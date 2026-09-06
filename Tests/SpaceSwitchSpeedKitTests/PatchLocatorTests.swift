// Space Switch Speed — speed control for the macOS Space-switch animation.
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
    /// Apple shipped it, including which `movi` encoding zeroed the gain, using
    /// the very words the engine writes and in the order it writes them: the
    /// loads before the `adrp` that repoints them, the `adrp` first on the way back.
    @Test("patch and revert restore the stock words", arguments: fixtures)
    func roundTrip(_ f: Fixture) throws {
        var w = f.words
        let sites = try PatchLocator.locate(words: w, base: f.base)
        func index(_ site: UInt64) -> Int { Int((site - f.base) / 4) }

        let scratch = (f.base &+ 0x1000_0000) & ~0xFFF
        let patch = try sites.patchWords(scratch: scratch)
        #expect(
            patch.map(\.address) == [
                sites.retentionLoadSite, sites.gainLoadSite, sites.gainSite, sites.bandSite, sites.adrpSite,
            ])
        for (address, word) in patch { w[index(address)] = word }

        // The patched image must still locate, at the same sites, with the
        // scratch page recoverable from the rewritten adrp alone.
        let after = try PatchLocator.locate(words: w, base: f.base)
        #expect(after.state == .patched)
        #expect(after.scratchPage == scratch)
        #expect(after.gainSite == sites.gainSite)
        #expect(after.bandSite == sites.bandSite)
        #expect(after.stockRetentionOffset == sites.stockRetentionOffset)
        #expect(after.stockConstPage == sites.stockConstPage)

        let stock = try after.stockWords(gainZero: f.gainZero)
        #expect(stock.first?.address == after.adrpSite)
        for (address, word) in stock { w[index(address)] = word }
        #expect(w == f.words)
    }

    /// An interrupted patch leaves the loads rewritten and the `adrp` still
    /// stock: the patched shape with both `adrp`s naming the same page. Read as
    /// patched, Dock's own constant page would become the scratch page, so every
    /// such prefix is refused instead.
    @Test("a half-applied patch is refused, not read as patched", arguments: fixtures)
    func halfApplied(_ f: Fixture) throws {
        let sites = try PatchLocator.locate(words: f.words, base: f.base)
        let patch = try sites.patchWords(scratch: (f.base &+ 0x1000_0000) & ~0xFFF)
        for count in 1..<patch.count {
            var w = f.words
            for (address, word) in patch.prefix(count) { w[Int((address - f.base) / 4)] = word }
            #expect(throws: SpaceSwitchSpeedError.self, "\(count) of \(patch.count) words written") {
                _ = try PatchLocator.locate(words: w, base: f.base)
            }
        }

        // And the other way: no prefix of the revert may read as stock either,
        // since stock means revert has nothing to do.
        var patched = f.words
        for (address, word) in patch { patched[Int((address - f.base) / 4)] = word }
        let stock = try PatchLocator.locate(words: patched, base: f.base).stockWords(gainZero: f.gainZero)
        for count in 1..<stock.count {
            var w = patched
            for (address, word) in stock.prefix(count) { w[Int((address - f.base) / 4)] = word }
            #expect(throws: SpaceSwitchSpeedError.self, "\(count) of \(stock.count) words restored") {
                _ = try PatchLocator.locate(words: w, base: f.base)
            }
        }
    }

    /// The stock guard reads the retention through the first `adrp` and the
    /// code reads it through the second; they must agree or the guard checks
    /// nothing.
    @Test("stock adrps naming different pages are refused", arguments: fixtures)
    func mismatchedPages(_ f: Fixture) throws {
        let sites = try PatchLocator.locate(words: f.words, base: f.base)
        var w = f.words
        w[Int((sites.adrpSite - f.base) / 4)] = try #require(
            ARM64.adrp(d: sites.baseReg, page: sites.stockConstPage + 0x1000, at: sites.adrpSite))
        #expect(throws: SpaceSwitchSpeedError.self) {
            _ = try PatchLocator.locate(words: w, base: f.base)
        }
    }

    /// The patch borrows the register the stock code zeroes for the rubber
    /// band, so anything else touching that register is a refusal: before the
    /// band, and after it too, since `fneg` leaves the gain there, until
    /// something redefines it.
    @Test("touching the borrowed register is refused", arguments: fixtures)
    func borrowedRegister(_ f: Fixture) throws {
        let sites = try PatchLocator.locate(words: f.words, base: f.base)
        func index(_ site: UInt64) -> Int { Int((site - f.base) / 4) }
        let k = sites.gainReg
        let before = index(sites.gainLoadSite) + 3  // a redundant adrp nothing checks
        let after = index(sites.bandSite) + 1

        let refused: [(what: String, at: Int, word: UInt32)] = [
            ("fmul writing it", before, ARM64.fmul(d: k, n: 0, m: 1)),
            ("fadd reading it", before, ARM64.fadd(d: 5, n: k, m: 0)),
            ("fmadd writing it", before, Self.fmadd(d: k, n: 0, m: 1, a: 2)),
            ("fmadd reading it as the addend", before, Self.fmadd(d: 5, n: 0, m: 1, a: k)),
            ("fmov #imm writing it", before, 0x1E60_1000 | (0x70 << 13) | k),
            ("fadd reading it after the band", after, ARM64.fadd(d: 5, n: k, m: 0)),
            (
                "a rubber band that writes it", index(sites.bandSite),
                ARM64.fsub(d: k, n: k, m: sites.positionReg)
            ),
        ]
        for edit in refused {
            var w = f.words
            w[edit.at] = edit.word
            #expect(throws: SpaceSwitchSpeedError.self, "\(edit.what)") {
                _ = try PatchLocator.locate(words: w, base: f.base)
            }
        }

        let accepted: [(what: String, at: Int, word: UInt32)] = [
            ("fmov #imm whose immediate spells the register", before, 0x1E60_1000 | (k << 16) | 7),
            ("a write after the band, which ends its live range", after, ARM64.fmul(d: k, n: 0, m: 1)),
        ]
        for edit in accepted {
            var w = f.words
            w[edit.at] = edit.word
            #expect(throws: Never.self, "\(edit.what)") {
                _ = try PatchLocator.locate(words: w, base: f.base)
            }
        }

        // Dock returns with `retab`; nothing after a return can depend on the register.
        var w = f.words
        w[after] = 0xD65F_0FFF
        w[after + 1] = ARM64.fadd(d: 5, n: k, m: 0)
        #expect(throws: Never.self, "a read after the function returns") {
            _ = try PatchLocator.locate(words: w, base: f.base)
        }
    }

    private static func fmadd(d: UInt32, n: UInt32, m: UInt32, a: UInt32) -> UInt32 {
        0x1F40_0000 | (m << 16) | (a << 10) | (n << 5) | d
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
