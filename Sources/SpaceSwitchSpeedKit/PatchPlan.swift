// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

/// The five instructions Space Switch Speed rewrites, located by shape rather than by
/// address so the tool keeps working when Dock is recompiled — and refuses,
/// rather than guessing, when the shape it depends on is gone.
///
/// Stock preamble and loop:
///
///     adrp  xB, page              -> adrp  xB, scratch
///     ldr   dA, [xB, #immA]       -> ldr   dA, [xB, #0]      retention
///     movi  vK, #0                -> ldr   dK, [xB, #8]      gain
///     adrp  xB, page              (untouched; re-establishes xB)
///     ...
///     fsub  dE, dT, dP            error = target - position
///    [ldr   dV, [xS, #vel]]       velocity, when not already in a register
///     fmul  dV, dV, dA
///     fadd  dE, dE, dE            -> fmul  dE, dE, dK        gain, was x2
///     fadd  dN, dE, dV            new velocity, into dE or dV
///    [str   dN, [xS, #vel]]
///     fmul  dW, dDT, dN
///     fadd  dP, dP, dW
///     ...
///     fsub  dX, dK, dP            -> fneg  dX, dP            rubber band
///
/// The bracketed instructions are absent in builds that keep the velocity in a
/// register, and the multiplies' operands appear in either order, so the loop is
/// matched by data flow rather than by that exact sequence. See `findLoop`.
///
/// Repointing `xB` is safe only because the redundant `adrp` two instructions
/// later restores it before its next use; that is checked, not assumed.
public struct PatchSites {
    public enum State { case stock, patched }

    public let state: State
    public let adrpSite: UInt64
    public let retentionLoadSite: UInt64
    public let gainLoadSite: UInt64
    public let gainSite: UInt64
    public let bandSite: UInt64

    public let baseReg: UInt32
    public let retentionReg: UInt32
    public let gainReg: UInt32
    public let errorReg: UInt32
    public let positionReg: UInt32
    public let bandDestReg: UInt32

    /// Where the stock retention constant lives, and its `ldr` offset.
    public let stockConstPage: UInt64
    public let stockRetentionOffset: UInt32
    /// Scratch page currently in use, when already patched.
    public let scratchPage: UInt64?
    /// The `movi` that zeroed the gain register, as Apple encoded it. Two
    /// encodings occur in the wild, so revert restores this rather than
    /// reconstructing one of them and hoping it is the right one.
    public let stockGainZeroWord: UInt32?

    public var stockRetentionAddress: UInt64 { stockConstPage + UInt64(stockRetentionOffset) }
}

extension PatchSites {
    /// The five words `apply` writes, in the order it has to write them: the
    /// constant loads are rewritten before the base register is repointed, so no
    /// intermediate state reads a wrong address.
    public func patchWords(scratch: UInt64) throws -> [(address: UInt64, word: UInt32)] {
        guard let adrp = ARM64.adrp(d: baseReg, page: scratch, at: adrpSite) else {
            throw SpaceSwitchSpeedError.noReachableScratch
        }
        guard let retention = ARM64.ldrd(t: retentionReg, n: baseReg, offset: 0),
            let gain = ARM64.ldrd(t: gainReg, n: baseReg, offset: 8)
        else {
            throw SpaceSwitchSpeedError.encodingFailed("constant loads")
        }
        return [
            (retentionLoadSite, retention),
            (gainLoadSite, gain),
            (gainSite, ARM64.fmul(d: errorReg, n: errorReg, m: gainReg)),
            (bandSite, ARM64.fneg(d: bandDestReg, n: positionReg)),
            (adrpSite, adrp),
        ]
    }

    /// The five words `revert` writes to put Apple's own instructions back.
    /// `gainZero` is the encoding this build used, which is the one thing the
    /// patched state cannot be asked for. The `adrp` goes first, so the retention
    /// load never reads its stock offset off the scratch page, which is too small
    /// for it; the gain load goes last, so an interrupted revert still reads as
    /// patched rather than as stock with a spring that multiplies by zero.
    public func stockWords(gainZero: UInt32) throws -> [(address: UInt64, word: UInt32)] {
        guard let adrp = ARM64.adrp(d: baseReg, page: stockConstPage, at: adrpSite),
            let retention = ARM64.ldrd(t: retentionReg, n: baseReg, offset: stockRetentionOffset)
        else {
            throw SpaceSwitchSpeedError.encodingFailed("stock preamble")
        }
        return [
            (adrpSite, adrp),
            (retentionLoadSite, retention),
            (gainSite, ARM64.fadd(d: errorReg, n: errorReg, m: errorReg)),
            (bandSite, ARM64.fsub(d: bandDestReg, n: gainReg, m: positionReg)),
            (gainLoadSite, gainZero),
        ]
    }
}

public enum PatchLocator {
    /// How far back from the loop the preamble may sit, in instructions.
    private static let preambleWindow = 64
    /// How far into the loop the rubber-band branch may sit, in instructions.
    private static let loopWindow = 96

    public static func locate(target: DockTarget, image: MachOImage) throws -> PatchSites {
        let text = image.text
        let words = try readWords(target: target, address: text.address, size: Int(text.size))
        return try locate(words: words, base: text.address)
    }

    /// Shape matching over a `__text` image, independent of where the words came
    /// from, so the same matcher can be run against a Dock binary read from disk.
    public static func locate(words: [UInt32], base: UInt64) throws -> PatchSites {
        guard let loop = findLoop(words) else { throw SpaceSwitchSpeedError.signatureNotFound }
        guard
            let pre = findPreamble(
                words, base: base,
                loopIndex: loop.gainIndex, retentionReg: loop.retentionReg)
        else {
            throw SpaceSwitchSpeedError.signatureNotFound
        }
        guard
            let band = findBand(
                words, loopIndex: loop.gainIndex, gainReg: pre.gainReg, positionReg: loop.positionReg)
        else {
            throw SpaceSwitchSpeedError.signatureNotFound
        }

        let addr = { (i: Int) in base + UInt64(i) * 4 }

        // The gain register must survive from where it is established for as
        // long as it is live. Anything else writing it would silently corrupt
        // both, and anything else *reading* it would be depending on the zero the
        // patch replaces with the gain — which is the assumption borrowing the
        // register rests on, so it is checked rather than trusted. The rubber
        // band is the last use only while it is `fsub`; patched to `fneg`, it
        // leaves the gain in the register, so the scan carries on past it until
        // something redefines the register or the function returns.
        let returns: Set<UInt32> = [0xD65F_03C0, 0xD65F_0BFF, 0xD65F_0FFF]  // ret, retaa, retab
        let end = min(words.count - 1, loop.gainIndex + loopWindow)
        for i in (pre.gainLoadIndex + 1)...end where i != loop.gainIndex {
            if returns.contains(words[i]) { break }
            if writesFPRegister(words[i], pre.gainReg) {
                if i > band.index { break }
                throw SpaceSwitchSpeedError.unexpectedConstants(
                    "register d\(pre.gainReg) is overwritten at 0x\(String(addr(i), radix: 16))")
            }
            if i != band.index, readsFPRegister(words[i], pre.gainReg) {
                throw SpaceSwitchSpeedError.unexpectedConstants(
                    "register d\(pre.gainReg) is read at 0x\(String(addr(i), radix: 16))")
            }
        }

        return PatchSites(
            state: pre.state,
            adrpSite: addr(pre.adrpIndex),
            retentionLoadSite: addr(pre.retentionLoadIndex),
            gainLoadSite: addr(pre.gainLoadIndex),
            gainSite: addr(loop.gainIndex),
            bandSite: addr(band.index),
            baseReg: pre.baseReg,
            retentionReg: loop.retentionReg,
            gainReg: pre.gainReg,
            errorReg: loop.errorReg,
            positionReg: loop.positionReg,
            bandDestReg: band.destReg,
            stockConstPage: pre.stockPage,
            stockRetentionOffset: pre.stockOffset,
            scratchPage: pre.state == .patched ? pre.currentPage : nil,
            stockGainZeroWord: pre.gainZeroWord
        )
    }

    // MARK: - Signature matching

    private struct Loop { let gainIndex: Int, retentionReg: UInt32, errorReg: UInt32, positionReg: UInt32 }

    /// Matches the integrator by its data flow rather than by one fixed sequence
    /// of instructions, because what varies between Dock builds is the compiler's
    /// scheduling, not Apple's arithmetic. Measured against Dock 2341.0.1 through
    /// 2427.6, three things move and none of them change what the loop computes:
    /// the operands of the commutative multiplies swap, the velocity is sometimes
    /// carried in a register instead of being reloaded and stored each iteration,
    /// and the accumulate lands in either the error or the velocity register.
    ///
    /// The gain still anchors the match, and every other instruction is found by
    /// which register feeds it. Two matches remain a refusal.
    private static func findLoop(_ w: [UInt32]) -> Loop? {
        guard w.count >= 6 else { return nil }
        var hit: Loop?
        for j in 3..<(w.count - 3) {
            // The gain: the hardcoded doubling while stock, the `fmul` that
            // replaced it once patched.
            let errorReg: UInt32
            if let g = ARM64.decodeFAdd(w[j]), g.d == g.n, g.n == g.m {
                errorReg = g.d
            } else if let g = ARM64.decodeFMul(w[j]), g.d == g.n, g.m != g.n {
                errorReg = g.d
            } else {
                continue
            }

            // Immediately before it, the velocity is damped by the retention
            // constant. Either operand may be the register being damped.
            guard let damp = ARM64.decodeFMul(w[j - 1]) else { continue }
            let velocityReg: UInt32, retentionReg: UInt32
            if damp.d == damp.n {
                (velocityReg, retentionReg) = (damp.n, damp.m)
            } else if damp.d == damp.m {
                (velocityReg, retentionReg) = (damp.m, damp.n)
            } else {
                continue
            }
            guard velocityReg != errorReg else { continue }

            // The error, with the velocity either reloaded from the state struct
            // or already live in a register from the previous iteration.
            var load: ARM64.Mem?
            var subIndex = j - 2
            if let l = ARM64.decodeLDRd(w[j - 2]), l.t == velocityReg {
                load = l
                subIndex = j - 3
            }
            guard subIndex >= 0, let sub = ARM64.decodeFSub(w[subIndex]), sub.d == errorReg else { continue }
            let positionReg = sub.m

            // velocity = gain * error + retention * velocity, either way round.
            guard let acc = ARM64.decodeFAdd(w[j + 1]),
                (acc.n == errorReg && acc.m == velocityReg) || (acc.n == velocityReg && acc.m == errorReg)
            else { continue }
            let newVelocity = acc.d

            // The store back, when the velocity came from memory.
            var k = j + 2
            if let l = load, let stv = ARM64.decodeSTRd(w[k]),
                stv.t == newVelocity, stv.n == l.n, stv.offset == l.offset
            {
                k += 1
            }

            // position += dt * velocity.
            guard k + 1 < w.count else { continue }
            guard let step = ARM64.decodeFMul(w[k]), step.n == newVelocity || step.m == newVelocity
            else { continue }
            guard let adv = ARM64.decodeFAdd(w[k + 1]), adv.d == positionReg,
                (adv.n == positionReg && adv.m == step.d) || (adv.n == step.d && adv.m == positionReg)
            else { continue }

            // Two matches would mean the signature is not discriminating enough.
            if hit != nil { return nil }
            hit = Loop(
                gainIndex: j, retentionReg: retentionReg,
                errorReg: errorReg, positionReg: positionReg)
        }
        return hit
    }

    private struct Preamble {
        let state: PatchSites.State
        let adrpIndex: Int, retentionLoadIndex: Int, gainLoadIndex: Int
        let baseReg: UInt32, gainReg: UInt32
        let currentPage: UInt64, stockPage: UInt64, stockOffset: UInt32
        let gainZeroWord: UInt32?
    }

    private static func findPreamble(
        _ w: [UInt32], base: UInt64,
        loopIndex: Int, retentionReg: UInt32
    ) -> Preamble? {
        let lower = max(1, loopIndex - preambleWindow)
        var i = loopIndex - 1
        while i >= lower {
            defer { i -= 1 }
            let pc = { (k: Int) in base + UInt64(k) * 4 }

            // ldr dA, [xB, #imm] establishing the retention register.
            guard let ldr = ARM64.decodeLDRd(w[i]), ldr.t == retentionReg else { continue }
            guard let adrp = ARM64.decodeADRP(w[i - 1], at: pc(i - 1)), adrp.d == ldr.n else { continue }

            // The instruction after either zeroes a register (stock) or loads
            // the gain from the same base (already patched).
            let gainReg: UInt32
            let state: PatchSites.State
            var gainZeroWord: UInt32?
            if let k = ARM64.decodeMOVIzero(w[i + 1]) {
                gainReg = k
                state = .stock
                gainZeroWord = w[i + 1]
            } else if let g = ARM64.decodeLDRd(w[i + 1]), g.n == ldr.n, g.offset == 8, ldr.offset == 0 {
                gainReg = g.t
                state = .patched
            } else {
                continue
            }

            // The redundant adrp that re-establishes the base register. Without
            // it, repointing the base would corrupt every later constant load.
            guard let restore = ARM64.decodeADRP(w[i + 2], at: pc(i + 2)), restore.d == ldr.n else {
                continue
            }
            // The constant block is contiguous, so the stock retention offset is
            // recoverable from its neighbour. That is what makes revert possible
            // without persisting anything; refuse the patch if it does not hold.
            guard let neighbour = ARM64.decodeLDRd(w[i + 3]), neighbour.n == ldr.n, neighbour.offset >= 8
            else { continue }
            let recoveredOffset = neighbour.offset - 8
            if state == .stock && recoveredOffset != ldr.offset { continue }
            // The patch points the first adrp at scratch, so the two name different
            // pages once patched and the same page while stock. An interrupted
            // patch, its loads rewritten and its adrp not yet, has the patched
            // shape on one page; read as patched, Dock's own constant page would
            // become the scratch page and the next apply would write into it.
            guard (adrp.page == restore.page) == (state == .stock) else { continue }

            return Preamble(
                state: state,
                adrpIndex: i - 1, retentionLoadIndex: i, gainLoadIndex: i + 1,
                baseReg: ldr.n, gainReg: gainReg,
                currentPage: adrp.page, stockPage: restore.page,
                stockOffset: recoveredOffset, gainZeroWord: gainZeroWord)
        }
        return nil
    }

    private struct Band { let index: Int, destReg: UInt32 }

    private static func findBand(_ w: [UInt32], loopIndex: Int, gainReg: UInt32, positionReg: UInt32) -> Band?
    {
        for i in loopIndex..<min(w.count, loopIndex + loopWindow) {
            if let s = ARM64.decodeFSub(w[i]), s.n == gainReg, s.m == positionReg {
                return Band(index: i, destReg: s.d)
            }
            if w[i] & 0xFFFF_FC00 == 0x1E61_4000, (w[i] >> 5) & 0x1F == positionReg {
                return Band(index: i, destReg: w[i] & 0x1F)  // already fneg
            }
        }
        return nil
    }

    /// Conservative test for "this instruction reads scalar FP register `reg`".
    /// Covers the scalar floating-point data-processing space as a whole rather
    /// than decoding each form, since over-reporting only causes a refusal —
    /// except where a field that names a register in one form is an opcode or an
    /// immediate in another, which would refuse a build for a register nobody
    /// reads.
    static func readsFPRegister(_ w: UInt32, _ reg: UInt32) -> Bool {
        // Three sources: fmadd and its siblings.
        if w & 0x5F00_0000 == 0x1F00_0000 {
            return (w >> 5) & 0x1F == reg || (w >> 16) & 0x1F == reg || (w >> 10) & 0x1F == reg
        }
        guard w & 0x5F20_0000 == 0x1E20_0000 else { return false }
        let form = (w >> 10) & 0x3F
        // `fmov Dd, #imm` reads nothing, and the conversions from an integer
        // register (scvtf, ucvtf, fmov from general) read no FP register.
        if form & 0x7 == 0b100 { return false }
        if form == 0, [0b010, 0b011, 0b111].contains((w >> 16) & 0x7) { return false }
        // Bits 20:16 name a second source only in the two-source, conditional
        // and register-compare forms; elsewhere they are an opcode.
        let hasRm = form & 0x3 != 0 || (form == 0b001000 && (w >> 3) & 1 == 0)
        return (w >> 5) & 0x1F == reg || (hasRm && (w >> 16) & 0x1F == reg)
    }

    /// Conservative test for "this instruction writes scalar FP register `reg`".
    /// Over-reporting only causes a refusal, which is the safe direction; the
    /// compares and the conversions to an integer register write no FP register.
    static func writesFPRegister(_ w: UInt32, _ reg: UInt32) -> Bool {
        // 64-bit SIMD pair load, in any addressing mode, which writes two registers.
        if w & 0x7E40_0000 == 0x6C40_0000 { return w & 0x1F == reg || (w >> 10) & 0x1F == reg }
        guard w & 0x1F == reg else { return false }
        // Scalar FP data processing with three sources.
        if w & 0x5F00_0000 == 0x1F00_0000 { return true }
        // Scalar FP data processing with one or two sources, and conversions.
        if w & 0x5F20_0000 == 0x1E20_0000 {
            let form = (w >> 10) & 0x3F
            if form == 0 { return [0b010, 0b011, 0b111].contains((w >> 16) & 0x7) }
            return form & 0xF != 0b1000 && form & 0x3 != 0b01
        }
        // SIMD modified-immediate (movi and friends).
        if w & 0x9FF8_0000 == 0x0F00_0000 { return true }
        // Vector register moves such as mov.16b (orr with identical sources).
        if w & 0xBFE0_FC00 == 0x0EA0_1C00 { return true }
        // 64-bit SIMD loads: ldr d scaled, and ldur d, ldr d pre- and post-indexed.
        if w & 0xFFC0_0000 == 0xFD40_0000 { return true }
        if w & 0xFFE0_0000 == 0xFC40_0000 { return true }
        return false
    }

    private static func readWords(target: DockTarget, address: UInt64, size: Int) throws -> [UInt32] {
        try target.read(address, size).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}
