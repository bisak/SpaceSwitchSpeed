#!/usr/bin/env python3
"""
Space-switch speed control for macOS.

The Space transition has no duration. Dock animates it with a leaky integrator
that runs on its own `space-switcher` dispatch queue:

    velocity = gain * (target - position) + A * velocity
    position += timestep * velocity

with gain = 2 and A = 0.695. Settling time is proportional to (1 - A), so
lowering that term speeds the whole transition up proportionally. This is why
macOS exposes no setting and why there is no constant to zero: the animation
ends when the spring settles, not when a clock runs out.

    --speed 1     stock macOS
    --speed 0.5   settles twice as fast
    --speed 0.25  four times as fast

The value is a straight multiplier on settling time. It is clamped at the fast
end, because A approaching 1 means momentum that never decays, which overshoots
and oscillates instead of arriving.

A is not an instruction immediate but a double in __TEXT,__const, loaded by
`ldr d2, [x11, #0x5d0]`. Dock reads that same constant from four places, so
overwriting it in place would also retime unrelated animations. Instead this
repoints only the integrator's own load to eight unused bytes of inter-section
padding and stores the chosen value there. Everything else keeps 0.695.

The integrator is found by a unique 32-byte signature of its inner loop, so the
patch does not depend on fixed offsets.
"""

import argparse
import struct
import sys

TEXT_VMBASE = 0x100000000

# Inner loop of the integrator: fsub / ldr / fmul / fadd / fadd / str / fmul / fadd.
# Unique in the arm64e slice, and untouched by the patch.
ANCHOR = bytes.fromhex(
    "3338711e94aa40fd940a621e732a731e732a741e93aa00fd1409731e312a741e"
)
ANCHOR_TO_LDR = -0x38            # the `ldr d2, [x11, #imm]` sits 0x38 before it

STOCK_A = 0.695                  # Apple's velocity-retention value
GAIN = 2.0                       # hardcoded stiffness: `fadd d19, d19, d19`
A_CEILING = 0.97                 # past here the ringing stops being subtle

LDR_FP64_BASE = 0xFD400000       # ldr dT, [xN, #imm12*8]
LDR_FP64_MASK = 0xFFC00000


def ldr_fields(word):
    """Decode ldr dT, [xN, #imm] -> (Rt, Rn, byte_offset), or None."""
    if (word & LDR_FP64_MASK) != LDR_FP64_BASE:
        return None
    return word & 0x1F, (word >> 5) & 0x1F, ((word >> 10) & 0xFFF) * 8


def ldr_encode(rt, rn, byte_off):
    if byte_off % 8 or not 0 <= byte_off // 8 < 4096:
        raise ValueError("offset 0x%x not encodable" % byte_off)
    return LDR_FP64_BASE | ((byte_off // 8) << 10) | (rn << 5) | rt


def adrp_page(word, pc):
    """Decode adrp xN, <page> -> absolute page address."""
    if (word & 0x9F000000) != 0x90000000:
        return None
    immlo = (word >> 29) & 3
    immhi = (word >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


class DockImage:
    """The arm64 slice of a Dock binary, addressed by virtual address."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as fh:
            self.data = bytearray(fh.read())
        self.slice_off, self.slice_size = self._find_arm64()
        self.sects = self._sections()

    def _find_arm64(self):
        magic, = struct.unpack(">I", self.data[:4])
        if magic not in (0xCAFEBABE, 0xCAFEBABF):
            return 0, len(self.data)
        count, = struct.unpack(">I", self.data[4:8])
        entry = 32 if magic == 0xCAFEBABF else 20
        for i in range(count):
            b = 8 + i * entry
            if magic == 0xCAFEBABF:
                cpu, _s, off, size = struct.unpack(">IIQQ", self.data[b:b + 24])
            else:
                cpu, _s, off, size, _a = struct.unpack(">5I", self.data[b:b + 20])
            if cpu == 0x0100000C:
                return off, size
        raise SystemExit("no arm64 slice in %s" % self.path)

    def _sections(self):
        m = self.data[self.slice_off:self.slice_off + self.slice_size]
        ncmds, _sz = struct.unpack_from("<II", m, 16)
        out, p = [], 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", m, p)
            if cmd == 0x19:
                nsects, = struct.unpack_from("<I", m, p + 64)
                sp = p + 72
                for _s in range(nsects):
                    name = m[sp:sp + 16].rstrip(b"\0").decode()
                    addr, size = struct.unpack_from("<QQ", m, sp + 32)
                    out.append((name, addr, size))
                    sp += 80
            p += cmdsize
        return sorted(out, key=lambda s: s[1])

    def off(self, vm):
        return self.slice_off + (vm - TEXT_VMBASE)

    def read(self, vm, n):
        return bytes(self.data[self.off(vm):self.off(vm) + n])

    def write(self, vm, blob):
        self.data[self.off(vm):self.off(vm) + len(blob)] = blob

    def word(self, vm):
        return struct.unpack("<I", self.read(vm, 4))[0]

    def find_ldr_site(self):
        body = bytes(self.data[self.slice_off:self.slice_off + self.slice_size])
        hits = []
        i = body.find(ANCHOR)
        while i >= 0:
            hits.append(TEXT_VMBASE + i)
            i = body.find(ANCHOR, i + 4)
        if len(hits) != 1:
            raise SystemExit("integrator signature matched %d times; "
                             "this build is not supported" % len(hits))
        return hits[0] + ANCHOR_TO_LDR

    def stock_slot(self, page, exclude):
        """Locate Apple's own 0.695 constant, so a revert can point back at it."""
        found = []
        for a in range(page, page + 4096 * 8, 8):
            if a == exclude:
                continue
            try:
                v, = struct.unpack("<d", self.read(a, 8))
            except struct.error:
                break
            if v == STOCK_A:
                found.append(a)
        return found[0] if len(found) == 1 else None

    def free_slot(self, page, owned=None):
        """Eight bytes in an inter-section gap reachable from `page`.

        A slot already pointed at by the integrator (`owned`) counts as free:
        it holds our previous value, so re-tuning must be able to reuse it.
        """
        window = range(page, page + 4096 * 8)
        for (n1, a1, s1), (n2, a2, _s2) in zip(self.sects, self.sects[1:]):
            gap_start, gap_end = a1 + s1, a2
            slot = (gap_start + 7) & ~7
            if slot + 8 > gap_end or slot not in window:
                continue
            if slot == owned or all(b == 0 for b in self.read(slot, 8)):
                return slot, "%s -> %s" % (n1, n2)
        return None, None

    def save(self, path=None):
        with open(path or self.path, "wb") as fh:
            fh.write(self.data)


def response(a, refresh=120.0):
    """Say whether the discrete system rings at this retention value.

    e[n+1] = (1 - dt*G) e[n] - dt*A v[n];  v[n+1] = G e[n] + A v[n]
    Characteristic roots are complex (oscillatory) when (1+A-dt*G)^2 < 4A.
    Stock sits just barely on the non-oscillating side, so every speed-up
    crosses over; what matters is how fast the ringing decays, |lambda| = sqrt(A).
    """
    tr = 1.0 + a - GAIN / refresh
    disc = tr * tr - 4.0 * a
    if disc >= 0:
        return "no overshoot"
    decay = a ** 0.5
    kind = "subtle ringing" if decay < 0.965 else "visible ringing"
    return "%s, decays %.1f%% per step" % (kind, (1 - decay) * 100)


def describe(img, site):
    """Return (damping, where, is_patched) for the current state."""
    w = img.word(site)
    f = ldr_fields(w)
    if not f:
        return None, "unrecognised instruction 0x%08x" % w, None
    rt, rn, boff = f
    page = adrp_page(img.word(site - 4), site - 4)
    if page is None:
        return None, "adrp not found before the load", None
    addr = page + boff
    val, = struct.unpack("<d", img.read(addr, 8))
    return val, addr, addr


def plan(img, site, target_a):
    """Writes needed to install target_a. Returns (writes, note)."""
    page = adrp_page(img.word(site - 4), site - 4)
    rt, rn, cur_off = ldr_fields(img.word(site))
    cur_addr = page + cur_off

    slot, gap = img.free_slot(page, owned=cur_addr)

    if abs(target_a - STOCK_A) < 1e-12:
        # Back to stock: point the load at Apple's constant and clear our slot.
        stock = img.stock_slot(page, exclude=slot)
        if cur_addr != slot:
            return [], "already stock"
        if stock is None:
            raise SystemExit("could not locate Apple's 0.695 constant to revert to; "
                             "restart Dock instead")
        return ([(site, struct.pack("<I", ldr_encode(rt, rn, stock - page)), "load"),
                 (slot, b"\0" * 8, "clear")],
                "restoring the original constant at 0x%x" % stock)

    if slot is None:
        raise SystemExit("no reachable padding slot for the constant")
    writes = [(slot, struct.pack("<d", target_a), "damping"),
              (site, struct.pack("<I", ldr_encode(rt, rn, slot - page)), "load")]
    return writes, "slot 0x%x in padding (%s)" % (slot, gap)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary",
                    default="/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--speed", type=float, metavar="0..1",
                   help="1 = stock macOS, lower = faster settle")
    g.add_argument("--damping", type=float, metavar="A",
                   help="set the retention constant A directly (advanced)")
    g.add_argument("--show", action="store_true")
    ap.add_argument("--apply", action="store_true", help="write it (default: dry run)")
    ap.add_argument("--output")
    ap.add_argument("--emit-lldb", action="store_true",
                    help="print writes for the runtime patcher")
    args = ap.parse_args()

    img = DockImage(args.binary)
    site = img.find_ldr_site()
    cur, addr, _ = describe(img, site)

    print("Dock: %s" % args.binary)
    print("  integrator load  0x%x -> constant at 0x%x" % (site, addr))
    if cur is None:
        print("  state            %s" % addr)
        return 1
    eff = (1 - cur) / (1 - STOCK_A)
    print("  retention A      %.6f   (settling x%.2f vs stock)" % (cur, eff))
    print("  response         %s" % response(cur))

    if args.show or (args.speed is None and args.damping is None):
        print("\nNothing requested. Use --speed 0..1 or --damping A.")
        return 0

    if args.damping is not None:
        target = args.damping
        if not 0.0 <= target < 1.0:
            raise SystemExit("--damping must be in [0, 1)")
        asked = "damping %g" % target
    else:
        if not 0.0 <= args.speed <= 1.0:
            raise SystemExit("--speed must be between 0 and 1")
        target = 1.0 - (1.0 - STOCK_A) * args.speed
        asked = "speed %g" % args.speed

    note = ""
    if target > A_CEILING:
        target = A_CEILING
        note = " (clamped at A=%.2f; beyond this the spring overshoots)" % A_CEILING

    got = (1 - target) / (1 - STOCK_A)
    print("\nRequested %s -> damping %.6f, settling x%.2f vs stock%s"
          % (asked, target, got, note))

    writes, where = plan(img, site, target)
    if not writes:
        print("Nothing to write (%s)." % where)
        return 0
    print("Storage  : %s" % where)
    for vm, blob, what in writes:
        print("  %-8s 0x%x <- %s" % (what, vm, blob.hex(" ")))

    if args.emit_lldb:
        for vm, blob, _w in writes:
            print("WRITE %#x %s" % (vm - TEXT_VMBASE, blob.hex()))

    if not args.apply:
        print("\nDry run. Re-run with --apply to write.")
        return 0

    for vm, blob, _w in writes:
        img.write(vm, blob)
    img.save(args.output)
    print("\nWrote %s" % (args.output or args.binary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
