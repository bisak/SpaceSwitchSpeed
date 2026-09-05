// SpaceSwitch — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

/// The five instructions SpaceSwitch rewrites, located by shape rather than by
/// address so the tool keeps working when Dock is recompiled — and refuses,
/// rather than guessing, when the shape it depends on is gone.
///
/// Stock preamble and loop:
///
///     adrp  xB, page              -> adrp  xB, scratch
///     ldr   dA, [xB, #immA]       -> ldr   dA, [xB, #0]      retention
///     movi.2d vK, #0              -> ldr   dK, [xB, #8]      gain
///     adrp  xB, page              (untouched; re-establishes xB)
///     ...
///     fsub  dE, dT, dP            error = target - position
///     ldr   dV, [xS, #vel]
///     fmul  dV, dV, dA
///     fadd  dE, dE, dE            -> fmul  dE, dE, dK        gain, was x2
///     fadd  dE, dE, dV
///     str   dE, [xS, #vel]
///     fmul  dW, dDT, dE
///     fadd  dP, dP, dW
///     ...
///     fsub  dX, dK, dP            -> fneg  dX, dP            rubber band
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

    public var stockRetentionAddress: UInt64 { stockConstPage + UInt64(stockRetentionOffset) }
}

public enum PatchLocator {
    /// How far back from the loop the preamble may sit, in instructions.
    private static let preambleWindow = 64
    /// How far into the loop the rubber-band branch may sit, in instructions.
    private static let loopWindow = 96

    public static func locate(target: DockTarget, image: MachOImage) throws -> PatchSites {
        let text = try image.text
        let words = try readWords(target: target, address: text.address, size: Int(text.size))

        guard let loop = findLoop(words) else { throw SpaceSwitchError.signatureNotFound }
        guard let pre = findPreamble(words, base: text.address,
                                     loopIndex: loop.index, retentionReg: loop.retentionReg) else {
            throw SpaceSwitchError.signatureNotFound
        }
        guard let band = findBand(words, loopIndex: loop.index, gainReg: pre.gainReg, positionReg: loop.positionReg) else {
            throw SpaceSwitchError.signatureNotFound
        }

        let addr = { (i: Int) in text.address + UInt64(i) * 4 }

        // The gain register must survive from where it is established to the
        // rubber band. Anything else writing it would silently corrupt both.
        for i in (pre.gainLoadIndex + 1) ... band.index where i != loop.index + 3 {
            if writesFPRegister(words[i], pre.gainReg) {
                throw SpaceSwitchError.unexpectedConstants(
                    "register d\(pre.gainReg) is overwritten at 0x\(String(addr(i), radix: 16))")
            }
        }

        return PatchSites(
            state: pre.state,
            adrpSite: addr(pre.adrpIndex),
            retentionLoadSite: addr(pre.retentionLoadIndex),
            gainLoadSite: addr(pre.gainLoadIndex),
            gainSite: addr(loop.index + 3),
            bandSite: addr(band.index),
            baseReg: pre.baseReg,
            retentionReg: loop.retentionReg,
            gainReg: pre.gainReg,
            errorReg: loop.errorReg,
            positionReg: loop.positionReg,
            bandDestReg: band.destReg,
            stockConstPage: pre.stockPage,
            stockRetentionOffset: pre.stockOffset,
            scratchPage: pre.state == .patched ? pre.currentPage : nil
        )
    }

    // MARK: - Signature matching

    private struct Loop { let index: Int, retentionReg: UInt32, errorReg: UInt32, positionReg: UInt32 }

    /// Matches the eight-instruction integrator core. The self-doubling `fadd`
    /// (or, once patched, the `fmul` that replaced it) anchors the match.
    private static func findLoop(_ w: [UInt32]) -> Loop? {
        var hit: Loop?
        for i in 0 ..< (w.count - 8) {
            guard let sub = ARM64.decodeFSub(w[i]) else { continue }
            guard let ldv = ARM64.decodeLDRd(w[i + 1]) else { continue }
            guard let mul = ARM64.decodeFMul(w[i + 2]),
                  mul.d == ldv.t, mul.n == ldv.t else { continue }

            let isStockGain = ARM64.decodeFAdd(w[i + 3]).map { $0.d == sub.d && $0.n == sub.d && $0.m == sub.d } ?? false
            let isPatchedGain = ARM64.decodeFMul(w[i + 3]).map { $0.d == sub.d && $0.n == sub.d } ?? false
            guard isStockGain || isPatchedGain else { continue }

            guard let acc = ARM64.decodeFAdd(w[i + 4]), acc.d == sub.d, acc.n == sub.d, acc.m == ldv.t else { continue }
            guard let stv = ARM64.decodeSTRd(w[i + 5]), stv.t == sub.d, stv.n == ldv.n, stv.offset == ldv.offset else { continue }
            guard let step = ARM64.decodeFMul(w[i + 6]), step.m == sub.d else { continue }
            guard let adv = ARM64.decodeFAdd(w[i + 7]), adv.d == sub.m, adv.n == sub.m, adv.m == step.d else { continue }

            // Two matches would mean the signature is not discriminating enough.
            if hit != nil { return nil }
            hit = Loop(index: i, retentionReg: mul.m, errorReg: sub.d, positionReg: sub.m)
        }
        return hit
    }

    private struct Preamble {
        let state: PatchSites.State
        let adrpIndex: Int, retentionLoadIndex: Int, gainLoadIndex: Int
        let baseReg: UInt32, gainReg: UInt32
        let currentPage: UInt64, stockPage: UInt64, stockOffset: UInt32
    }

    private static func findPreamble(_ w: [UInt32], base: UInt64,
                                    loopIndex: Int, retentionReg: UInt32) -> Preamble? {
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
            if let k = ARM64.decodeMOVIzero(w[i + 1]) {
                gainReg = k
                state = .stock
            } else if let g = ARM64.decodeLDRd(w[i + 1]), g.n == ldr.n, g.offset == 8, ldr.offset == 0 {
                gainReg = g.t
                state = .patched
            } else { continue }

            // The redundant adrp that re-establishes the base register. Without
            // it, repointing the base would corrupt every later constant load.
            guard let restore = ARM64.decodeADRP(w[i + 2], at: pc(i + 2)), restore.d == ldr.n else { continue }
            // The constant block is contiguous, so the stock retention offset is
            // recoverable from its neighbour. That is what makes revert possible
            // without persisting anything; refuse the patch if it does not hold.
            guard let neighbour = ARM64.decodeLDRd(w[i + 3]), neighbour.n == ldr.n, neighbour.offset >= 8 else { continue }
            let recoveredOffset = neighbour.offset - 8
            if state == .stock && recoveredOffset != ldr.offset { continue }

            return Preamble(state: state,
                            adrpIndex: i - 1, retentionLoadIndex: i, gainLoadIndex: i + 1,
                            baseReg: ldr.n, gainReg: gainReg,
                            currentPage: adrp.page, stockPage: restore.page,
                            stockOffset: recoveredOffset)
        }
        return nil
    }

    private struct Band { let index: Int, destReg: UInt32 }

    private static func findBand(_ w: [UInt32], loopIndex: Int, gainReg: UInt32, positionReg: UInt32) -> Band? {
        for i in loopIndex ..< min(w.count, loopIndex + loopWindow) {
            if let s = ARM64.decodeFSub(w[i]), s.n == gainReg, s.m == positionReg { return Band(index: i, destReg: s.d) }
            if w[i] & 0xFFFF_FC00 == 0x1E61_4000, (w[i] >> 5) & 0x1F == positionReg {
                return Band(index: i, destReg: w[i] & 0x1F)      // already fneg
            }
        }
        return nil
    }

    /// Conservative test for "this instruction writes scalar FP register `reg`".
    /// Over-reporting only causes a refusal, which is the safe direction.
    private static func writesFPRegister(_ w: UInt32, _ reg: UInt32) -> Bool {
        guard w & 0x1F == reg else { return false }
        // Scalar FP data processing (one, two and three source), and conversions.
        if w & 0x5F20_0000 == 0x1E20_0000 { return true }
        // SIMD modified-immediate (movi and friends).
        if w & 0x9FF8_0000 == 0x0F00_0000 { return true }
        // Vector register moves such as mov.16b (orr with identical sources).
        if w & 0xBFE0_FC00 == 0x0EA0_1C00 { return true }
        // 64-bit SIMD loads: ldr d, ldur d, ldp d.
        if w & 0xFFC0_0000 == 0xFD40_0000 { return true }
        if w & 0xFFE0_0C00 == 0xFC40_0000 { return true }
        if w & 0x7FC0_0000 == 0x6D40_0000 { return true }
        return false
    }

    private static func readWords(target: DockTarget, address: UInt64, size: Int) throws -> [UInt32] {
        var words = [UInt32]()
        words.reserveCapacity(size / 4)
        var offset = 0
        let chunk = 1 << 20
        while offset < size {
            let n = min(chunk, size - offset)
            let data = try target.read(address + UInt64(offset), n)
            data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: n - 3, by: 4) {
                    words.append(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))
                }
            }
            offset += n
        }
        return words
    }
}
