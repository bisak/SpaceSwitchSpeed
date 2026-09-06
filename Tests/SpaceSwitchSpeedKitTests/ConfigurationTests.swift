// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation
import Testing

@testable import SpaceSwitchSpeedKit

@Suite("Configuration")
final class ConfigurationTests {
    private let directory: URL
    private let fm = FileManager.default

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: directory) }

    private func file(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("config-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("a saved speed loads")
    func loads() throws {
        let config = Configuration.load(from: try file(#"{"speed": 0.35}"#))
        #expect(config.speed == 0.35)
        #expect(config.isEnabled)
    }

    /// Anything the helper cannot trust means Dock at stock: malformed JSON, or
    /// a speed the CLI would have refused.
    @Test(
        "anything untrustworthy loads as stock",
        arguments: [#"{"speed": 0.05}"#, #"{"speed": 1.5}"#, #"{"speed": "fast"}"#, "not json", ""])
    func stock(contents: String) throws {
        let config = Configuration.load(from: try file(contents))
        #expect(config.speed == Speed.stock)
        #expect(!config.isEnabled)
    }

    @Test("a missing file loads as stock")
    func missing() {
        let config = Configuration.load(from: directory.appendingPathComponent("missing.json"))
        #expect(config.speed == Speed.stock)
    }
}
