// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation
import Testing

@testable import SpaceSwitchSpeedKit

@Suite("Helper status")
struct HelperStatusTests {
    @Test("a status survives its own encoding")
    func roundTrip() throws {
        let status = HelperStatus(
            speed: 0.35, dockPIDs: [412, 9001], updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            error: nil)
        let data = try #require(status.encoded())
        #expect(HelperStatus.decode(data) == status)
    }

    /// The first helper wrote a single `dockPID`. An app updated ahead of its
    /// helper must still read that file, or it shows nothing until the next change.
    @Test("the previous helper's format still decodes")
    func previousFormat() throws {
        let data = Data(
            """
            {
              "dockPID" : 9795,
              "error" : "Dock's spring constants are not what this version expects",
              "speed" : 1,
              "updatedAt" : "2026-09-06T09:44:10Z"
            }
            """.utf8)
        let status = try #require(HelperStatus.decode(data))
        #expect(status.dockPIDs.isEmpty)
        #expect(status.error?.hasPrefix("Dock's spring constants") == true)
        #expect(status.speed == 1)
    }

    @Test("sameness ignores the timestamp and nothing else")
    func sameness() {
        let base = HelperStatus(speed: 0.5, dockPIDs: [1], updatedAt: Date(), error: nil)
        let later = HelperStatus(speed: 0.5, dockPIDs: [1], updatedAt: Date() + 60, error: nil)
        let failed = HelperStatus(speed: 0.5, dockPIDs: [1], updatedAt: Date(), error: "no")
        #expect(base.describesSameState(as: later))
        #expect(!base.describesSameState(as: failed))
        #expect(!base.describesSameState(as: nil))
    }
}
