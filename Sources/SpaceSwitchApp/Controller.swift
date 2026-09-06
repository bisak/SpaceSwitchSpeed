// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import AppKit
import Combine
import Foundation
import SpaceSwitchKit

/// Backs the controls the window has.
///
/// Changing Dock needs root, which the app does not have. Rather than making
/// that the user's problem, the first change they make authorises a background
/// helper once and everything after it is silent. Without that helper each
/// change costs an authorisation prompt of its own, which is what turning off
/// "apply after restarting" trades away.
@MainActor
final class Controller: ObservableObject {
    @Published var stop: Double
    @Published private(set) var note: Note?
    @Published private(set) var busy = false
    @Published var confirmingRemoval = false

    /// Damping is a secondary control, hidden behind Options. Nil means it
    /// follows the speed automatically, which is what almost everyone wants.
    @Published private(set) var damping: Double?

    enum Note: Equatable {
        case needsSIPDisabled
        case failed(String)
    }

    let model = SpringModel(dt: Display.mainFrameInterval())

    private var committed: Double
    private var poll: Task<Void, Never>?

    init() {
        let config = Configuration.load()
        let index = Speed.presets.firstIndex { abs($0.value - config.speed) < 0.005 } ?? 0
        let position = Double(config.enabled ? index : 0)
        stop = position
        committed = position
        damping = config.damping

        if !SystemIntegrityProtection.isDisabled { note = .needsSIPDisabled }

        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkForTrouble()
            }
        }
    }

    deinit { poll?.cancel() }

    var isEditable: Bool { note != .needsSIPDisabled && !busy }

    // MARK: - Changing the setting

    func commit() {
        guard note != .needsSIPDisabled, stop != committed else { return }
        apply(stop: stop, damping: damping)
    }

    /// Takes SpaceSwitch off the machine: Dock back to stock, the helper and
    /// every file it wrote gone, and this app's own preferences with them. All
    /// that is left is the app itself, for the user to move to the Trash.
    func removeEverything() {
        Task {
            guard await authorise("uninstall") else { return }
            if let identifier = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: identifier)
            }
            NSApp.terminate(nil)
        }
    }

    private func apply(stop: Double, damping: Double?) {
        let preset = Speed.presets[Int(stop)]
        var config = Configuration.load()
        config.speed = preset.value
        config.enabled = preset.value < Speed.stock
        config.damping = damping
        config.lastKnownRefreshHz = Display.mainRefreshRate()

        // With a helper running, saving is the whole job: it notices the change
        // and applies it within half a second.
        if HelperInstall.isInstalled {
            do {
                try config.save()
                note = nil
                committed = stop
            } catch {
                note = .failed("Could not save your setting.")
            }
            return
        }

        // Otherwise this first change installs the helper, which is what makes
        // every change after it silent.
        Task {
            if await authorise("install") {
                try? config.save()
                self.committed = stop
                self.note = nil
            } else {
                self.stop = self.committed
            }
        }
    }

    // MARK: - Authorisation

    private enum Outcome: Sendable { case succeeded, cancelled, failed }

    /// macOS shows its own authorisation prompt, so the app never asks for a
    /// password itself.
    private func authorise(_ arguments: String) async -> Bool {
        guard let tool = Self.commandLineTool() else {
            note = .failed("SpaceSwitch is missing part of itself. Reinstall it.")
            return false
        }
        busy = true
        defer { busy = false }

        switch await Self.run(tool, arguments) {
        case .succeeded: return true
        case .cancelled: return false
        case .failed:
            note = .failed("Could not apply your setting.")
            return false
        }
    }

    /// Runs off the main actor: the authorisation prompt blocks until answered.
    private nonisolated static func run(_ tool: URL, _ arguments: String) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let escaped = tool.path.replacingOccurrences(of: "\"", with: "\\\"")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [
                    "-e",
                    "do shell script \"'\(escaped)' \(arguments)\" with administrator privileges",
                ]
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = Pipe()
                guard (try? process.run()) != nil else {
                    return continuation.resume(returning: .failed)
                }
                let errorText = String(
                    decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: .succeeded)
                } else {
                    // -128 is the user dismissing the authorisation prompt.
                    continuation.resume(returning: errorText.contains("-128") ? .cancelled : .failed)
                }
            }
        }
    }

    // MARK: - Trouble

    /// Surfaces only failures the user can do something about, and only once
    /// they have persisted past a retry.
    private func checkForTrouble() {
        guard note != .needsSIPDisabled, !busy, HelperInstall.isInstalled else { return }
        guard let live = HelperStatus.load() else { return }
        if let error = live.error, Date().timeIntervalSince(live.updatedAt) < 30 {
            note = .failed(error)
        } else if case .failed = note {
            note = nil
        }
    }

    /// Deliberately does not use `url(forAuxiliaryExecutable:)`: that searches
    /// Contents/MacOS, where a case-insensitive filesystem makes "spaceswitch"
    /// and the bundle executable "SpaceSwitch" the same file.
    private static func commandLineTool() -> URL? {
        [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spaceswitch"),
            URL(fileURLWithPath: "/opt/homebrew/bin/spaceswitch"),
            URL(fileURLWithPath: "/usr/local/bin/spaceswitch"),
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum SystemIntegrityProtection {
    /// `csrutil status` is the documented way to ask, and shelling out avoids
    /// depending on the private `csr_check` symbol.
    static var isDisabled: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).lowercased().contains("disabled")
    }
}
