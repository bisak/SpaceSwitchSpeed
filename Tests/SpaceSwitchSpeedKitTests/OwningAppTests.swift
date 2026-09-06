// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation
import Testing

@testable import SpaceSwitchSpeedKit

@Suite("Owning app")
final class OwningAppTests {
    private let root: URL
    private let fm = FileManager.default

    /// `F_GETPATH` answers with the real path, which under the temporary
    /// directory starts with `/private`. Foundation's own resolution strips
    /// that prefix, so `realpath` it is.
    init() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OwningAppTests-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard let real = realpath(scratch.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    deinit { try? fm.removeItem(at: root) }

    private func bundle(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("a move or rename is followed, not mistaken for a deletion")
    func followsMoves() throws {
        let original = try bundle("A.app")
        let app = OwningApp(recorded: original, fallbacks: [])
        #expect(app.locate() == original)

        let moved = root.appendingPathComponent("Elsewhere/Renamed.app").path
        try fm.createDirectory(
            at: root.appendingPathComponent("Elsewhere"), withIntermediateDirectories: true)
        try fm.moveItem(atPath: original, toPath: moved)
        #expect(app.locate() == moved)
    }

    @Test("a deleted bundle is gone even though its descriptor still names a path")
    func reportsDeletion() throws {
        let original = try bundle("A.app")
        let app = OwningApp(recorded: original, fallbacks: [])
        try fm.removeItem(atPath: original)
        #expect(app.locate() == nil)
    }

    @Test("a bundle replaced in place, as an update does, is adopted")
    func adoptsReplacement() throws {
        let original = try bundle("A.app")
        let app = OwningApp(recorded: original, fallbacks: [])
        try fm.removeItem(atPath: original)
        #expect(app.locate() == nil)
        _ = try bundle("A.app")
        #expect(app.locate() == original)
    }

    @Test("an installed copy stands in for a recorded path that no longer exists")
    func fallsBackToInstalledCopy() throws {
        let installed = try bundle("Installed.app")
        let app = OwningApp(recorded: root.appendingPathComponent("Missing.app").path, fallbacks: [installed])
        #expect(app.locate() == installed)
    }

    @Test("the Trash counts as gone until the bundle is put back")
    func treatsTrashAsGone() throws {
        let original = try bundle("A.app")
        let app = OwningApp(recorded: original, fallbacks: [])
        let trashed = root.appendingPathComponent(".Trash/A.app").path
        try fm.createDirectory(at: root.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try fm.moveItem(atPath: original, toPath: trashed)
        #expect(app.locate() == nil)
        try fm.moveItem(atPath: trashed, toPath: original)
        #expect(app.locate() == original)
    }

    @Test(
        "only a Trash directory component counts",
        arguments: [
            ("/Users/me/.Trash/SpaceSwitchSpeed.app", true),
            ("/Volumes/External/.Trashes/501/SpaceSwitchSpeed.app", true),
            ("/Applications/Trash.app", false),
            ("/Users/me/Documents/.Trash-ish/SpaceSwitchSpeed.app", false),
        ])
    func trashPaths(path: String, expected: Bool) {
        #expect(OwningApp.isInTrash(path) == expected)
    }
}
