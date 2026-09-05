// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

/// What the helper last did, so the unprivileged app can report the truth
/// instead of assuming its settings took effect.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var applied: Bool
    public var speed: Double
    public var damping: Double
    public var gain: Double
    public var retention: Double
    public var refreshHz: Double
    public var dockPID: Int32
    public var updatedAt: Date
    public var error: String?

    public init(applied: Bool, speed: Double, damping: Double, gain: Double, retention: Double,
                refreshHz: Double, dockPID: Int32, updatedAt: Date, error: String?) {
        self.applied = applied
        self.speed = speed
        self.damping = damping
        self.gain = gain
        self.retention = retention
        self.refreshHz = refreshHz
        self.dockPID = dockPID
        self.updatedAt = updatedAt
        self.error = error
    }

    public static let url = Configuration.directory.appendingPathComponent("status.json")

    /// Encoder and decoder must agree on dates; a mismatch fails silently and
    /// leaves every reader believing the helper has never run.
    private static var coder: (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    public static func load() -> HelperStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? coder.1.decode(HelperStatus.self, from: data)
    }

    public func save() {
        guard let data = try? Self.coder.0.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.url.path)
    }
}

/// Installs and removes the root LaunchDaemon that reapplies the setting.
///
/// The daemon is this same executable run with `daemon`, so there is no second
/// binary to locate or keep in step.
public enum HelperInstall {
    public static let label = "com.bisak.spaceswitch.helper"
    public static let plistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    public static let executableURL = Configuration.directory.appendingPathComponent("spaceswitch")

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public static func install() throws {
        guard geteuid() == 0 else { throw SpaceSwitchError.notPermitted(KERN_PROTECTION_FAILURE) }
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()

        try Configuration.prepareDirectory()
        let fm = FileManager.default
        for stale in ["spaceswitch", "spaceswitchd"] {
            let url = Configuration.directory.appendingPathComponent(stale)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try fm.copyItem(at: source, to: executableURL)
        try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                             ofItemAtPath: executableURL.path)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
                             ofItemAtPath: plistURL.path)

        _ = launchctl(["bootout", "system/\(label)"])          // ignore "not loaded"
        let result = launchctl(["bootstrap", "system", plistURL.path])
        guard result.status == 0 else {
            throw SpaceSwitchError.verificationFailed("launchctl bootstrap failed: \(result.output)")
        }
    }

    public static func uninstall() throws {
        guard geteuid() == 0 else { throw SpaceSwitchError.notPermitted(KERN_PROTECTION_FAILURE) }
        _ = launchctl(["bootout", "system/\(label)"])
        let fm = FileManager.default
        for url in [plistURL, executableURL, HelperStatus.url] where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "could not run launchctl") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
