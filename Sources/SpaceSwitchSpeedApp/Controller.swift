// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import AppKit
import Combine
import Foundation
import ServiceManagement
import SpaceSwitchSpeedKit

/// Backs the one control the window has.
///
/// Changing Dock needs root, which the app does not have. Rather than making
/// that the user's problem, the first change they make authorises a background
/// helper once, and everything after it is silent.
@MainActor
final class Controller: ObservableObject {
    @Published var stop: Double
    @Published private(set) var note: Note?
    @Published private(set) var busy = false
    @Published var confirmingRemoval = false

    enum Note: Equatable {
        case needsDebuggingRestrictionsOff
        /// The helper was switched off under Login Items.
        case switchedOff
        /// This app's own failure; it stands until a change succeeds.
        case failed(String)
        /// Reported by the helper; it clears when the helper recovers.
        case helperFailed(String)
    }

    private var committed: Double
    private var poll: Task<Void, Never>?

    init() {
        // The saved speed is not necessarily a preset, since config.json can be
        // edited by hand, so snap to the nearest stop.
        let speed = Configuration.load().speed
        let nearest = Speed.presets.indices.min {
            abs(Speed.presets[$0].value - speed) < abs(Speed.presets[$1].value - speed)
        }
        let position = Double(nearest ?? 0)
        stop = position
        committed = position

        if !SystemIntegrityProtection.allowsTaskForPID { note = .needsDebuggingRestrictionsOff }

        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkForTrouble()
            }
        }
    }

    deinit { poll?.cancel() }

    var isEditable: Bool { note != .needsDebuggingRestrictionsOff && !busy }

    /// The stop the slider is resting on.
    var preset: Speed.Preset { Speed.presets[Int(stop)] }

    // MARK: - Changing the setting

    func commit() {
        guard note != .needsDebuggingRestrictionsOff, stop != committed else { return }
        apply(stop: stop)
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Takes Space Switch Speed off the machine: Dock back to stock, the helper and
    /// every file it wrote gone, and this app's own preferences with them. All
    /// that is left is the app itself, for the user to move to the Trash.
    func removeEverything() {
        if HelperInstall.isPresent, !authorise("uninstall") { return }
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        NSApp.terminate(nil)
    }

    private func apply(stop: Double) {
        // Reinstalling cannot switch the helper back on; only the user can.
        if Self.helperIsSwitchedOff {
            note = .switchedOff
            self.stop = committed
            return
        }
        let speed = Speed.presets[Int(stop)].value
        let succeeded: Bool
        if HelperInstall.isCurrent(with: Self.helper) {
            // Saving is the whole job: the helper notices within half a second.
            // Only a standard account, which cannot write the shared directory,
            // needs root for it.
            succeeded = (try? Configuration(speed: speed).save()) != nil || authorise("set \(speed)")
        } else {
            // This change installs the helper, or replaces one an earlier build
            // left behind, which is what makes every change after it silent.
            succeeded = authorise("install \(speed)")
        }
        if succeeded {
            committed = stop
            note = nil
        } else {
            self.stop = committed
        }
    }

    // MARK: - Authorisation

    private enum Outcome { case succeeded, cancelled, failed(String) }

    /// macOS shows its own authorisation prompt, so the app never asks for a
    /// password itself.
    private func authorise(_ arguments: String) -> Bool {
        busy = true
        defer { busy = false }

        switch Self.run(Self.helper, arguments) {
        case .succeeded: return true
        case .cancelled: return false
        case .failed(let message):
            note = .failed(message)
            return false
        }
    }

    /// Main-actor bound because `NSAppleScript` is. Running the script in
    /// process is the whole point: the authorisation dialog then names this app
    /// instead of `osascript`, which matters for a tool asking to be trusted
    /// with root.
    private static func run(_ tool: URL, _ arguments: String) -> Outcome {
        let source =
            "do shell script (quoted form of \(literal(tool.path)))"
            + " & \(literal(" " + arguments)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return .failed("Could not run the helper.") }

        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return .succeeded }

        /// `errAEUserCanceled`, which Swift does not surface from Carbon.
        let userCancelled = -128
        if error[NSAppleScript.errorNumber] as? Int == userCancelled { return .cancelled }
        // The helper's own words, minus the name it prefixes them with for a terminal.
        let message = (error[NSAppleScript.errorMessage] as? String ?? "")
            .replacingOccurrences(of: "spaceswitchspeed: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "Could not apply your setting." : message)
    }

    /// Wraps a string as an AppleScript literal; `quoted form of` then handles
    /// the shell layer, so a path may contain quotes of either kind.
    private static func literal(_ text: String) -> String {
        let escaped =
            text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Trouble

    /// macOS lists the helper under Login Items and lets the user switch it off
    /// there, which stops it without telling anyone; the window has to say so.
    private static var helperIsSwitchedOff: Bool {
        HelperInstall.isInstalled
            && SMAppService.statusForLegacyPlist(at: HelperInstall.plistURL) == .requiresApproval
    }

    /// The helper's last word is the truth about Dock, so its error stands
    /// until it reports success. This app's own failures are left alone.
    private func checkForTrouble() {
        guard note != .needsDebuggingRestrictionsOff, !busy else { return }
        if Self.helperIsSwitchedOff {
            note = .switchedOff
            return
        }
        if note == .switchedOff { note = nil }
        guard let live = HelperStatus.load() else { return }
        if let error = live.error {
            note = .helperFailed(error)
        } else if case .helperFailed = note {
            note = nil
        }
    }

    /// Deliberately does not use `url(forAuxiliaryExecutable:)`: that searches
    /// Contents/MacOS, and the helper is copied into Contents/Helpers.
    private static let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/spaceswitchspeed")
}
