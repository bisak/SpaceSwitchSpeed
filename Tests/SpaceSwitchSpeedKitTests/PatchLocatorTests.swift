// SpaceSwitchSpeed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Testing

@testable import SpaceSwitchSpeedKit

/// The integrator as six shipping Dock builds actually compiled it.
///
/// What differs between them is only the compiler's scheduling — the operands of
/// the commutative multiplies, whether the velocity is reloaded each iteration or
/// kept in a register, and which of the two `movi` encodings zeroes the gain — so
/// these windows are the regression net for `findLoop` being matched by data flow
/// rather than by one fixed sequence. Windows are the instructions from the
/// preamble through the rubber band, taken from `__text` at their real addresses
/// so `adrp` still decodes correctly.
@Suite("Patch locator")
struct PatchLocatorTests {
    struct Fixture {
        let build: String
        let base: UInt64
        let adrp: UInt64, gain: UInt64, band: UInt64
        let baseReg: UInt32, retentionReg: UInt32, gainReg: UInt32
        let errorReg: UInt32, positionReg: UInt32
        let gainZero: UInt32
        let words: [UInt32]
    }

    static let fixtures: [Fixture] = [
        Fixture(
            build: "15.0 / 24A335",
            base: 0x10014043c,
            adrp: 0x10014045c, gain: 0x1001404a0, band: 0x1001404e0,
            baseReg: 10, retentionReg: 2, gainReg: 3, errorReg: 20, positionReg: 17,
            gainZero: 0x2f00e403,
            words: [
                0xfd402280, 0x9e620103, 0x1e680863, 0x1e632842, 0xfd001682, 0xf100055f,
                0x540007eb, 0xfd40aa85, 0xd000102a, 0xfd411d42, 0x2f00e403, 0xd000102a,
                0xfd412144, 0xd000102a, 0xfd412946, 0xb000102a, 0xfd47ad47, 0x1e6e1010,
                0x1e7e1012, 0xd000102a, 0x1e604011, 0xfd412553, 0xb40007c8, 0x1e713834,
                0x1e6208a5, 0x1e742a94, 0x1e652a85, 0x1e6808b4, 0x1e742a31, 0x37000129,
                0xfd401a95, 0x2f00e414, 0x1e6122a0, 0x1e714420, 0x540004c4, 0x1e752020,
                0x1e614620, 0x54000464, 0x1e602228, 0x1e6408b4, 0x54000085, 0x1e713875,
                0x1e660aa5, 0x14000005, 0x1e702220, 0x5400016d,
            ]),
        Fixture(
            build: "15.6.1 / 24G90",
            base: 0x100139a8c,
            adrp: 0x100139aac, gain: 0x100139af0, band: 0x100139b30,
            baseReg: 11, retentionReg: 2, gainReg: 3, errorReg: 20, positionReg: 17,
            gainZero: 0x2f00e403,
            words: [
                0xfd402280, 0x9e630123, 0x1e680863, 0x1e632842, 0xfd001682, 0xf100051f,
                0x5400080b, 0xfd40aa84, 0xb000100b, 0xfd453162, 0x2f00e403, 0xb000100b,
                0xfd453565, 0xb000100b, 0xfd453d66, 0xb000100b, 0xfd43b567, 0x1e6e1010,
                0x1e7e1012, 0xb000100b, 0x1e604011, 0xfd453973, 0xb40007e9, 0x1e713834,
                0x1e620884, 0x1e742a94, 0x1e642a84, 0x1e680894, 0x1e742a31, 0x3700012a,
                0xfd401a95, 0x2f00e414, 0x1e6122a0, 0x1e714420, 0x540004e4, 0x1e752020,
                0x1e614620, 0x54000484, 0x1e602228, 0x1e650894, 0x54000085, 0x1e713875,
                0x1e660aa4, 0x14000005, 0x1e702220, 0x5400016d,
            ]),
        Fixture(
            build: "26.0 / 25A354",
            base: 0x10014df3c,
            adrp: 0x10014df5c, gain: 0x10014dfa4, band: 0x10014dfe4,
            baseReg: 11, retentionReg: 2, gainReg: 3, errorReg: 19, positionReg: 17,
            gainZero: 0x2f00e403,
            words: [
                0x5280000a, 0xfd402280, 0x9e630123, 0x1e680863, 0x1e632842, 0xfd001682,
                0xf100051f, 0x5400080b, 0xf00010eb, 0xfd417162, 0x2f00e403, 0xf00010eb,
                0xfd417564, 0xf00010eb, 0xfd417d65, 0xd00010eb, 0xfd47b566, 0x1e6e1007,
                0x1e7e1010, 0xf00010eb, 0x1e604011, 0xfd417972, 0xb4000749, 0x1e713833,
                0xfd40aa94, 0x1e620a94, 0x1e732a73, 0x1e742a73, 0xfd00aa93, 0x1e680a74,
                0x1e742a31, 0x3700010a, 0xfd401a94, 0x1e612280, 0x1e714420, 0x54000424,
                0x1e742020, 0x1e614620, 0x540003c4, 0x1e602228, 0x1e640a74, 0x54000085,
                0x1e713873, 0x1e650a75, 0x14000005, 0x1e672220, 0x5400012d,
            ]),
        Fixture(
            build: "26.2 / 25C56",
            base: 0x10014f038,
            adrp: 0x10014f058, gain: 0x10014f0a0, band: 0x10014f0e0,
            baseReg: 11, retentionReg: 2, gainReg: 3, errorReg: 19, positionReg: 17,
            gainZero: 0x2f00e403,
            words: [
                0x5280000a, 0xfd402280, 0x9e630123, 0x1e680863, 0x1e632842, 0xfd001682,
                0xf100051f, 0x5400080b, 0xf000110b, 0xfd45b962, 0x2f00e403, 0xf000110b,
                0xfd45bd64, 0xf000110b, 0xfd45c565, 0xf000110b, 0xfd43f966, 0x1e6e1007,
                0x1e7e1010, 0xf000110b, 0x1e604011, 0xfd45c172, 0xb4000749, 0x1e713833,
                0xfd40aa94, 0x1e620a94, 0x1e732a73, 0x1e742a73, 0xfd00aa93, 0x1e680a74,
                0x1e742a31, 0x3700010a, 0xfd401a94, 0x1e612280, 0x1e714420, 0x54000424,
                0x1e742020, 0x1e614620, 0x540003c4, 0x1e602228, 0x1e640a74, 0x54000085,
                0x1e713873, 0x1e650a75, 0x14000005, 0x1e672220, 0x5400012d,
            ]),
        Fixture(
            build: "26.4 / 25E246",
            base: 0x100150ed0,
            adrp: 0x100150ef0, gain: 0x100150f38, band: 0x100150f78,
            baseReg: 11, retentionReg: 2, gainReg: 3, errorReg: 19, positionReg: 17,
            gainZero: 0x6f00e403,
            words: [
                0x5280000a, 0xfd402280, 0x9e630123, 0x1e630903, 0x1e632842, 0xfd001682,
                0xf100051f, 0x5400080b, 0xf00010eb, 0xfd42f162, 0x6f00e403, 0xf00010eb,
                0xfd42f564, 0xf00010eb, 0xfd42fd65, 0xf00010eb, 0xfd413166, 0x1e6e1007,
                0x1e7e1010, 0x4ea01c11, 0xf00010eb, 0xfd42f972, 0xb4000749, 0x1e713833,
                0xfd40aa94, 0x1e620a94, 0x1e732a73, 0x1e742a73, 0xfd00aa93, 0x1e730914,
                0x1e742a31, 0x3700010a, 0xfd401a94, 0x1e612280, 0x1e714420, 0x54000424,
                0x1e742020, 0x1e614620, 0x540003c4, 0x1e602228, 0x1e640a74, 0x54000085,
                0x1e713873, 0x1e650a75, 0x14000005, 0x1e672220, 0x5400012d,
            ]),
        Fixture(
            build: "26.6.2 / 25G83",
            base: 0x100150ed0,
            adrp: 0x100150ef0, gain: 0x100150f38, band: 0x100150f78,
            baseReg: 11, retentionReg: 2, gainReg: 3, errorReg: 19, positionReg: 17,
            gainZero: 0x6f00e403,
            words: [
                0x5280000a, 0xfd402280, 0x9e630123, 0x1e630903, 0x1e632842, 0xfd001682,
                0xf100051f, 0x5400080b, 0xf00010eb, 0xfd42e962, 0x6f00e403, 0xf00010eb,
                0xfd42ed64, 0xf00010eb, 0xfd42f565, 0xf00010eb, 0xfd412966, 0x1e6e1007,
                0x1e7e1010, 0x4ea01c11, 0xf00010eb, 0xfd42f172, 0xb4000749, 0x1e713833,
                0xfd40aa94, 0x1e620a94, 0x1e732a73, 0x1e742a73, 0xfd00aa93, 0x1e730914,
                0x1e742a31, 0x3700010a, 0xfd401a94, 0x1e612280, 0x1e714420, 0x54000424,
                0x1e742020, 0x1e614620, 0x540003c4, 0x1e602228, 0x1e640a74, 0x54000085,
                0x1e713873, 0x1e650a75, 0x14000005, 0x1e672220, 0x5400012d,
            ]),
    ]

    @Test("the integrator is located in every shipping build", arguments: fixtures)
    func locates(_ f: Fixture) throws {
        let sites = try PatchLocator.locate(words: f.words, base: f.base)
        #expect(sites.state == .stock)
        #expect(sites.adrpSite == f.adrp)
        #expect(sites.gainSite == f.gain)
        #expect(sites.bandSite == f.band)
        #expect(sites.baseReg == f.baseReg)
        #expect(sites.retentionReg == f.retentionReg)
        #expect(sites.gainReg == f.gainReg)
        #expect(sites.errorReg == f.errorReg)
        #expect(sites.positionReg == f.positionReg)
        #expect(sites.stockGainZeroWord == f.gainZero)
    }

    /// Applying and undoing the patch has to leave Dock's `__text` exactly as
    /// Apple shipped it, including which `movi` encoding zeroed the gain.
    @Test("patch and revert restore the stock words", arguments: fixtures)
    func roundTrip(_ f: Fixture) throws {
        var w = f.words
        let sites = try PatchLocator.locate(words: w, base: f.base)
        func index(_ site: UInt64) -> Int { Int((site - f.base) / 4) }

        let scratch = (f.base &+ 0x1000_0000) & ~0xFFF
        let adrp = try #require(ARM64.adrp(d: sites.baseReg, page: scratch, at: sites.adrpSite))
        let loadA = try #require(ARM64.ldrd(t: sites.retentionReg, n: sites.baseReg, offset: 0))
        let loadG = try #require(ARM64.ldrd(t: sites.gainReg, n: sites.baseReg, offset: 8))

        w[index(sites.retentionLoadSite)] = loadA
        w[index(sites.gainLoadSite)] = loadG
        w[index(sites.gainSite)] = ARM64.fmul(d: sites.errorReg, n: sites.errorReg, m: sites.gainReg)
        w[index(sites.bandSite)] = ARM64.fneg(d: sites.bandDestReg, n: sites.positionReg)
        w[index(sites.adrpSite)] = adrp

        // The patched image must still locate, at the same sites, with the
        // scratch page recoverable from the rewritten adrp alone.
        let after = try PatchLocator.locate(words: w, base: f.base)
        #expect(after.state == .patched)
        #expect(after.scratchPage == scratch)
        #expect(after.gainSite == sites.gainSite)
        #expect(after.bandSite == sites.bandSite)
        #expect(after.stockRetentionOffset == sites.stockRetentionOffset)
        #expect(after.stockConstPage == sites.stockConstPage)

        let backAdrp = try #require(
            ARM64.adrp(d: after.baseReg, page: after.stockConstPage, at: after.adrpSite))
        let backLoadA = try #require(
            ARM64.ldrd(t: after.retentionReg, n: after.baseReg, offset: after.stockRetentionOffset))
        w[index(after.adrpSite)] = backAdrp
        w[index(after.retentionLoadSite)] = backLoadA
        w[index(after.gainLoadSite)] = f.gainZero
        w[index(after.gainSite)] = ARM64.fadd(d: after.errorReg, n: after.errorReg, m: after.errorReg)
        w[index(after.bandSite)] = ARM64.fsub(
            d: after.bandDestReg, n: after.gainReg, m: after.positionReg)

        #expect(w == f.words)
    }

    /// Uniqueness is the only thing standing between the tool and the three other
    /// springs Dock inlines from the same source, so a second match must refuse
    /// rather than pick one.
    @Test("a second candidate is refused, not guessed")
    func ambiguityRefuses() throws {
        let f = Self.fixtures[0]
        #expect(throws: SpaceSwitchSpeedError.self) {
            _ = try PatchLocator.locate(words: f.words + f.words, base: f.base)
        }
    }

    /// Both encodings zero the register; Dock has shipped each of them.
    @Test("both movi encodings are recognised")
    func moviEncodings() {
        #expect(ARM64.decodeMOVIzero(0x6F00_E403) == 3)  // movi.2d v3, #0
        #expect(ARM64.decodeMOVIzero(0x2F00_E403) == 3)  // movi   d3, #0
        #expect(ARM64.decodeMOVIzero(0x1E60_2800) == nil)
    }
}

extension PatchLocatorTests.Fixture: CustomTestStringConvertible {
    var testDescription: String { build }
}
