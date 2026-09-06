// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Testing

@testable import SpaceSwitchSpeedKit

@Suite("Spring model")
struct SpringTests {
    /// Characterising Apple's constants and synthesising them back must be
    /// exact, otherwise the speed axis is not anchored to stock.
    @Test("speed 1.0 reproduces Apple's constants", arguments: [60.0, 90.0, 120.0, 144.0, 240.0])
    func roundTrip(refreshHz: Double) {
        let model = SpringModel(dt: 1 / refreshHz)
        let (gain, retention) = model.coefficients(speed: 1.0)
        #expect(abs(gain - SpringModel.stockGain) < 1e-9)
        #expect(abs(retention - SpringModel.stockRetention) < 1e-12)
    }

    /// A 60 Hz Mac runs Apple's constants with complex poles, so both branches
    /// have to invert cleanly or `status` misreports the speed on most Macs.
    @Test("the speed is recoverable from the retention", arguments: [60.0, 120.0])
    func speedRoundTrip(refreshHz: Double) {
        let model = SpringModel(dt: 1 / refreshHz)
        for speed in stride(from: 0.2, through: 1.0, by: 0.1) {
            let (_, retention) = model.coefficients(speed: speed)
            #expect(abs(SpringModel.speed(retention: retention) - speed) < 1e-9)
        }
    }

    @Test("raising the speed always arrives sooner and never overshoots")
    func speedIsMonotonic() {
        let model = SpringModel(dt: 1 / 120.0)
        var previous = Double.infinity
        for speed in stride(from: 1.0, through: 0.2, by: -0.1) {
            let (gain, retention) = model.coefficients(speed: speed)
            let response = model.simulate(gain: gain, retention: retention)
            #expect(response.arrival < previous, "speed \(speed) should arrive sooner")
            #expect(response.overshoot < 0.01, "speed \(speed) should not visibly overshoot")
            previous = response.arrival
        }
    }

    @Test("every preset is inside the supported range")
    func presetsAreInRange() {
        for preset in Speed.presets {
            #expect(Speed.range.contains(preset.value), "\(preset.name) is outside the slider range")
        }
    }
}

@Suite("AArch64 encoding")
struct EncodingTests {
    /// Word values taken from a disassembly of the shipped Dock binary.
    @Test("encodings match the disassembled instructions")
    func encodings() {
        #expect(ARM64.fsub(d: 19, n: 1, m: 17) == 0x1E71_3833)
        #expect(ARM64.fadd(d: 19, n: 19, m: 19) == 0x1E73_2A73)
        #expect(ARM64.fmul(d: 20, n: 20, m: 2) == 0x1E62_0A94)
        #expect(ARM64.fneg(d: 19, n: 17) == 0x1E61_4233)
        #expect(ARM64.ldrd(t: 20, n: 20, offset: 0x150) == 0xFD40_AA94)
        #expect(ARM64.decodeMOVIzero(0x6F00_E403) == 3)
        #expect(ARM64.decodeLDRd(0xFD40_AA94) == ARM64.Mem(t: 20, n: 20, offset: 0x150))
    }

    @Test("adrp round-trips through its split immediate")
    func adrpRoundTrip() throws {
        let pc: UInt64 = 0x1_0015_0EF0
        let page: UInt64 = 0x1_0036_F000
        let word = try #require(ARM64.adrp(d: 11, page: page, at: pc))
        #expect(word == 0xF000_10EB)
        let decoded = try #require(ARM64.decodeADRP(word, at: pc))
        #expect(decoded.page == page)
        #expect(decoded.d == 11)
    }

    /// The scratch page can land anywhere the allocator chooses, so the
    /// encoder has to refuse what it cannot reach rather than emit a wrong page.
    @Test("adrp refuses targets beyond its range")
    func adrpRangeIsChecked() {
        #expect(ARM64.adrp(d: 11, page: 0x9_0000_0000, at: 0x1_0000_0000) == nil)
        #expect(ARM64.ldrd(t: 2, n: 11, offset: 4) == nil)
        #expect(ARM64.ldrd(t: 2, n: 11, offset: 0x10000) == nil)
    }
}
