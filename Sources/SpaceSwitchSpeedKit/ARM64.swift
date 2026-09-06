// Space Switch Speed — speed control for the macOS Space-switch animation.
// Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
// See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.

import Foundation

/// The handful of AArch64 encodings this tool reads and writes.
///
/// Only scalar-double arithmetic, 64-bit SIMD load/store and `adrp` are needed.
/// Decoders return `nil` rather than trapping so a pattern scan can simply walk
/// every word in `__text`.
public enum ARM64 {
    public struct Reg3: Equatable { public let d: UInt32, n: UInt32, m: UInt32 }
    public struct Mem: Equatable { public let t: UInt32, n: UInt32, offset: UInt32 }

    // MARK: Scalar double, three registers

    private static func decode3(_ w: UInt32, _ base: UInt32) -> Reg3? {
        guard w & 0xFFE0_FC00 == base else { return nil }
        return Reg3(d: w & 0x1F, n: (w >> 5) & 0x1F, m: (w >> 16) & 0x1F)
    }
    private static func encode3(_ base: UInt32, _ d: UInt32, _ n: UInt32, _ m: UInt32) -> UInt32 {
        base | (m << 16) | (n << 5) | d
    }

    public static func decodeFAdd(_ w: UInt32) -> Reg3? { decode3(w, 0x1E60_2800) }
    public static func decodeFSub(_ w: UInt32) -> Reg3? { decode3(w, 0x1E60_3800) }
    public static func decodeFMul(_ w: UInt32) -> Reg3? { decode3(w, 0x1E60_0800) }

    public static func fmul(d: UInt32, n: UInt32, m: UInt32) -> UInt32 { encode3(0x1E60_0800, d, n, m) }
    public static func fadd(d: UInt32, n: UInt32, m: UInt32) -> UInt32 { encode3(0x1E60_2800, d, n, m) }
    public static func fsub(d: UInt32, n: UInt32, m: UInt32) -> UInt32 { encode3(0x1E60_3800, d, n, m) }

    /// `fneg Dd, Dn`
    public static func fneg(d: UInt32, n: UInt32) -> UInt32 { 0x1E61_4000 | (n << 5) | d }

    // MARK: 64-bit SIMD load/store, unsigned scaled offset

    public static func decodeLDRd(_ w: UInt32) -> Mem? {
        guard w & 0xFFC0_0000 == 0xFD40_0000 else { return nil }
        return Mem(t: w & 0x1F, n: (w >> 5) & 0x1F, offset: ((w >> 10) & 0xFFF) * 8)
    }
    public static func decodeSTRd(_ w: UInt32) -> Mem? {
        guard w & 0xFFC0_0000 == 0xFD00_0000 else { return nil }
        return Mem(t: w & 0x1F, n: (w >> 5) & 0x1F, offset: ((w >> 10) & 0xFFF) * 8)
    }

    /// `ldr Dt, [Xn, #offset]` — offset must be a multiple of 8 below 32 KiB.
    public static func ldrd(t: UInt32, n: UInt32, offset: UInt32) -> UInt32? {
        guard offset % 8 == 0, offset / 8 <= 0xFFF else { return nil }
        return 0xFD40_0000 | ((offset / 8) << 10) | (n << 5) | t
    }

    // MARK: Immediates and addressing

    /// `movi Vd.2d, #0` and `movi Dd, #0`, which differ only in `Q`. Both leave
    /// the register's upper half zero, so `ldr Dd` substitutes for either; which
    /// one the compiler picks has moved between Dock builds.
    public static func decodeMOVIzero(_ w: UInt32) -> UInt32? {
        let masked = w & 0xFFFF_FFE0
        return masked == 0x6F00_E400 || masked == 0x2F00_E400 ? w & 0x1F : nil
    }

    public static func decodeADRP(_ w: UInt32, at pc: UInt64) -> (d: UInt32, page: UInt64)? {
        guard w & 0x9F00_0000 == 0x9000_0000 else { return nil }
        let immlo = (w >> 29) & 0x3
        let immhi = (w >> 5) & 0x7FFFF
        var imm = Int64((immhi << 2) | immlo)
        if imm & (1 << 20) != 0 { imm -= (1 << 21) }  // sign-extend 21 bits
        return (w & 0x1F, UInt64(Int64(pc & ~0xFFF) + imm * 0x1000))
    }

    /// `adrp Xd, page` — fails when the target is beyond ±4 GiB of `pc`.
    public static func adrp(d: UInt32, page: UInt64, at pc: UInt64) -> UInt32? {
        let delta = Int64(bitPattern: page & ~0xFFF) - Int64(bitPattern: pc & ~0xFFF)
        guard delta % 0x1000 == 0 else { return nil }
        let imm = delta / 0x1000
        guard imm >= -(1 << 20) && imm < (1 << 20) else { return nil }
        let u = UInt32(bitPattern: Int32(imm)) & 0x1FFFFF
        return 0x9000_0000 | ((u & 0x3) << 29) | ((u >> 2) << 5) | d
    }
}
