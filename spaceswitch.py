#!/usr/bin/env python3
"""
Space-switch speed control for macOS.

macOS times the Space transition with two hardcoded 0.25 second constants in
Dock, and exposes no preference for either:

  transition   the duration Dock uses for its own Space transition
  crossfade    the value Dock sends WindowServer over XPC as "xfade-duration",
               which times the space transform and alpha blend

Both are `fmov d0, #0.25` immediates. This tool rewrites them together, so the
two phases stay in step, and lets you pick any duration in between rather than
only on or off.

    --speed 1     stock macOS, 250 ms
    --speed 0.5   half as long, 125 ms
    --speed 0     instant

The value is a straight multiplier on the stock duration, so 1 leaves macOS
alone and 0 removes the animation entirely. Durations shorter than one display
frame are indistinguishable from instant and only add latency, so they snap to
zero.

The ARM64 `fmov` immediate cannot encode anything between 0 and 0.125 s, which
is most of the useful range. For those values the tool rewrites the instruction
as a PC-relative `ldr d0, <literal>` and stores a full double in unused padding
between __auth_stubs and __objc_stubs. Stock and instant use the compact
encodings instead, so the smallest edit that expresses the value is the one
applied.

Sites are located by the instructions that follow them, which the patch does not
disturb. That makes the tool idempotent: it reads back whatever is currently
installed and can move to any other value, including all the way back to stock.
"""

import argparse
import ctypes
import ctypes.util
import struct
import subprocess
import sys

TEXT_VMBASE = 0x100000000
STOCK_SECONDS = 0.25

# Instruction encodings, little-endian words.
MOVI_D0_ZERO = 0x2F00E400          # movi d0, #0
FMOV_D0_BASE = 0x1E601000          # fmov d0, #<imm8>, Rd=0
FMOV_D0_MASK = 0xFFE01FFF
LDR_D0_BASE = 0x5C000000           # ldr d0, <pc-relative literal>
LDR_D0_MASK = 0xFF00001F

# Bytes that must follow each site. None matches any byte. These pin the two
# call sites down uniquely and are never modified.
SITES = {
    "transition": (0xA8, None, None, 0xD1, None, 0x01, None, 0xF8),
    "crossfade": (0xE0, 0x03, 0x13, 0xAA, 0xE1, 0x03, 0x15, 0xAA,
                  0xF4, 0x03, 0x1B, 0xAA),
}

# Sixteen bytes of zero padding between __TEXT,__auth_stubs and
# __TEXT,__objc_stubs. Within PC-relative literal reach of both sites.
POOL_VMADDR = 0x100343010
POOL_SIZE = 16


# ---------------------------------------------------------------- encodings

def fp_imm8_to_double(imm8):
    """Expand an AArch64 8-bit floating-point immediate to its double value."""
    a = (imm8 >> 7) & 1
    b = (imm8 >> 6) & 1
    c = (imm8 >> 5) & 1
    d = (imm8 >> 4) & 1
    efgh = imm8 & 0xF
    exp = ((1 - b) << 10) | ((0xFF if b else 0) << 2) | (c << 1) | d
    bits = (a << 63) | (exp << 52) | (efgh << 48)
    return struct.unpack("<d", struct.pack("<Q", bits))[0]


FMOV_TABLE = {}
for _i in range(256):
    FMOV_TABLE.setdefault(fp_imm8_to_double(_i), _i)


def encode_fmov(value):
    """Return the fmov word for value, or None if it is not representable."""
    imm8 = FMOV_TABLE.get(value)
    if imm8 is None:
        return None
    return FMOV_D0_BASE | (imm8 << 13)


def encode_ldr(site_vmaddr, pool_vmaddr):
    delta = pool_vmaddr - site_vmaddr
    if delta % 4:
        raise ValueError("literal is not 4-byte aligned relative to the site")
    imm19 = delta >> 2
    if not -(1 << 18) <= imm19 < (1 << 18):
        raise ValueError("literal is out of PC-relative range")
    return LDR_D0_BASE | ((imm19 & 0x7FFFF) << 5)


def decode(word, site_vmaddr, pool_reader):
    """Describe the instruction currently installed at a site.

    Returns (seconds, form) where seconds is None if unrecognized.
    """
    if word == MOVI_D0_ZERO:
        return 0.0, "movi"
    if (word & FMOV_D0_MASK) == FMOV_D0_BASE:
        return fp_imm8_to_double((word >> 13) & 0xFF), "fmov"
    if (word & LDR_D0_MASK) == LDR_D0_BASE:
        imm19 = (word >> 5) & 0x7FFFF
        if imm19 & (1 << 18):
            imm19 -= 1 << 19
        target = site_vmaddr + imm19 * 4
        raw = pool_reader(target, 8)
        if raw is None:
            return None, "ldr(unreadable)"
        return struct.unpack("<d", raw)[0], "ldr"
    return None, "unknown"


# ------------------------------------------------------------------ Mach-O

class DockImage:
    """The arm64 slice of a Dock binary, addressed by virtual address."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as fh:
            self.data = bytearray(fh.read())
        self.slice_off, self.slice_size = self._find_arm64()

    def _find_arm64(self):
        magic, = struct.unpack(">I", self.data[:4])
        if magic not in (0xCAFEBABE, 0xCAFEBABF):
            return 0, len(self.data)
        count, = struct.unpack(">I", self.data[4:8])
        entry = 32 if magic == 0xCAFEBABF else 20
        for i in range(count):
            base = 8 + i * entry
            if magic == 0xCAFEBABF:
                cpu, _s, off, size = struct.unpack(">IIQQ", self.data[base:base + 24])
            else:
                cpu, _s, off, size, _a = struct.unpack(">5I", self.data[base:base + 20])
            if cpu == 0x0100000C:
                return off, size
        raise SystemExit("no arm64 slice in %s" % self.path)

    def file_off(self, vmaddr):
        return self.slice_off + (vmaddr - TEXT_VMBASE)

    def read(self, vmaddr, n):
        o = self.file_off(vmaddr)
        return bytes(self.data[o:o + n])

    def write(self, vmaddr, blob):
        o = self.file_off(vmaddr)
        self.data[o:o + len(blob)] = blob

    def word(self, vmaddr):
        return struct.unpack("<I", self.read(vmaddr, 4))[0]

    def find_sites(self):
        """Locate each site by its trailing signature. Returns {name: vmaddr}."""
        body = bytes(self.data[self.slice_off:self.slice_off + self.slice_size])
        out = {}
        for name, suffix in SITES.items():
            hits = []
            for pos in range(0, len(body) - 4 - len(suffix), 4):
                tail = body[pos + 4:pos + 4 + len(suffix)]
                if all(w is None or tail[i] == w for i, w in enumerate(suffix)):
                    word, = struct.unpack("<I", body[pos:pos + 4])
                    known = (word == MOVI_D0_ZERO
                             or (word & FMOV_D0_MASK) == FMOV_D0_BASE
                             or (word & LDR_D0_MASK) == LDR_D0_BASE)
                    if known:
                        hits.append(TEXT_VMBASE + pos)
            if len(hits) != 1:
                raise SystemExit("%s: expected 1 site, found %d %s"
                                 % (name, len(hits), [hex(h) for h in hits]))
            out[name] = hits[0]
        return out

    def save(self, path=None):
        with open(path or self.path, "wb") as fh:
            fh.write(self.data)


# ------------------------------------------------------------------- misc

def refresh_hz():
    """Main display refresh rate, or None when the system does not report one."""
    try:
        cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
        cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
        cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
        cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
        mode = cg.CGDisplayCopyDisplayMode(cg.CGMainDisplayID())
        if not mode:
            return None
        hz = cg.CGDisplayModeGetRefreshRate(mode)
        return hz if hz > 0 else None
    except Exception:
        return None


def ms(seconds):
    return "%.1f ms" % (seconds * 1000.0)


# ------------------------------------------------------------------- plan

def build_plan(img, sites, target_seconds):
    """Decide the instruction and pool writes needed to reach target_seconds."""
    writes = []
    if target_seconds == 0.0:
        word = MOVI_D0_ZERO
        form = "movi d0, #0"
        pool = None
    else:
        word = encode_fmov(target_seconds)
        if word is not None:
            form = "fmov d0, #%g" % target_seconds
            pool = None
        else:
            form = "ldr d0, <literal>"
            pool = struct.pack("<d", target_seconds)

    for name, vmaddr in sorted(sites.items()):
        w = encode_ldr(vmaddr, POOL_VMADDR) if pool is not None else word
        writes.append((name, vmaddr, struct.pack("<I", w)))

    # The slot is ours only if a site currently points at it.
    owned = any(
        (img.word(v) & LDR_D0_MASK) == LDR_D0_BASE for v in sites.values()
    )

    pool_write = None
    if pool is not None:
        current = img.read(POOL_VMADDR, POOL_SIZE)
        if not owned and any(b != 0 for b in current):
            raise SystemExit(
                "the literal slot at 0x%x is not empty and was not written by this "
                "tool; refusing to reuse it" % POOL_VMADDR)
        pool_write = (POOL_VMADDR, pool + b"\0" * (POOL_SIZE - len(pool)))
    elif owned:
        # Moving to an encoding that needs no literal. Hand the padding back so
        # returning to stock leaves the binary byte-identical to Apple's.
        pool_write = (POOL_VMADDR, b"\0" * POOL_SIZE)
    return writes, pool_write, form


def report_current(img, sites):
    reader = lambda a, n: img.read(a, n)
    rows = []
    for name, vmaddr in sorted(sites.items()):
        secs, form = decode(img.word(vmaddr), vmaddr, reader)
        rows.append((name, vmaddr, secs, form))
    return rows


# ------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary",
                    default="/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--speed", type=float, metavar="0..1",
                   help="1 = stock macOS (default), 0 = instant")
    g.add_argument("--ms", type=float, metavar="MILLISECONDS",
                   help="set the duration directly")
    g.add_argument("--show", action="store_true",
                   help="report what is currently installed")
    ap.add_argument("--apply", action="store_true",
                    help="write the change (default is a dry run)")
    ap.add_argument("--output", help="write to this path instead of in place")
    ap.add_argument("--emit-lldb", action="store_true",
                    help="print memory writes for patching a running Dock")
    args = ap.parse_args()

    img = DockImage(args.binary)
    sites = img.find_sites()

    hz = refresh_hz()
    frame = 1.0 / hz if hz else None

    print("Dock: %s" % args.binary)
    for name, vmaddr, secs, form in report_current(img, sites):
        shown = "unrecognized" if secs is None else ms(secs)
        print("  %-11s 0x%x  %-14s %s" % (name, vmaddr, shown, form))

    if args.show or (args.speed is None and args.ms is None):
        if hz:
            print("\nDisplay refreshes at %.4g Hz, one frame is %s." % (hz, ms(frame)))
        print("\nNothing requested. Use --speed 0..1 or --ms.")
        return 0

    if args.speed is not None:
        if not 0.0 <= args.speed <= 1.0:
            raise SystemExit("--speed must be between 0 and 1")
        target = STOCK_SECONDS * args.speed
        asked = "speed %g" % args.speed
    else:
        target = args.ms / 1000.0
        if target < 0:
            raise SystemExit("--ms must not be negative")
        asked = "%g ms" % args.ms

    note = ""
    if frame and 0 < target < frame:
        note = " (below one %s frame, snapped to instant)" % ms(frame).strip()
        target = 0.0

    print("\nRequested %s -> %s%s" % (asked, ms(target), note))

    writes, pool_write, form = build_plan(img, sites, target)
    print("Encoding : %s" % form)

    for name, vmaddr, blob in writes:
        print("  %-11s 0x%x <- %s" % (name, vmaddr, blob.hex(" ")))
    if pool_write:
        print("  %-11s 0x%x <- %s" % ("literal", pool_write[0],
                                      pool_write[1][:8].hex(" ")))

    if args.emit_lldb:
        # Machine-readable plan for the runtime patcher: one
        # "WRITE <offset-from-image-base> <hex>" line per edit.
        for _n, vmaddr, blob in writes:
            print("WRITE %#x %s" % (vmaddr - TEXT_VMBASE, blob.hex()))
        if pool_write:
            print("WRITE %#x %s" % (pool_write[0] - TEXT_VMBASE,
                                    pool_write[1].hex()))

    if not args.apply:
        print("\nDry run. Re-run with --apply to write.")
        return 0

    for _n, vmaddr, blob in writes:
        img.write(vmaddr, blob)
    if pool_write:
        img.write(pool_write[0], pool_write[1])
    img.save(args.output)
    print("\nWrote %s" % (args.output or args.binary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
