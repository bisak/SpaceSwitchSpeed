#!/usr/bin/env python3
# Renders the README banner into docs/images/banner.webp.
#
#   make banner
#       build build/banner/banner.html, capture every frame of it with
#       headless Chrome, and encode the animation
#   python3 Scripts/make-banner.py --html
#       only build the HTML, for previewing in a browser (it loops there)
#   python3 Scripts/make-banner.py --states default.png gentle.png balanced.png quick.png
#       prepare docs/images/banner-source from window screenshots (Shift-Cmd-4,
#       Space, click the window) taken at each preset, then render
#
# Everything else in it is Apple's: the MacBook Pro is the device icon from
# CoreTypes, the type is SF Pro, and the desktops on its screen are cut from
# the macOS Tahoe press images on Apple Newsroom, fetched at render time into
# build/banner. None of it is committed.
#
# The piece is one loop. At Default the desktops swipe right, right, left,
# left with Dock's own integrator and Apple's constants, the cursor drags the
# slider to Quick with the window snapping between the real screenshots as
# the knob passes each tick, the same four swipes play with the coefficients
# SpaceSwitchSpeed writes for 0.35, and the cursor drags back.

import base64
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

from PIL import Image, ImageChops, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "images" / "banner.webp"
SOURCE_DIR = ROOT / "docs" / "images" / "banner-source"
WORK_DIR = ROOT / "build" / "banner"
HTML = WORK_DIR / "banner.html"

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DEVICE_ICON = Path(
    "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
    "com.apple.macbookpro-16-2021-space-gray.icns"
)
# Apple's macOS Tahoe press images: full desktops, shown on a MacBook Pro.
# The screen is cut out from inside the bezel.
NEWSROOM = (
    "https://www.apple.com/newsroom/images/2025/06/"
    "macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/article/"
    "Apple-WWDC25-macOS-Tahoe-26-{}-250609_big.jpg.slideshow-xlarge_2x.jpg"
)
DESKTOPS = ["Messages", "Apple-Intelligence-Shortcuts-Notes", "Apple-Music"]

# The slider's presets up to Quick, as Speed.presets orders them, and where
# each knob sits in the 2x window screenshots. Only the ones in SHOWN get
# their own swipes; the rest appear as the knob snaps past them during a drag.
STATES = [("default", 1.0), ("gentle", 0.75), ("balanced", 0.5), ("quick", 0.35)]
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
CAPTURE_SCALE = 2
OUTPUT_WIDTH = 1792

DEVICE_SCALE = 0.78
DEVICE_RIGHT_MARGIN = 56
LEFT_MARGIN = 96
WINDOW_TOP = 348
WINDOW_WIDTH = 560

CURSOR_REST = (30, 36)
FADE = 0.06


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
    # the "Switching speed" label and left of the hare; the blue fill has a
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


def device_artwork():
    iconset = WORK_DIR / "device.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    subprocess.run(["iconutil", "-c", "iconset", "-o", iconset, DEVICE_ICON], check=True)
    return Image.open(iconset / "icon_512x512@2x.png").convert("RGBA")


def desktop(name):
    jpg = WORK_DIR / f"newsroom-{name}.jpg"
    if not jpg.exists():
        print(f"fetching {name} from Apple Newsroom")
        urllib.request.urlretrieve(NEWSROOM.format(name), jpg)
    image = Image.open(jpg).convert("RGB")
    return image.crop(screen_inside_bezel(image))


def screen_inside_bezel(image):
    # The press shot is a straight-on MacBook Pro on a light background. Walk
    # inward from the black bezel's bounding box until the black ends; the
    # top edge is probed a quarter of the way across, clear of the notch.
    px = image.load()
    black = lambda p: max(p[:3]) < 40
    x0, y0, x1, y1 = Image.eval(image.convert("L"), lambda v: 255 if v < 40 else 0).getbbox()
    cy, cx = (y0 + y1) // 2, x0 + (x1 - x0) // 4
    left, right, top, bottom = x0, x1 - 1, y0, y1 - 1
    while black(px[left, cy]):
        left += 1
    while black(px[right, cy]):
        right -= 1
    while black(px[cx, top]):
        top += 1
    while black(px[cx, bottom]):
        bottom -= 1
    return (left, top, right + 1, bottom + 1)


def screen_mask(device):
    # The icon's screen is a flat blue; the bezel, notch and body are not.
    # Anti-aliased body edges read as blue too, so keep only the one big blob,
    # grown by a pixel so the wallpaper also covers the screen's own edge blend.
    r, g, b, _ = device.split()
    blue = ImageChops.subtract(b, r).point(lambda x: 255 if x > 60 else 0)
    blob = blue.filter(ImageFilter.MinFilter(15)).filter(ImageFilter.MaxFilter(19))
    return ImageChops.multiply(blue, blob).filter(ImageFilter.MaxFilter(3))


def fit(image, size):
    w, h = size
    scale = max(w / image.width, h / image.height)
    resized = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
    left = (resized.width - w) // 2
    top = (resized.height - h) // 2
    return resized.crop((left, top, left + w, top + h))


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

    def step(self):
        self.v = self.gain * (self.target - self.pos) + self.retention * self.v
        self.pos += DT * self.v
        self.t += DT
        self.positions.append(self.pos)

    def wait(self, seconds):
        until = self.t + seconds
        while self.t < until:
            self.step()

    def swipe(self, target):
        # Dock stops stepping once |velocity| drops under its epsilon and the
        # remaining fraction of a pixel is never drawn, so snap the same way.
        self.target = target
        self.step()
        while abs(self.v) >= SETTLE_EPSILON:
            self.step()
        self.pos, self.v = self.target, 0.0
        self.positions[-1] = self.pos

    def set_speed(self, speed):
        self.gain, self.retention = coefficients(speed)

    def cursor_at(self, x, y, scale=1.0, easing="linear"):
        self.cursor.append((self.t, x, y, scale, easing))

    def switch(self, at, a, b):
        self.switches.append((at, a, b))

    def strip_keyframes(self):
        step = round(1 / DT / FPS)
        return [(i * DT, p) for i, p in enumerate(self.positions) if i % step == 0] + [(self.t, self.pos)]


SWIPES = [1, 2, 1, 0]
SWIPE_PAUSE = 0.2


def build_timeline(knob, rest):
    tl = Timeline()
    pitch = knob[1][0] - knob[0][0]

    tl.cursor_at(*rest(SHOWN[0]))
    for n, i in enumerate(SHOWN):
        tl.set_speed(STATES[i][1])
        for target in SWIPES:
            tl.swipe(target)
            tl.wait(SWIPE_PAUSE)
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


def build_html():
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    W, H = SIZE

    device = device_artwork()
    mask = screen_mask(device)
    sx0, sy0, sx1, sy1 = mask.getbbox()
    body = device.split()[3].point(lambda a: 255 if a > 10 else 0).getbbox()
    dx = W - DEVICE_RIGHT_MARGIN - body[2] * DEVICE_SCALE
    dy = H / 2 - (body[1] + body[3]) / 2 * DEVICE_SCALE
    dw, dh = device.width * DEVICE_SCALE, device.height * DEVICE_SCALE
    screen_x, screen_y = dx + sx0 * DEVICE_SCALE, dy + sy0 * DEVICE_SCALE
    screen_w, screen_h = (sx1 - sx0) * DEVICE_SCALE, (sy1 - sy0) * DEVICE_SCALE
    gap = round(screen_w * 0.05)
    pitch = screen_w + gap

    device.save(WORK_DIR / "device.png")
    # A CSS mask must be same-origin, and file:// pages have none, so it is
    # inlined rather than referenced.
    mask_buffer = io.BytesIO()
    mask.crop((sx0, sy0, sx1, sy1)).save(mask_buffer, "PNG")
    mask_uri = "data:image/png;base64," + base64.b64encode(mask_buffer.getvalue()).decode()
    for i, name in enumerate(DESKTOPS):
        fit(desktop(name), (round(screen_w * 2), round(screen_h * 2))).save(
            WORK_DIR / f"desktop-{i}.jpg", quality=90
        )
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
        keyframes("slide", slide_rows),
        keyframes("cursor", cursor_rows),
    ]
    for name, _ in STATES:
        css.append(f"  .state.{name} {{ animation: show-{name} {total:.3f}s linear infinite; }}")
        css.append(keyframes(f"show-{name}", state_rows[name]))

    strip_images = "".join(f'<img src="desktop-{i}.jpg">' for i in range(len(DESKTOPS)))
    state_images = "".join(f'<img class="state {name}" src="{name}.png">' for name, _ in STATES)

    html = f"""<!doctype html>
<meta charset="utf-8">
<title>SpaceSwitchSpeed banner</title>
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
    overflow: hidden; transform: scale(2.1); opacity: .38; filter: blur(60px);
  }}
  h1 {{
    left: {LEFT_MARGIN}px; top: 120px; margin: 0;
    font-size: 96px; font-weight: 700; letter-spacing: -0.5px; line-height: 1; color: #f5f5f7;
  }}
  p {{
    left: {LEFT_MARGIN + 3}px; top: 258px; margin: 0;
    font-size: 34px; font-weight: 400; letter-spacing: -0.2px; line-height: 1; color: #989ca6;
  }}
  .device {{ left: {dx:.2f}px; top: {dy:.2f}px; width: {dw:.2f}px; height: {dh:.2f}px; }}
  .screen {{
    left: {screen_x:.2f}px; top: {screen_y:.2f}px; width: {screen_w:.2f}px; height: {screen_h:.2f}px;
    overflow: hidden; background: #0a0c0f;
    -webkit-mask-image: url({mask_uri}); -webkit-mask-size: 100% 100%;
    mask-image: url({mask_uri}); mask-size: 100% 100%;
  }}
  .strip {{ position: absolute; left: 0; top: 0; display: flex; gap: {gap}px; will-change: transform; }}
  .strip img {{ display: block; width: {screen_w:.2f}px; height: {screen_h:.2f}px; }}
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
  <div class="glow"><div class="strip">{strip_images}</div></div>
  <h1>SpaceSwitchSpeed</h1>
  <p>Make the macOS Space switch as fast as you want.</p>
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
        self.evaluate(f"seek({t})")
        data = self.call("Page.captureScreenshot", format="png")["data"]
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
    frames = [f.resize(size, Image.LANCZOS) for f in frames]
    frames[0].save(
        OUT,
        save_all=True,
        append_images=frames[1:],
        duration=round(1000 / FPS),
        loop=0,
        quality=86,
        method=6,
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
        raise SystemExit("usage: make-banner.py [--html | --states default.png gentle.png balanced.png quick.png]")
    else:
        encode(capture(build_html()))
