#!/usr/bin/env python3
# Renders the README banner into docs/images/banner.webp.
#
#   make banner
#       build build/banner/banner.html, capture every frame of it with
#       headless Chrome, and encode the animation
#   python3 Scripts/make-banner.py --html
#       only build the HTML, for previewing in a browser (it loops there)
#   python3 Scripts/make-banner.py --states default.png gentle.png balanced.png quick.png instant.png
#       prepare docs/images/banner-source from window screenshots (Shift-Cmd-4,
#       Space, click the window) taken at each preset, then render
#
# Everything else in it is Apple's: the type is SF Pro, and both the MacBook
# Pro and the desktops on its screen are cut from the macOS Tahoe press images
# on Apple Newsroom, fetched at render time into build/banner. None of it is
# committed.
#
# The piece is one loop. At Default the desktops swipe right, right, left,
# left with Dock's own integrator and Apple's constants, Control held down and
# the arrow tapped for each one while three fingers flick the way the content
# goes, the cursor drags the slider to Quick with the window snapping between
# the real screenshots as the knob passes each tick, the same four swipes play
# at the same rhythm with the coefficients Space Switch Speed writes for 0.35,
# and the cursor drags back.

import base64
import functools
import io
import json
import math
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "images" / "banner.webp"
SOURCE_DIR = ROOT / "docs" / "images" / "banner-source"
WORK_DIR = ROOT / "build" / "banner"
HTML = WORK_DIR / "banner.html"

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# Apple's macOS Tahoe press images: a straight-on MacBook Pro on a flat
# background, one desktop each. The first is also the device itself, so the
# frame and the desktops that slide across it share one geometry.
NEWSROOM = (
    "https://www.apple.com/newsroom/images/2025/06/"
    "macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/article/"
    "Apple-WWDC25-macOS-Tahoe-26-{}-250609_big.jpg.slideshow-xlarge_2x.jpg"
)
DESKTOPS = ["Messages", "Apple-Intelligence-Shortcuts-Notes", "Apple-Music"]
FRAME = DESKTOPS[0]
# The bezel is pure black and the background a flat near-white, which is what
# the screen and the body are cut along. The level is as high as it goes
# before the wallpaper's darkest corners start reading as bezel.
BEZEL = (0, 0, 0)
BEZEL_LEVEL = 12
BACKGROUND_TOLERANCE = 12
MATTE = (255, 0, 255)

# The slider's presets, as Speed.presets orders them, and where each knob sits
# in the 2x window screenshots. The two in SHOWN get their own swipes and the
# ones between them appear as the knob snaps past during the drag; the rest are
# shot anyway, so SHOWN can be moved without going back for screenshots.
STATES = [("default", 1.0), ("gentle", 0.75), ("balanced", 0.5), ("quick", 0.35), ("instant", 0.2)]
SHOWN = [0, 3]
WINDOW_SIZE = (720, 232)
KNOB_X = [115.5 + i * 123 for i in range(len(STATES))]
KNOB_Y = 171

STOCK_RETENTION = 0.695
STOCK_GAIN = 2.0
SETTLE_EPSILON = 0.01
DT = 1 / 120
SPEED_RANGE = (0.2, 1.0)

SIZE = (1792, 592)
FPS = 25
OUTPUT_WIDTH = 1792
# The page is laid out at the output's own size, so it is captured at 1x and
# the artwork carries the detail instead: the device, the screen and its mask
# are cut at 2x for the browser to sample down.
CAPTURE_SCALE = 1
ASSET_SCALE = 2

# The device sits in from the right edge as far as the title sits in from the
# left, and the title is sized to leave a gutter between the two of them.
DEVICE_WIDTH = 700
DEVICE_RIGHT_MARGIN = 96
LEFT_MARGIN = 96
TITLE_SIZE = 84
WINDOW_TOP = 348
WINDOW_WIDTH = 560

CURSOR_REST = (30, 36)
FADE = 0.06

# The screen's spill onto the background. A CSS blur is rasterised at the
# size it ends up on screen, so blurring the strip live costs more than the
# rest of the frame put together; the desktops are blurred once at a fraction
# of the size instead and the browser only has to scale them up.
GLOW_SPREAD = 3.2
GLOW_BLUR = 60
GLOW_STEP = 6
GLOW_OPACITY = 0.38
GLOW_FALLOFF = "50%"

# The shortcut and the gesture that do the switch, played as each swipe
# starts: Control goes down for the whole burst, the arrow taps, and the hand
# flicks the way the content travels, which is the opposite way to the Space
# you are going to.
KEY_LEAD = 0.08
KEY_TAP = 0.18
KEY_FADE = 0.02
KEY_IDLE = "background: #191b21; color: #8f96a3;"
KEY_LIT = "background: #f2f3f5; color: #16181d;"
FLICK = 0.17
HAND_TRAVEL = 11


def coefficients(speed):
    power = 1 / min(max(speed, SPEED_RANGE[0]), SPEED_RANGE[1])
    a = STOCK_RETENTION
    trace = 1 + a - DT * STOCK_GAIN
    discriminant = trace * trace - 4 * a
    retention = a**power
    if discriminant >= 0:
        root = math.sqrt(discriminant)
        scaled = ((trace + root) / 2) ** power + ((trace - root) / 2) ** power
    else:
        angle = math.acos(trace / (2 * math.sqrt(a)))
        scaled = 2 * a ** (power / 2) * math.cos(angle * power)
    return (1 + retention - scaled) / DT, retention


def ease_in_out(u):
    return 4 * u**3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2


def ease_time(p):
    lo, hi = 0.0, 1.0
    for _ in range(40):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if ease_in_out(mid) < p else (lo, mid)
    return (lo + hi) / 2


# MARK: - Sources


def prepare_states(paths):
    if len(paths) != len(STATES):
        raise SystemExit(f"--states needs {len(STATES)} screenshots: " + ", ".join(n for n, _ in STATES))
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    for path, (name, _) in zip(paths, STATES):
        shot = Image.open(path).convert("RGBA")
        alpha = shot.split()[3].point(lambda v: 255 if v > 250 else 0)
        window = shot.crop(alpha.getbbox())
        if window.size != WINDOW_SIZE:
            raise SystemExit(f"{path}: window is {window.size}, expected {WINDOW_SIZE}")
        erase_cursor(window)
        window.save(SOURCE_DIR / f"{name}.png")
        print(f"{name}: prepared from {path}")


def erase_cursor(window):
    # The arrow is the only near-black thing in the content area right of
    # the "Speed" label and left of the hare; the blue fill has a
    # high green channel and the text is grey. Above the track the window is
    # plain white. Where the cursor overlaps the track, the track rows are
    # rebuilt from a column just outside the cursor's extent.
    px = window.load()
    hits = [
        (x, y)
        for x in range(260, 630)
        for y in range(75, 215)
        if px[x, y][0] < 60 and px[x, y][1] < 60 and px[x, y][3] == 255
    ]
    if not hits:
        return
    pad = 8
    x0 = min(x for x, _ in hits) - pad
    y0 = min(y for _, y in hits) - pad
    x1 = max(x for x, _ in hits) + pad
    y1 = max(y for _, y in hits) + pad
    window.paste((255, 255, 255, 255), (x0, y0, x1 + 1, y1 + 1))
    if y1 >= 158:
        donor = x1 + 30
        for y in range(158, 205):
            for x in range(x0, x1 + 1):
                px[x, y] = px[donor, y]


@functools.cache
def press(name):
    jpg = WORK_DIR / f"newsroom-{name}.jpg"
    if not jpg.exists():
        print(f"fetching {name} from Apple Newsroom")
        urllib.request.urlretrieve(NEWSROOM.format(name), jpg)
    return Image.open(jpg).convert("RGB")


def display_area(shot):
    # Everything the bezel encloses, so the corner radius and the notch's
    # cutout are the device's own shape rather than an approximation of it.
    # The wallpaper's own near-black pixels are as dark as the bezel, so the
    # lit region is flooded from the middle of the screen and then the holes
    # that leaves are filled by flooding the outside and keeping what it
    # cannot reach. The notch is not a hole: it opens onto the bezel.
    lit = Image.eval(shot.convert("L"), lambda v: 255 if v >= BEZEL_LEVEL else 0)
    ImageDraw.floodfill(lit, (shot.width // 2, shot.height // 2), 128)
    inside = lit.point(lambda v: 255 if v == 128 else 0)
    around = ImageOps.invert(inside)
    ImageDraw.floodfill(around, (0, 0), 128)
    return ImageChops.lighter(inside, around.point(lambda v: 255 if v == 255 else 0))


def notch_area(display, rect):
    hole = ImageOps.invert(display.crop(rect))
    ImageDraw.floodfill(hole, ((rect[2] - rect[0]) // 2, 0), 128)
    return hole.point(lambda v: 255 if v == 128 else 0).getbbox()


def device_frame(shot, display):
    # The MacBook off its background, with the screen blanked: the wallpaper
    # arrives later, on the strip that slides behind the screen's mask.
    flood = shot.copy()
    for seed in ((0, 0), (shot.width - 1, 0)):
        ImageDraw.floodfill(flood, seed, MATTE, thresh=BACKGROUND_TOLERANCE)
    background = None
    for channel, value in zip(flood.split(), MATTE):
        hit = channel.point(lambda v, value=value: 255 if v == value else 0)
        background = hit if background is None else ImageChops.multiply(background, hit)
    alpha = ImageOps.invert(background).filter(ImageFilter.MinFilter(5))
    frame = shot.copy()
    frame.paste(BEZEL, (0, 0), display)
    # Scaling the frame down samples a few pixels either side of the cut, so
    # the background has to be pushed back out of their reach first.
    for _ in range(3):
        frame = Image.composite(frame, frame.filter(ImageFilter.MinFilter(3)), alpha)
    frame.putalpha(alpha)
    return frame


def desktop(name, rect, notch):
    # The notch is hardware, and hardware does not travel with the Space, so
    # it comes back out of the content: the wallpaper the press shot shows
    # just below the cutout is drawn up through it.
    image = press(name).crop(rect)
    px = image.load()
    x0, y0, x1, y1 = notch
    for x in range(x0, x1):
        under = px[x, y1]
        for y in range(y0, y1):
            px[x, y] = under
    return image


# MARK: - Timeline


class Timeline:
    """Runs Dock's integrator continuously, so a swipe that lands while the
    previous one is still settling behaves as it does on a real Mac."""

    def __init__(self):
        self.t = 0.0
        self.pos = 0.0
        self.v = 0.0
        self.target = 0.0
        self.gain, self.retention = coefficients(1.0)
        self.positions = []
        self.switches = []
        self.cursor = []
        self.taps = []
        self.holds = []

    def step(self):
        self.v = self.gain * (self.target - self.pos) + self.retention * self.v
        self.pos += DT * self.v
        # Dock stops stepping once |velocity| drops under its epsilon and the
        # remaining fraction of a pixel is never drawn, so snap the same way.
        if abs(self.v) < SETTLE_EPSILON:
            self.pos, self.v = self.target, 0.0
        self.t += DT
        self.positions.append(self.pos)

    def wait(self, seconds):
        until = self.t + seconds
        while self.t < until:
            self.step()

    def swipe(self, target):
        self.taps.append((self.t, 1 if target > self.target else -1))
        self.target = target

    def settle(self):
        while self.pos != self.target:
            self.step()

    def set_speed(self, speed):
        self.gain, self.retention = coefficients(speed)

    def cursor_at(self, x, y, scale=1.0, easing="linear"):
        self.cursor.append((self.t, x, y, scale, easing))

    def switch(self, at, a, b):
        self.switches.append((at, a, b))

    def hold(self, since):
        self.holds.append((since, self.t))

    def strip_keyframes(self):
        step = round(1 / DT / FPS)
        return [(i * DT, p) for i, p in enumerate(self.positions) if i % step == 0] + [(self.t, self.pos)]


# Both bursts are swiped at one rhythm, which is the whole point. The rhythm is
# a whole stock switch, 0.867s of travel and a beat: Default fills it and Quick
# spends most of it at rest. Anything shorter cuts Default off before it lands
# and undersells how long the animation this exists to shorten actually takes.
SWIPES = [1, 2, 1, 0]
SWIPE_CADENCE = 0.9


def build_timeline(knob, rest):
    tl = Timeline()
    pitch = knob[1][0] - knob[0][0]

    tl.cursor_at(*rest(SHOWN[0]))
    for n, i in enumerate(SHOWN):
        tl.set_speed(STATES[i][1])
        burst = tl.t
        for target in SWIPES:
            tl.swipe(target)
            tl.wait(SWIPE_CADENCE)
        tl.hold(burst)
        tl.settle()
        tl.wait(0.3)

        target = SHOWN[(n + 1) % len(SHOWN)]
        tl.cursor_at(*rest(i), easing="ease-out")
        tl.wait(0.28)
        tl.cursor_at(*knob[i], easing="ease-out")
        tl.wait(0.06)
        tl.cursor_at(*knob[i], 0.9, easing="ease-in-out")
        seconds = 0.15 + 0.15 * abs(target - i)
        start = tl.t
        for k in range(min(i, target), max(i, target)):
            crossing = (knob[k][0] + pitch / 2 - knob[i][0]) / (knob[target][0] - knob[i][0])
            at = start + seconds * ease_time(crossing)
            tl.switch(at, k if target > i else k + 1, k + 1 if target > i else k)
        tl.wait(seconds)
        tl.cursor_at(*knob[target], 0.9, easing="ease-out")
        tl.wait(0.06)
        tl.cursor_at(*knob[target], easing="ease-in-out")
        tl.wait(0.22)
        tl.cursor_at(*rest(target))
    return tl


# MARK: - HTML


def keyframes(name, rows):
    return f"@keyframes {name} {{\n" + "\n".join(rows) + "\n}"


def pct(t, total):
    return f"{100 * min(max(t, 0), total) / total:.4f}%"


def lit_rows(spans, total):
    # A span that starts before the loop does clamps onto 0%, where it has to
    # win over the resting row, so the generated rows come after it.
    rows = [f"  0% {{ {KEY_IDLE} }}"]
    for down, up in spans:
        for at, style in (
            (down - KEY_FADE, KEY_IDLE),
            (down + KEY_FADE, KEY_LIT),
            (up - KEY_FADE, KEY_LIT),
            (up + KEY_FADE, KEY_IDLE),
        ):
            rows.append(f"  {pct(at, total)} {{ {style} }}")
    return rows + [f"  100% {{ {KEY_IDLE} }}"]


def build_html():
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    W, H = SIZE

    display = display_area(press(FRAME))
    rect = display.getbbox()
    notch = notch_area(display, rect)
    device = device_frame(press(FRAME), display)
    body = device.split()[3].getbbox()
    device = device.crop(body)

    scale = DEVICE_WIDTH / device.width
    dw, dh = DEVICE_WIDTH, device.height * scale
    dx = W - DEVICE_RIGHT_MARGIN - dw
    dy = H - dh
    screen_x, screen_y = dx + (rect[0] - body[0]) * scale, dy + (rect[1] - body[1]) * scale
    screen_w, screen_h = (rect[2] - rect[0]) * scale, (rect[3] - rect[1]) * scale
    gap = round(screen_w * 0.05)
    pitch = screen_w + gap
    content = (round(screen_w * ASSET_SCALE), round(screen_h * ASSET_SCALE))
    haze = (round(screen_w / GLOW_STEP), round(screen_h / GLOW_STEP))
    haze_mask = f"radial-gradient(closest-side, #000 {GLOW_FALLOFF}, transparent 100%)"

    device.resize((round(dw * ASSET_SCALE), round(dh * ASSET_SCALE)), Image.LANCZOS).save(
        WORK_DIR / "device.png"
    )
    # A CSS mask must be same-origin, and file:// pages have none, so it is
    # inlined rather than referenced. It carries the shape in its alpha, which
    # is the channel a mask image is read through.
    mask = display.crop(rect).resize(content, Image.BILINEAR)
    mask_buffer = io.BytesIO()
    Image.merge("LA", (mask, mask)).save(mask_buffer, "PNG")
    mask_uri = "data:image/png;base64," + base64.b64encode(mask_buffer.getvalue()).decode()
    shots = []
    for i, name in enumerate(DESKTOPS):
        shot = desktop(name, rect, notch)
        shot.resize(content, Image.LANCZOS).save(WORK_DIR / f"desktop-{i}.png")
        shots.append(shot.resize(haze, Image.LANCZOS))
    # The blur has to run across the whole filmstrip: blurring the desktops one
    # by one leaves the gaps between them hard, and a black band then sweeps
    # through the glow on every switch. The strip wraps around by one desktop
    # at each end so the blur never reaches the canvas either.
    order = [-1, *range(len(shots)), 0]
    step = haze[0] + round(gap / GLOW_STEP)
    wide = Image.new("RGB", (step * (len(order) - 1) + haze[0], haze[1]), BEZEL)
    for i, k in enumerate(order):
        wide.paste(shots[k], (i * step, 0))
    wide.filter(ImageFilter.GaussianBlur(GLOW_BLUR / GLOW_STEP)).save(WORK_DIR / "glow.png")
    haze_width = pitch * (len(order) - 1) + screen_w
    for name, _ in STATES:
        image = Image.open(SOURCE_DIR / f"{name}.png")
        if image.size != WINDOW_SIZE:
            raise SystemExit(f"{name}.png is {image.size}, expected {WINDOW_SIZE}")
        shutil.copy(SOURCE_DIR / f"{name}.png", WORK_DIR / f"{name}.png")

    ws = WINDOW_WIDTH / WINDOW_SIZE[0]
    knob = [(LEFT_MARGIN + x * ws, WINDOW_TOP + KNOB_Y * ws) for x in KNOB_X]

    def rest(i):
        return (knob[i][0] + CURSOR_REST[0], knob[i][1] + CURSOR_REST[1])

    tl = build_timeline(knob, rest)
    total = tl.t

    slide_rows = [
        f"  {pct(t, total)} {{ transform: translateX({-v * pitch:.2f}px); }}" for t, v in tl.strip_keyframes()
    ]
    cursor_rows = [
        f"  {pct(t, total)} {{ transform: translate({x:.2f}px, {y:.2f}px) scale({s}); animation-timing-function: {e}; }}"
        for t, x, y, s, e in tl.cursor
    ] + [f"  100% {{ transform: translate({tl.cursor[0][1]:.2f}px, {tl.cursor[0][2]:.2f}px) scale(1); }}"]

    hold_rows = lit_rows([(a - KEY_LEAD, b) for a, b in tl.holds], total)
    tap_rows = {
        step: lit_rows([(t - KEY_LEAD, t - KEY_LEAD + KEY_TAP) for t, s in tl.taps if s == step], total)
        for step in (-1, 1)
    }
    finger_rows = ["  0% { transform: translateX(0); animation-timing-function: ease-out; }"]
    for t, step in tl.taps:
        for offset, x, easing in (
            (0, 0, "ease-out"),
            (FLICK, -step * HAND_TRAVEL, "ease-in-out"),
            (FLICK + KEY_TAP, 0, "linear"),
        ):
            finger_rows.append(
                f"  {pct(t - KEY_LEAD + offset, total)} {{ transform: translateX({x}px);"
                f" animation-timing-function: {easing}; }}"
            )
    finger_rows.append("  100% { transform: translateX(0); }")

    state_rows = {name: [f"  0% {{ opacity: {int(i == 0)}; }}"] for i, (name, _) in enumerate(STATES)}
    for at, a, b in tl.switches:
        for index, value in ((a, 1), (b, 0)):
            rows = state_rows[STATES[index][0]]
            rows.append(f"  {pct(at - FADE, total)} {{ opacity: {value}; }}")
            rows.append(f"  {pct(at + FADE, total)} {{ opacity: {1 - value}; }}")
    for i, (name, _) in enumerate(STATES):
        state_rows[name].append(f"  100% {{ opacity: {int(i == 0)}; }}")

    css = [
        f"  .strip {{ animation: slide {total:.3f}s linear infinite; }}",
        f"  .cursor {{ animation: cursor {total:.3f}s linear infinite; }}",
        f"  .key.control {{ animation: hold {total:.3f}s linear infinite; }}",
        f"  .key.back {{ animation: tap-back {total:.3f}s linear infinite; }}",
        f"  .key.forward {{ animation: tap-forward {total:.3f}s linear infinite; }}",
        f"  .hand {{ animation: flick {total:.3f}s linear infinite; }}",
        keyframes("slide", slide_rows),
        keyframes("cursor", cursor_rows),
        keyframes("hold", hold_rows),
        keyframes("tap-back", tap_rows[-1]),
        keyframes("tap-forward", tap_rows[1]),
        keyframes("flick", finger_rows),
    ]
    for name, _ in STATES:
        css.append(f"  .state.{name} {{ animation: show-{name} {total:.3f}s linear infinite; }}")
        css.append(keyframes(f"show-{name}", state_rows[name]))

    strip_images = "".join(f'<img src="desktop-{i}.png">' for i in range(len(DESKTOPS)))

    state_images = "".join(f'<img class="state {name}" src="{name}.png">' for name, _ in STATES)

    html = f"""<!doctype html>
<meta charset="utf-8">
<title>Space Switch Speed banner</title>
<style>
  html, body {{ margin: 0; background: #0f1013; }}
  #stage {{
    position: relative; width: {W}px; height: {H}px; overflow: hidden;
    background: #0f1013;
    font-family: -apple-system, "SF Pro Display", "Helvetica Neue", sans-serif;
    -webkit-font-smoothing: antialiased;
  }}
  #stage > * {{ position: absolute; }}
  .vignette {{
    left: 0; top: 0; width: {W}px; height: {H}px;
    background: radial-gradient(620px 420px at {dx + dw / 2:.0f}px {H / 2:.0f}px, rgba(38, 73, 95, .5), rgba(38, 73, 95, 0) 70%);
  }}
  .glow {{
    left: {screen_x:.2f}px; top: {screen_y:.2f}px; width: {screen_w:.2f}px; height: {screen_h:.2f}px;
    overflow: hidden; transform: scale({GLOW_SPREAD}); opacity: {GLOW_OPACITY};
    /* The blur used to feather this layer's own edge as well as its contents;
       pre-blurred artwork leaves the clip hard, so the falloff is a mask. */
    -webkit-mask-image: {haze_mask}; mask-image: {haze_mask};
  }}
  h1 {{
    left: {LEFT_MARGIN}px; top: 126px; margin: 0;
    font-size: {TITLE_SIZE}px; font-weight: 700; letter-spacing: -0.5px; line-height: 1; color: #f5f5f7;
  }}
  .keys {{
    left: {LEFT_MARGIN}px; top: 248px; display: flex; align-items: center; gap: 10px;
  }}
  .key {{
    width: 48px; height: 48px; border-radius: 11px; border: 1.5px solid #2c303a;
    display: flex; align-items: center; justify-content: center;
    font-size: 24px; line-height: 1; {KEY_IDLE}
  }}
  .key.control {{ margin-right: 6px; }}
  .rule {{ width: 1px; height: 32px; background: #2c303a; margin: 0 18px; }}
  .hand {{
    width: 52px; height: 65px; fill: none; stroke: #8f96a3; stroke-width: 3.6;
    stroke-linecap: round; stroke-linejoin: round; will-change: transform;
  }}
  .device {{ left: {dx:.2f}px; top: {dy:.2f}px; width: {dw:.2f}px; height: {dh:.2f}px; }}
  .screen {{
    left: {screen_x:.2f}px; top: {screen_y:.2f}px; width: {screen_w:.2f}px; height: {screen_h:.2f}px;
    overflow: hidden; background: #000;
    -webkit-mask-image: url({mask_uri}); -webkit-mask-size: 100% 100%;
    mask-image: url({mask_uri}); mask-size: 100% 100%;
  }}
  .strip {{ position: absolute; left: 0; top: 0; display: flex; gap: {gap}px; will-change: transform; }}
  .strip img {{ display: block; width: {screen_w:.2f}px; height: {screen_h:.2f}px; }}
  .glow .strip img {{ width: {haze_width:.2f}px; margin-left: {-pitch:.2f}px; }}
  .window {{
    left: {LEFT_MARGIN}px; top: {WINDOW_TOP}px; width: {WINDOW_WIDTH}px; height: {WINDOW_SIZE[1] * ws:.2f}px;
    background: #fff; border-radius: {10 * ws * 2:.1f}px;
    box-shadow: 0 18px 44px rgba(0, 0, 0, .6), 0 2px 6px rgba(0, 0, 0, .35);
  }}
  .state {{ position: absolute; left: 0; top: 0; width: 100%; height: 100%; }}
  .cursor {{
    left: 0; top: 0; width: 26px; height: 32px; transform-origin: 3px 2px;
    filter: drop-shadow(0 1px 1.5px rgba(0, 0, 0, .35));
  }}
{chr(10).join(css)}
</style>
<div id="stage">
  <div class="vignette"></div>
  <div class="glow"><div class="strip"><img src="glow.png"></div></div>
  <h1>Space Switch Speed</h1>
  <div class="keys">
    <div class="key control">&#8963;</div>
    <div class="key back">&#8592;</div>
    <div class="key forward">&#8594;</div>
    <div class="rule"></div>
    <svg class="hand" viewBox="0 0 62 78">
      <path d="M17 46V22a5 5 0 0 1 10 0v24"/>
      <path d="M31 46V12a5 5 0 0 1 10 0v34"/>
      <path d="M45 46V20a5 5 0 0 1 10 0v36"/>
      <path d="M17 46V40a5 5 0 0 0-10 0v16c0 12 9 20 21 20h12c9 0 15-8 15-20"/>
    </svg>
  </div>
  <img class="device" src="device.png">
  <div class="screen"><div class="strip">{strip_images}</div></div>
  <div class="window">{state_images}</div>
  <svg class="cursor" viewBox="0 0 26 32">
    <path d="M3 2 L3 24.5 L8.6 19.3 L12.6 28.2 L16.4 26.5 L12.5 17.9 L19.8 17.9 Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/>
  </svg>
</div>
<script>
  function seek(t) {{
    for (const a of document.getAnimations()) {{ a.pause(); a.currentTime = t * 1000; }}
  }}
  const q = new URLSearchParams(location.search);
  if (q.has("t")) addEventListener("load", () => seek(+q.get("t")));
</script>
"""
    HTML.write_text(html)
    print(f"{HTML.relative_to(ROOT)}: {total:.2f} s loop")
    return total


# MARK: - Capture


class Chrome:
    def __init__(self, port=9333):
        self.profile = WORK_DIR / "chrome-profile"
        shutil.rmtree(self.profile, ignore_errors=True)
        self.process = subprocess.Popen(
            [
                CHROME,
                "--headless=new",
                "--disable-gpu",
                "--hide-scrollbars",
                "--no-first-run",
                f"--remote-debugging-port={port}",
                f"--user-data-dir={self.profile}",
                f"--window-size={SIZE[0] * CAPTURE_SCALE},{SIZE[1] * CAPTURE_SCALE}",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(50):
            time.sleep(0.2)
            try:
                targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list"))
            except OSError:
                continue
            pages = [t for t in targets if t["type"] == "page"]
            if pages:
                break
        else:
            raise SystemExit("headless Chrome did not start")
        self.sock = self.connect(pages[0]["webSocketDebuggerUrl"])
        self.id = 0

    def connect(self, url):
        host_port, _, path = url.removeprefix("ws://").partition("/")
        host, _, port = host_port.partition(":")
        sock = socket.create_connection((host, int(port)))
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall(
            f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        response = b""
        while b"\r\n\r\n" not in response:
            response += sock.recv(4096)
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise SystemExit("websocket handshake with Chrome failed")
        return sock

    def read(self, n):
        data = bytearray()
        while len(data) < n:
            chunk = self.sock.recv(min(1 << 20, n - len(data)))
            if not chunk:
                raise ConnectionError("Chrome closed the connection")
            data += chunk
        return bytes(data)

    def receive(self):
        message = bytearray()
        while True:
            b0, b1 = self.read(2)
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self.read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self.read(8))[0]
            if b1 & 0x80:
                self.read(4)
            payload = self.read(length)
            if b0 & 0x0F == 0x8:
                raise ConnectionError("Chrome closed the connection")
            if b0 & 0x0F != 0x9:
                message += payload
                if b0 & 0x80:
                    return json.loads(message.decode())

    def call(self, method, **params):
        self.id += 1
        payload = json.dumps({"id": self.id, "method": method, "params": params}).encode()
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
        mask = os.urandom(4)
        self.sock.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        while True:
            message = self.receive()
            if message.get("id") == self.id:
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message.get("result", {})

    def evaluate(self, expression):
        return self.call("Runtime.evaluate", expression=expression, returnByValue=True)["result"].get("value")

    def open(self, url):
        self.call(
            "Emulation.setDeviceMetricsOverride",
            width=SIZE[0],
            height=SIZE[1],
            deviceScaleFactor=CAPTURE_SCALE,
            mobile=False,
        )
        self.call("Page.navigate", url=url)
        for _ in range(100):
            if self.evaluate("document.readyState === 'complete' && [...document.images].every(i => i.complete)"):
                return
            time.sleep(0.1)
        raise SystemExit("the banner page did not finish loading")

    def frame(self, t):
        # Encoding the frame as PNG costs Chrome more than drawing it does, and
        # the frames are headed for a lossy codec anyway: JPEG at full quality
        # halves the render and stays within a couple of levels of the pixels.
        self.evaluate(f"seek({t})")
        data = self.call("Page.captureScreenshot", format="jpeg", quality=100)["data"]
        return Image.open(io.BytesIO(base64.b64decode(data))).convert("RGB")

    def close(self):
        self.sock.close()
        self.process.terminate()
        self.process.wait()
        shutil.rmtree(self.profile, ignore_errors=True)


def capture(total):
    chrome = Chrome()
    try:
        chrome.open(HTML.resolve().as_uri())
        count = round(total * FPS)
        frames = []
        for i in range(count):
            frames.append(chrome.frame(i / FPS))
            if i % 50 == 0:
                print(f"  frame {i}/{count}")
    finally:
        chrome.close()
    return frames


def encode(frames):
    size = (OUTPUT_WIDTH, round(SIZE[1] * OUTPUT_WIDTH / SIZE[0]))
    # The banner is opaque throughout, so RGB drops an alpha channel that would
    # otherwise cost a chunk in every frame. minimize_size lets the encoder spend
    # time finding the frame differences worth storing.
    if frames[0].size != size:
        frames = [f.resize(size, Image.LANCZOS) for f in frames]
    frames[0].save(
        OUT,
        save_all=True,
        append_images=frames[1:],
        duration=round(1000 / FPS),
        loop=0,
        quality=78,
        method=4,
        minimize_size=True,
    )
    print(f"{OUT.name}: {OUT.stat().st_size // 1024} KB, {len(frames)} frames at {FPS} fps")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--states"]:
        prepare_states(args[1:])
        args = []
    if args == ["--html"]:
        build_html()
    elif args:
        shots = " ".join(f"{name}.png" for name, _ in STATES)
        raise SystemExit(f"usage: make-banner.py [--html | --states {shots}]")
    else:
        encode(capture(build_html()))
