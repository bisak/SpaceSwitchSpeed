// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

/// What the helper last did, so the unprivileged app can report the truth
/// instead of assuming its settings took effect.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var speed: Double
    public var dockPIDs: [Int32]
    public var updatedAt: Date
    public var error: String?

    public init(speed: Double, dockPIDs: [Int32], updatedAt: Date, error: String?) {
        self.speed = speed
        self.dockPIDs = dockPIDs
        self.updatedAt = updatedAt
        self.error = error
    }

    public static let url = Configuration.directory.appendingPathComponent("status.json")

    private enum CodingKeys: String, CodingKey { case speed, dockPIDs, updatedAt, error }

    /// A status written by an older helper, before `dockPIDs`, still decodes,
    /// so an updated app can read its errors until the helper is replaced.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speed = try values.decode(Double.self, forKey: .speed)
        dockPIDs = try values.decodeIfPresent([Int32].self, forKey: .dockPIDs) ?? []
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        error = try values.decodeIfPresent(String.self, forKey: .error)
    }

    /// Equality that ignores the timestamp, so a retry that changes nothing
    /// need not touch the disk.
    public func describesSameState(as other: HelperStatus?) -> Bool {
        guard let other else { return false }
        return speed == other.speed && dockPIDs == other.dockPIDs && error == other.error
    }

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
        return decode(data)
    }

    public func save() {
        guard let data = encoded() else { return }
        try? data.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.url.path)
    }

    static func decode(_ data: Data) -> HelperStatus? {
        try? coder.1.decode(HelperStatus.self, from: data)
    }

    func encoded() -> Data? {
        try? Self.coder.0.encode(self)
    }
}

/// Installs and removes the root LaunchDaemon that reapplies the setting.
///
/// The daemon is this same executable run with `daemon`, so there is no second
/// binary to locate or keep in step.
public enum HelperInstall {
    public static let label = "com.bisak.spaceswitchspeed.helper"
    /// What Login Items shows the daemon as, in place of its label.
    public static let appBundleIdentifier = "com.bisak.spaceswitchspeed"
    public static let plistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    /// Root-only, unlike the settings directory: launchd runs this as root, so
    /// it cannot live anywhere an admin process could replace it.
    public static let executableURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/\(label)")

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Whether anything of the helper is on disk, so that removal can skip
    /// asking for a password when there is nothing to remove.
    public static var isPresent: Bool {
        [plistURL, executableURL, Configuration.directory].contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Whether launchd has the daemon running. Files in place with no daemon
    /// behind them, after a failed bootstrap or a manual bootout, would
    /// otherwise be trusted with settings that nobody applies.
    public static var isRunning: Bool { !Processes.pids(runningExecutable: executableURL.path).isEmpty }

    /// Whether the running helper is byte-for-byte the one at `bundled`. An
    /// updated app ships a new helper, and the daemon would otherwise keep
    /// running the old one indefinitely.
    public static func isCurrent(with bundled: URL) -> Bool {
        isInstalled && isRunning
            && FileManager.default.contentsEqual(atPath: bundled.path, andPath: executableURL.path)
    }

    /// The app bundle this tool was run from, if any. Recorded at install time
    /// so the helper can tell when it has been orphaned — macOS offers no
    /// notification that an app was moved to the Trash.
    private static func owningApp(of tool: URL) -> URL? {
        let bundle = tool.deletingLastPathComponent()  // Contents/Helpers
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // .app
        guard bundle.pathExtension == "app",
            FileManager.default.fileExists(atPath: bundle.path)
        else { return nil }
        return bundle
    }

    public static func install() throws {
        guard geteuid() == 0 else { throw SpaceSwitchSpeedError.needsRoot }
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()

        try Configuration.prepareDirectory()
        let fm = FileManager.default
        let directory = executableURL.deletingLastPathComponent()
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try assertRootOnly(directory)
        if source.path != executableURL.path {
            if fm.fileExists(atPath: executableURL.path) { try fm.removeItem(at: executableURL) }
            try fm.copyItem(at: source, to: executableURL)
        }
        try fm.setAttributes(
            [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: executableURL.path)
        try assertRootOnly(executableURL)
        try writePlist(owner: owningApp(of: source)?.path)

        _ = launchctl(["bootout", "system/\(label)"])  // ignore "not loaded"
        let result = launchctl(["bootstrap", "system", plistURL.path])
        guard result.status == 0 else {
            try? fm.removeItem(at: plistURL)
            try? fm.removeItem(at: executableURL)
            throw SpaceSwitchSpeedError.verificationFailed("launchctl bootstrap failed: \(result.output)")
        }
    }

    /// The daemon calls this when its app has moved, so the record outlives a reboot.
    public static func recordOwner(_ app: String) throws {
        guard geteuid() == 0 else { throw SpaceSwitchSpeedError.needsRoot }
        try writePlist(owner: app)
    }

    private static func writePlist(owner: String?) throws {
        var arguments = [executableURL.path, "daemon"]
        if let owner { arguments += ["--owner", owner] }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "AssociatedBundleIdentifiers": [appBundleIdentifier],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0],
            ofItemAtPath: plistURL.path)
    }

    /// The point of the location: never hand launchd a binary that anyone but
    /// root could have written.
    private static func assertRootOnly(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let owner = attributes[.ownerAccountID] as? Int ?? -1
        let mode = attributes[.posixPermissions] as? Int ?? 0
        guard owner == 0, mode & 0o022 == 0 else {
            throw SpaceSwitchSpeedError.verificationFailed(
                "\(url.path) is writable by someone other than root")
        }
    }

    /// Removes the helper and everything it wrote, leaving nothing of
    /// Space Switch Speed on the system volume.
    public static func uninstall() throws {
        guard geteuid() == 0 else { throw SpaceSwitchSpeedError.needsRoot }
        // Files first: booting out terminates the helper, and the helper is
        // itself a caller of this when it finds it has outlived its app.
        // `bootout` unloads by label, so it does not need the plist to remain.
        let fm = FileManager.default
        try? fm.removeItem(at: plistURL)
        try? fm.removeItem(at: executableURL)
        try? fm.removeItem(at: Configuration.directory)
        _ = launchctl(["bootout", "system/\(label)"])
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
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
