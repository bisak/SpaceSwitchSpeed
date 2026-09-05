import XCTest
@testable import SpaceSwitchKit

final class SpringTests: XCTestCase {
    /// Characterising Apple's constants and synthesising them back must be exact,
    /// otherwise the speed axis is not anchored to stock.
    func testRoundTripAcrossRefreshRates() {
        for hz in [60.0, 90.0, 120.0, 144.0, 240.0] {
            let m = SpringModel(dt: 1 / hz)
            let (g, a) = m.coefficients(speed: 1.0)
            XCTAssertEqual(g, SpringModel.stockGain, accuracy: 1e-9, "gain at \(hz)Hz")
            XCTAssertEqual(a, SpringModel.stockRetention, accuracy: 1e-12, "retention at \(hz)Hz")
        }
    }

    func testStockCharacterMatchesDisassembledConstants() {
        let m = SpringModel(dt: 1 / 120.0)
        XCTAssertEqual(m.stockDamping, 1.2891, accuracy: 1e-4)
        XCTAssertEqual(m.stockTimeConstant, 0.1242, accuracy: 1e-4)
    }

    /// A 60 Hz Mac runs Apple's constants underdamped; the complex-root branch
    /// must round-trip too or the tool would be wrong on most Macs.
    func testUnderdampedStockIsHandled() {
        let m = SpringModel(dt: 1 / 60.0)
        XCTAssertLessThan(m.stockDamping, 1.0)
        let (g, a) = m.coefficients(timeConstant: m.stockTimeConstant, damping: m.stockDamping)
        XCTAssertEqual(g, SpringModel.stockGain, accuracy: 1e-9)
        XCTAssertEqual(a, SpringModel.stockRetention, accuracy: 1e-12)
    }

    func testSpeedMonotonicallyShortensArrival() {
        let m = SpringModel(dt: 1 / 120.0)
        var previous = Double.infinity
        for speed in stride(from: 1.0, through: 0.2, by: -0.1) {
            let (g, a) = m.coefficients(speed: speed)
            let r = m.simulate(gain: g, retention: a)
            XCTAssertLessThan(r.arrival, previous, "speed \(speed) should arrive sooner")
            XCTAssertLessThan(r.overshoot, 0.01, "speed \(speed) should not visibly overshoot")
            previous = r.arrival
        }
    }

    func testEncodingsMatchDisassembledDock() {
        XCTAssertEqual(ARM64.fsub(d: 19, n: 1, m: 17), 0x1E71_3833)
        XCTAssertEqual(ARM64.fadd(d: 19, n: 19, m: 19), 0x1E73_2A73)
        XCTAssertEqual(ARM64.fmul(d: 20, n: 20, m: 2), 0x1E62_0A94)
        XCTAssertEqual(ARM64.fneg(d: 19, n: 17), 0x1E61_4233)
        XCTAssertEqual(ARM64.ldrd(t: 20, n: 20, offset: 0x150), 0xFD40_AA94)
        XCTAssertEqual(ARM64.decodeMOVIzero(0x6F00_E403), 3)
        XCTAssertEqual(ARM64.decodeLDRd(0xFD40_AA94), ARM64.Mem(t: 20, n: 20, offset: 0x150))
    }

    func testADRPRoundTrip() {
        let pc: UInt64 = 0x1_0015_0EF0
        let page: UInt64 = 0x1_0036_F000
        let word = ARM64.adrp(d: 11, page: page, at: pc)
        XCTAssertEqual(word, 0xF000_10EB)
        XCTAssertEqual(ARM64.decodeADRP(word!, at: pc)?.page, page)
        XCTAssertEqual(ARM64.decodeADRP(word!, at: pc)?.d, 11)
    }
}
