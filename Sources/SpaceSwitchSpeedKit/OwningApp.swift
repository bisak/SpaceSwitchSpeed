// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

/// Follows the app that installed the helper. Dragging an app to the Trash
/// notifies nobody, so the helper has to look for itself, and it must not
/// mistake a bundle that was merely moved or renamed for one that is gone.
///
/// An event-only descriptor on the bundle answers with its current path after
/// any rename on the same volume, without pinning the volume: a disk image the
/// app was run from can still be ejected.
public final class OwningApp {
    static let trashDirectories: Set<Substring> = [".Trash", ".Trashes"]

    private let candidates: [String]
    private var descriptor: Int32 = -1

    /// `recorded` is where the app was when the helper was installed. The
    /// fallback covers an app that was run from a disk image and installed
    /// properly afterwards.
    public init(recorded: String, fallbacks: [String] = ["/Applications/Space Switch Speed.app"]) {
        candidates = [recorded] + fallbacks.filter { $0 != recorded }
        _ = locate()
    }

    deinit { release() }

    /// The bundle's current path, or nil while every candidate is in the Trash
    /// or gone. A trashed bundle is let go of, so that a copy installed elsewhere
    /// can take its place.
    public func locate() -> String? {
        if descriptor >= 0 {
            if let path = Self.currentPath(of: descriptor), Self.isSameObject(descriptor, path),
                !Self.isInTrash(path)
            {
                return path
            }
            release()
        }
        for path in candidates where !Self.isInTrash(path) {
            let opened = open(path, O_EVTONLY)
            guard opened >= 0 else { continue }
            descriptor = opened
            return path
        }
        return nil
    }

    private func release() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private static func currentPath(of descriptor: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// A deleted bundle keeps answering `F_GETPATH` with its last path, and a
    /// replaced one answers with a path its successor now occupies.
    private static func isSameObject(_ descriptor: Int32, _ path: String) -> Bool {
        var held = stat()
        var named = stat()
        guard fstat(descriptor, &held) == 0, stat(path, &named) == 0 else { return false }
        return held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { trashDirectories.contains($0) }
    }
}
