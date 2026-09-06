// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

/// `csrutil status` is the documented way to ask, and shelling out avoids
/// depending on the private `csr_check` symbol.
public enum SystemIntegrityProtection {
    /// Whether `task_for_pid` on Dock can succeed: SIP off altogether, or a
    /// custom configuration with its debugging restrictions off. No other part
    /// of SIP matters to this tool.
    public static var allowsTaskForPID: Bool { allowsTaskForPID(status: csrutilStatus()) }

    /// A custom configuration reports `unknown` on its first line and then one
    /// line per protection, and one of those, Apple Internal, reads `disabled`
    /// on every Mac outside Apple. Only the debugging line decides.
    static func allowsTaskForPID(status: String) -> Bool {
        let lines = status.lowercased().split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let summary = lines.first(where: { $0.hasPrefix("system integrity protection status:") })
        else { return false }
        if summary.contains("disabled") { return true }
        if summary.contains("enabled") { return false }
        return lines.contains { $0.hasPrefix("debugging restrictions:") && $0.contains("disabled") }
    }

    private static func csrutilStatus() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
