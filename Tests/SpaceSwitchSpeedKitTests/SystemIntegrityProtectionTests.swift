// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Testing

@testable import SpaceSwitchSpeedKit

@Suite("System Integrity Protection")
struct SystemIntegrityProtectionTests {
    static let custom = """
        System Integrity Protection status: unknown (Custom Configuration).

        Configuration:
        \tApple Internal: disabled
        \tKext Signing: disabled
        \tFilesystem Protections: enabled
        \tDebugging Restrictions: %@
        \tDTrace Restrictions: enabled
        \tNVRAM Protections: enabled
        \tBaseSystem Verification: enabled
        \tBoot-arg Restrictions: enabled
        \tKernel Integrity Protections: enabled
        \tAuthenticated Root Requirement: enabled

        """

    @Test("the plain answers")
    func plain() {
        let disabled = "System Integrity Protection status: disabled.\n"
        let enabled = "System Integrity Protection status: enabled.\n"
        #expect(SystemIntegrityProtection.allowsTaskForPID(status: disabled))
        #expect(!SystemIntegrityProtection.allowsTaskForPID(status: enabled))
    }

    /// "Apple Internal: disabled" appears in every custom configuration, so a
    /// search for the word would let `--without kext` through and the helper
    /// would then fail on every Dock launch.
    @Test("a custom configuration is decided by its debugging line alone")
    func custom() {
        let with = Self.custom.replacingOccurrences(of: "%@", with: "disabled")
        let without = Self.custom.replacingOccurrences(of: "%@", with: "enabled")
        #expect(SystemIntegrityProtection.allowsTaskForPID(status: with))
        #expect(!SystemIntegrityProtection.allowsTaskForPID(status: without))
    }

    @Test("no answer means no")
    func silence() {
        #expect(!SystemIntegrityProtection.allowsTaskForPID(status: ""))
        #expect(!SystemIntegrityProtection.allowsTaskForPID(status: "csrutil: command not found"))
    }
}
