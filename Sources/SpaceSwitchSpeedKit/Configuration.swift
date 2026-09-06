// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

/// Settings shared by the app and the helper.
///
/// The helper runs as root and re-applies on every Dock launch, so the file
/// lives somewhere both can reach: readable by everyone, writable by admins.
public struct Configuration: Codable, Equatable, Sendable {
    /// A multiplier on Dock's stock pace. `Speed.stock` means unpatched, so no
    /// separate on/off flag exists to disagree with it.
    public var speed: Double

    public init(speed: Double) {
        self.speed = speed
    }

    public var isEnabled: Bool { speed < Speed.stock }

    public static let directory = URL(
        fileURLWithPath: "/Library/Application Support/SpaceSwitchSpeed", isDirectory: true)
    public static let url = directory.appendingPathComponent("config.json")

    public static func load() -> Configuration {
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONDecoder().decode(Configuration.self, from: data)
        else {
            return Configuration(speed: Speed.stock)
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
