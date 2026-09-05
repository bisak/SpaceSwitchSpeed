// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

/// Settings shared by the command line tool, the app and the helper.
///
/// The helper runs as root and re-applies on every Dock launch, so the file
/// lives somewhere both can reach: readable by everyone, writable by admins.
public struct Configuration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var speed: Double
    /// Overrides the damping ratio derived from `speed`. Nil means "follow the
    /// single-knob rule", which is what the app exposes by default.
    public var damping: Double?
    /// Recorded by whichever component last ran inside a login session. A root
    /// helper has no window server connection to ask, so it needs the hint.
    public var lastKnownRefreshHz: Double?

    public init(
        enabled: Bool = true, speed: Double = 0.5, damping: Double? = nil,
        lastKnownRefreshHz: Double? = nil
    ) {
        self.enabled = enabled
        self.speed = speed.clamped(to: Speed.range)
        self.damping = damping
        self.lastKnownRefreshHz = lastKnownRefreshHz
    }

    public static let directory = URL(
        fileURLWithPath: "/Library/Application Support/SpaceSwitch", isDirectory: true)
    public static let url = directory.appendingPathComponent("config.json")

    public static func load() -> Configuration {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            return Configuration(enabled: false, speed: Speed.stock)
        }
        return config
    }

    /// Creates the shared directory so admin users can write settings without
    /// privileges while the helper, running as root, reads them.
    public static func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o775])
        }
        if geteuid() == 0 {
            let adminGroup = 80
            try? fm.setAttributes(
                [.posixPermissions: 0o775, .ownerAccountID: 0, .groupOwnerAccountID: adminGroup],
                ofItemAtPath: directory.path)
        }
    }

    public func save() throws {
        try Self.prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: Self.url.path)
    }
}
