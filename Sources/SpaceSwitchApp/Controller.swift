// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Combine
import Foundation
import SpaceSwitchKit

/// Owns the settings the window edits and reports what the helper did with them.
///
/// The app is unprivileged: writing to Dock needs root, so the app only records
/// intent and the helper enacts it. Everything the window shows about the live
/// system comes from the helper's own status file, never from assumption.
@MainActor
final class Controller: ObservableObject {
    @Published var enabled: Bool { didSet { publish() } }
    @Published var speed: Double { didSet { publish() } }
    @Published var usesCustomDamping: Bool { didSet { publish() } }
    @Published var damping: Double { didSet { publish() } }

    @Published private(set) var live: HelperStatus?
    @Published private(set) var helperInstalled: Bool
    @Published private(set) var busy = false
    @Published private(set) var problem: String?
    @Published private(set) var sipDisabled: Bool

    let model: SpringModel
    let refreshHz: Double

    private var publishTask: Task<Void, Never>?
    private var poll: Timer?

    init() {
        refreshHz = Display.mainRefreshRate()
        model = SpringModel(dt: 1 / refreshHz)

        let config = Configuration.load()
        enabled = config.enabled
        speed = config.speed
        usesCustomDamping = config.damping != nil
        damping = config.damping ?? SpringModel(dt: 1 / refreshHz).damping(forSpeed: config.speed)

        helperInstalled = HelperInstall.isInstalled
        sipDisabled = SystemIntegrityProtection.isDisabled
        live = HelperStatus.load()

        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { poll?.invalidate() }

    // MARK: - Derived values

    var effectiveDamping: Double { usesCustomDamping ? damping : model.damping(forSpeed: speed) }

    var coefficients: (gain: Double, retention: Double) {
        model.coefficients(speed: speed, damping: usesCustomDamping ? damping : nil)
    }

    var response: SpringModel.Response {
        let c = coefficients
        return model.simulate(gain: c.gain, retention: c.retention)
    }

    var stockResponse: SpringModel.Response {
        model.simulate(gain: SpringModel.stockGain, retention: SpringModel.stockRetention)
    }

    var presetName: String? { Speed.presets.first { abs($0.value - speed) < 0.005 }?.name }

    /// True when the helper has confirmed the current settings are on Dock.
    var isLive: Bool {
        guard enabled, let live, live.applied, live.error == nil else { return false }
        return abs(live.speed - speed) < 0.02 && abs(live.damping - effectiveDamping) < 0.02
    }

    // MARK: - Settings

    func refresh() {
        helperInstalled = HelperInstall.isInstalled
        live = HelperStatus.load()
    }

    /// Slider drags produce a change per frame; the helper only needs the last.
    private func publish() {
        publishTask?.cancel()
        publishTask = Task { [enabled, speed, usesCustomDamping, damping, refreshHz] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            var config = Configuration.load()
            config.enabled = enabled
            config.speed = speed
            config.damping = usesCustomDamping ? damping : nil
            config.lastKnownRefreshHz = refreshHz
            do {
                try config.save()
                await MainActor.run { self.problem = nil }
            } catch {
                await MainActor.run { self.problem = "Could not save settings: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Helper lifecycle

    /// The app cannot install a root job itself, so it asks macOS to run the
    /// bundled command line tool with administrator rights. One password prompt.
    func installHelper() { runPrivileged("install", then: true) }
    func removeHelper() { runPrivileged("uninstall", then: false) }

    private func runPrivileged(_ subcommand: String, then installed: Bool) {
        guard let tool = Self.bundledCLI() else {
            problem = "Could not find the spaceswitch command line tool inside the app bundle."
            return
        }
        busy = true
        problem = nil
        Task.detached {
            let escaped = tool.path.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"'\(escaped)' \(subcommand)\" with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = Pipe()
            try? process.run()
            let errorText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let status = process.terminationStatus

            await MainActor.run {
                self.busy = false
                self.refresh()
                if status != 0 {
                    // -128 is the user cancelling the authorisation dialog.
                    if !errorText.contains("-128") {
                        self.problem = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } else if installed {
                    self.publish()
                }
            }
        }
    }

    /// Deliberately does not use `url(forAuxiliaryExecutable:)`: that searches
    /// Contents/MacOS, where a case-insensitive filesystem makes "spaceswitch"
    /// and the bundle executable "SpaceSwitch" the same file.
    private static func bundledCLI() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spaceswitch"),
            URL(fileURLWithPath: "/opt/homebrew/bin/spaceswitch"),
            URL(fileURLWithPath: "/usr/local/bin/spaceswitch"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
