// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Darwin
import Foundation

/// The process table, read the way `ps` reads it. A full walk costs under a
/// millisecond, and it works on root's processes from an unprivileged caller.
enum Processes {
    static func pids(runningExecutable path: String) -> [pid_t] {
        var bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { pid in
            guard pid > 0 else { return false }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            return length > 0 && String(decoding: buffer.prefix(Int(length)), as: UTF8.self) == path
        }
    }
}
