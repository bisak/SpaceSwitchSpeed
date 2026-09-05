// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Combine
import Foundation
import SpaceSwitchKit

/// Backs the one control the window has.
///
/// Changing Dock needs root, which the app does not have. Rather than making
/// that the user's problem, the first change they make authorises a background
/// job once and everything after it is silent.
@MainActor
final class Controller: ObservableObject {
    @Published var stop: Double
    @Published private(set) var note: Note?
    @Published private(set) var busy = false

    /// Damping is a secondary control, hidden behind Options. Nil means it
    /// follows the speed automatically, which is what almost everyone wants.
    @Published private(set) var damping: Double?

    enum Note: Equatable {
        case needsSIPDisabled
        case failed(String)
    }

    private var committed: Double
    private var poll: Timer?

    init() {
        let config = Configuration.load()
        let index = Speed.presets.firstIndex { abs($0.value - config.speed) < 0.005 } ?? 0
        let position = Double(config.enabled ? index : 0)
        stop = position
        committed = position
        damping = config.damping

        if !SystemIntegrityProtection.isDisabled { note = .needsSIPDisabled }

        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForTrouble() }
        }
    }

    deinit { poll?.invalidate() }

    var isEditable: Bool { note != .needsSIPDisabled && !busy }

    let model = SpringModel(dt: Display.mainFrameInterval())

    /// The damping actually in force, whether chosen or derived.
    var effectiveDamping: Double {
        damping ?? model.damping(forSpeed: Speed.presets[Int(stop)].value)
    }

    func setDamping(_ value: Double?) {
        damping = value
        guard HelperInstall.isInstalled else { return commit() }
        write(stop)
    }

    // MARK: - Committing a change

    func commit() {
        guard note != .needsSIPDisabled else { return }
        let target = stop

        guard HelperInstall.isInstalled else {
            authorise { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    self.write(target)
                    self.committed = target
                } else {
                    self.stop = self.committed
                }
            }
            return
        }
        write(target)
        committed = target
    }

    private func write(_ stop: Double) {
        let preset = Speed.presets[Int(stop)]
        var config = Configuration.load()
        config.speed = preset.value
        config.enabled = preset.value < Speed.stock
        config.damping = damping
        config.lastKnownRefreshHz = Display.mainRefreshRate()
        do {
            try config.save()
            note = nil
        } catch {
            note = .failed("Could not save your setting.")
        }
    }

    /// Installs the background job. macOS shows its own authorisation prompt, so
    /// the app never asks for a password itself.
    private func authorise(completion: @escaping (Bool) -> Void) {
        guard let tool = Self.commandLineTool() else {
            note = .failed("SpaceSwitch is missing part of itself. Reinstall it.")
            return completion(false)
        }
        busy = true
        Task.detached {
            let escaped = tool.path.replacingOccurrences(of: "\"", with: "\\\"")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"'\(escaped)' install\" with administrator privileges"]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = Pipe()
            try? process.run()
            let errorText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let code = process.terminationStatus

            await MainActor.run {
                self.busy = false
                if code == 0 {
                    completion(true)
                } else {
                    // -128 is the user dismissing the authorisation prompt.
                    if !errorText.contains("-128") { self.note = .failed("Could not start SpaceSwitch.") }
                    completion(false)
                }
            }
        }
    }

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
        [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spaceswitch"),
         URL(fileURLWithPath: "/opt/homebrew/bin/spaceswitch"),
         URL(fileURLWithPath: "/usr/local/bin/spaceswitch")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
