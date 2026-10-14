#!/usr/bin/env python3
"""Dusk App Store screenshot compositor.

Reads panels.json, builds one HTML page per panel (device frame + copy +
background, all CSS), renders it with headless Google Chrome at 2x
supersampling, then uses ImageMagick to downsample to the exact App Store
size, drop alpha and write opaque sRGB PNGs.

Dependencies: Google Chrome (or Chromium) and ImageMagick 7 (`magick`).
Python stdlib only.

Usage:
  compose.py [iphone|ipad|tv|all ...] [--only 01-home] [--config path]
             [--preview] [--preview-dir DIR] [--jobs N] [--strict]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import html
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_CONFIG = HERE / "panels.json"
STYLE_CSS = HERE / "style.css"
WORK = REPO / "build" / "screenshots" / "compose"

CHROME_CANDIDATES = [
    os.environ.get("CHROME", ""),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
]

# Supersampling factor: Chrome renders at SSx, ImageMagick downsamples.
SS = 2

# --------------------------------------------------------------------------
# Device geometry. All lengths are fractions of the screen's SHORT side, so a
# device can be drawn at any size. Values come from published dimensions of
# iPhone 17 Pro Max / iPad Pro 13" (M4/M5) at their native resolutions.
# --------------------------------------------------------------------------
DEVICES = {
    "iphone": {
        "frame": 0.0135,      # metal band visible from the front
        "bezel": 0.0170,      # black glass border around the active area
        "screen_radius": 0.140,
        "thickness": 0.105,   # body depth, for the extruded side when tilted
        "island": (0.282, 0.083, 0.026),  # w, h, top offset
        "camera": None,
        # side buttons: (side, start, length) along the long edge, as fractions
        # of the screen's long side, measured from the top.
        "buttons": [("left", 0.112, 0.040), ("left", 0.180, 0.065),
                    ("left", 0.262, 0.065), ("right", 0.200, 0.100),
                    ("right", 0.465, 0.070)],
    },
    "ipad": {
        "frame": 0.0040,
        "bezel": 0.0360,
        "screen_radius": 0.0190,
        "thickness": 0.026,
        "island": None,
        "camera": 0.0060,     # front camera dot diameter, centred in the top bezel
        "buttons": [("top", 0.80, 0.075), ("right", 0.075, 0.055), ("right", 0.140, 0.055)],
    },
    "tv": {
        # A frameless floating display: a hairline dark edge, nothing else.
        "frame": 0.0030,
        "bezel": 0.0028,
        "screen_radius": 0.0060,
        "thickness": 0.022,
        "island": None,
        "camera": None,
        "buttons": [],
    },
}

FINISHES = {
    # front band gradient, side (extrusion) colours, button colour
    "graphite": {
        "band": "linear-gradient(150deg, #8b8c91 0%, #4a4b50 7%, #2a2b2f 22%, #1b1c1f 50%, #26272b 74%, #505156 92%, #7b7c81 100%)",
        "side_light": "#3a3b40",
        "side_dark": "#141518",
        "button": "linear-gradient(90deg, #2a2b2f, #55565b 50%, #2a2b2f)",
    },
    "silver": {
        "band": "linear-gradient(150deg, #f1f1f3 0%, #bfc0c4 10%, #9a9ba0 30%, #8a8b90 55%, #a9aaae 80%, #e4e4e7 100%)",
        "side_light": "#c4c5c9",
        "side_dark": "#77787d",
        "button": "linear-gradient(90deg, #8a8b90, #d8d9dc 50%, #8a8b90)",
    },
    "display": {
        "band": "linear-gradient(172deg, #6a6b70 0%, #2c2d31 18%, #17181b 55%, #26272b 100%)",
        "side_light": "#26272b",
        "side_dark": "#0c0c0e",
        "button": "none",
    },
}


# --------------------------------------------------------------------------
# Config helpers
# --------------------------------------------------------------------------
def fail(msg: str) -> None:
    print(f"compose: error: {msg}", file=sys.stderr)
    sys.exit(1)


def find_chrome() -> str:
    for c in CHROME_CANDIDATES:
        if c and Path(c).exists():
            return c
    fail("Google Chrome / Chromium not found (set CHROME=/path/to/binary)")
    return ""


def find_magick() -> str:
    m = shutil.which("magick")
    if not m:
        fail("ImageMagick 7 (`magick`) not found; brew install imagemagick")
    return m


def deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def png_size(path: Path) -> tuple[int, int]:
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        fail(f"{path} is not a PNG")
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


class MissingInput(Exception):
    pass


def resolve_input(panel: dict, key: str = "input") -> tuple[Path, bool]:
    """Return (path, is_placeholder)."""
    raw = panel.get(key)
    if raw:
        p = (REPO / raw).resolve()
        if p.exists():
            return p, False
    ph = panel.get(key.replace("input", "placeholder"))
    if ph:
        p = (REPO / ph).resolve()
        if p.exists():
            return p, True
    raise MissingInput(f"panel {panel['id']}: neither {key} ({raw}) nor a placeholder exists")


# --------------------------------------------------------------------------
# HTML building
# --------------------------------------------------------------------------
@dataclass
class Box:
    """A device placed on the canvas: centre, screen size, transform."""
    cx: float
    cy: float
    sw: float  # screen width (css px)
    sh: float  # screen height
    rot: tuple[float, float, float] = (0.0, 0.0, 0.0)  # rotateX, rotateY, rotateZ (deg)
    z: float = 0.0
    dim: float = 0.0  # 0..1 darkening for a background device


def mix_hex(a: str, b: str, t: float) -> str:
    ca = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(ca, cb))


def device_outer(kind: str, sw: float, sh: float) -> tuple[float, float, float]:
    d = DEVICES[kind]
    s = min(sw, sh)
    border = (d["frame"] + d["bezel"]) * s
    return sw + 2 * border, sh + 2 * border, border


def shade_html(kind: str, box: Box) -> str:
    """Blurred shadow of a device, drawn between two overlapping devices (the
    stage-wide drop-shadow only darkens the background)."""
    ow, oh, _ = device_outer(kind, box.sw, box.sh)
    s = min(box.sw, box.sh)
    d = DEVICES[kind]
    r = (d["screen_radius"] + d["bezel"] + d["frame"]) * s
    rx, ry, rz = box.rot
    tf = (f"translate3d(-50%,-50%,{box.z - 2:.1f}px) translate({s * 0.012:.1f}px,{s * 0.03:.1f}px) "
          f"rotateZ({rz}deg) rotateX({rx}deg) rotateY({ry}deg)")
    return (f'<div style="position:absolute;left:{box.cx:.2f}px;top:{box.cy:.2f}px;width:{ow:.2f}px;'
            f'height:{oh:.2f}px;border-radius:{r:.2f}px;background:rgba(0,0,0,0.6);'
            f'filter:blur({s * 0.035:.1f}px);transform:{tf}"></div>')


def clean_capture(path: Path, pcfg: dict, plat: str) -> Path:
    """Remove iPadOS 26's window-resize grip (a grey arc in the bottom-right
    corner of every iPad capture): mask it and fill from the surrounding
    pixels (alpha-weighted blur). Cached in build/screenshots/compose/clean/."""
    mask = pcfg.get("grip_mask")
    if not mask:
        return path
    mask_p = (REPO / mask).resolve()
    out = WORK / "clean" / plat / path.name
    if out.exists() and out.stat().st_mtime >= max(path.stat().st_mtime, mask_p.stat().st_mtime):
        return out
    out.parent.mkdir(parents=True, exist_ok=True)
    w, h = png_size(path)
    subprocess.run([shutil.which("magick") or "magick", str(path), "-alpha", "off",
                    "(", str(mask_p), "-background", "black", "-gravity", "southeast",
                    "-extent", f"{w}x{h}", "-negate", ")", "+gravity",
                    "-compose", "CopyOpacity", "-composite",
                    "(", "+clone", "-blur", "0x5", "-channel", "A", "-level", "0,8%", "+channel", ")",
                    "-compose", "DstOver", "-composite", "-alpha", "off", str(out)], check=True)
    return out


def grip_html(img_uri: str, sw: float, sh: float, frac: float) -> str:
    """Clone-stamp over iPadOS 26's window-resize grip (bottom-right corner of
    every iPad capture): show the patch just left of it in its place."""
    p = frac * max(sw, sh)
    return (f'<div style="position:absolute;right:0;bottom:0;width:{p:.2f}px;height:{p:.2f}px;'
            f'background:url({img_uri}) no-repeat;background-size:{sw:.2f}px {sh:.2f}px;'
            f'background-position:{-(sw - 2 * p):.2f}px {-(sh - p):.2f}px"></div>')


def has_baked_island(path: Path, kind: str, iw: int, ih: int) -> bool:
    """True if the capture already shows a Dynamic Island (mock-ups, old
    exports). Simulator captures don't, so the frame draws one."""
    spec = DEVICES[kind].get("island")
    if not spec:
        return True  # nothing to draw
    s = min(iw, ih)
    w, h, top = spec[0] * s, spec[1] * s, spec[2] * s
    if iw > ih:  # landscape: island sits on the left edge
        crop = f"{int(h * 0.5)}x{int(w * 0.7)}+{int(top + h * 0.25)}+{int(ih / 2 - w * 0.35)}"
    else:
        crop = f"{int(w * 0.7)}x{int(h * 0.5)}+{int(iw / 2 - w * 0.35)}+{int(top + h * 0.25)}"
    out = subprocess.run([shutil.which("magick") or "magick", str(path), "-crop", crop, "+repage",
                          "-colorspace", "Gray", "-format", "%[fx:maxima]", "info:"],
                         capture_output=True, text=True)
    try:
        return float(out.stdout.strip()) < 0.04
    except ValueError:
        return False


def device_html(kind: str, finish: str, img_uri: str, box: Box, light_deg: float,
                draw_island: bool = True, grip_patch: float = 0.0) -> str:
    d = DEVICES[kind]
    f = FINISHES[finish]
    s = min(box.sw, box.sh)
    frame = d["frame"] * s
    bezel = d["bezel"] * s
    r_screen = d["screen_radius"] * s
    r_bezel = r_screen + bezel
    r_outer = r_bezel + frame
    ow, oh, border = device_outer(kind, box.sw, box.sh)
    tilted = any(abs(a) > 0.01 for a in box.rot)
    rx, ry, rz = box.rot

    parts: list[str] = []

    # Extruded body: a stack of rounded slabs behind the front face. Only
    # rendered when the device is rotated in 3D (invisible otherwise). The
    # side catches the light right behind the front edge and falls off.
    if tilted and (abs(rx) > 0.01 or abs(ry) > 0.01):
        depth = d["thickness"] * s
        n = max(8, min(26, int(depth / 2.4)))
        for i in range(1, n + 1):
            t = i / n
            col = mix_hex(f["side_light"], f["side_dark"], min(1.0, t * 1.6))
            parts.append(
                f'<div class="slab" style="border-radius:{r_outer:.2f}px;'
                f'transform:translateZ({-depth * t:.2f}px);background:{col}"></div>'
            )

    # Side buttons: thin slivers peeking past the band, at mid depth.
    # Defined for portrait; a landscape screen rotates the device 90deg CCW.
    landscape = box.sw > box.sh
    nub = max(1.2, 0.0042 * s)
    for side, start, length in d["buttons"]:
        if landscape:
            if side == "top":
                side, start = "left", 1 - start - length
            elif side == "right":
                side = "top"
            elif side == "left":
                side = "bottom"
        if side in ("left", "right"):
            top = border + start * box.sh
            h = length * box.sh
            x = -nub if side == "left" else ow - 1
            style = f"left:{x:.2f}px;top:{top:.2f}px;width:{nub + 1:.2f}px;height:{h:.2f}px"
        else:
            left = border + start * box.sw
            w = length * box.sw
            y = -nub if side == "top" else oh - 1
            style = f"left:{left:.2f}px;top:{y:.2f}px;width:{w:.2f}px;height:{nub + 1:.2f}px"
        zt = f"transform:translateZ({-d['thickness'] * s * 0.5:.2f}px);" if tilted else ""
        grad = f["button"] if side in ("left", "right") else f["button"].replace("90deg", "0deg")
        parts.append(f'<div class="button" style="{style};{zt}background:{grad};border-radius:{nub:.2f}px"></div>')

    # Front face: metal band -> black bezel -> screen.
    island = ""
    if d["island"] and draw_island:
        iw, ih, it = (v * s for v in d["island"])
        if box.sw > box.sh:  # landscape: island on the left edge, vertical
            island = (f'<div class="island" style="width:{ih:.2f}px;height:{iw:.2f}px;left:{bezel + it:.2f}px;'
                      f'top:{(box.sh + 2 * bezel) / 2 - iw / 2:.2f}px;border-radius:{ih / 2:.2f}px"></div>')
        else:
            island = (f'<div class="island" style="width:{iw:.2f}px;height:{ih:.2f}px;left:50%;'
                      f'top:{bezel + it:.2f}px;margin-left:{-iw / 2:.2f}px;border-radius:{ih / 2:.2f}px"></div>')
    camera = ""
    if d["camera"]:
        cd = d["camera"] * s
        if box.sw >= box.sh:  # landscape: camera on the long top edge
            cam_pos = f"left:{ow / 2 - cd / 2:.2f}px;top:{border / 2 - cd / 2:.2f}px"
        else:
            cam_pos = f"left:{border / 2 - cd / 2:.2f}px;top:{oh / 2 - cd / 2:.2f}px" \
                if False else f"left:{ow / 2 - cd / 2:.2f}px;top:{border / 2 - cd / 2:.2f}px"
        camera = f'<div class="camera" style="{cam_pos};width:{cd:.2f}px;height:{cd:.2f}px"></div>'

    hair = max(0.6, s * 0.0009)
    parts.append(
        f'<div class="band" style="border-radius:{r_outer:.2f}px;background:{f["band"]};'
        f'box-shadow: inset 0 0 0 {hair:.2f}px rgba(255,255,255,0.22), inset 0 0 0 {hair * 2.4:.2f}px rgba(0,0,0,0.35);">'
        f'<div class="bezel" style="inset:{frame:.2f}px;border-radius:{r_bezel:.2f}px">'
        f'<div class="screen" style="inset:{bezel:.2f}px;border-radius:{r_screen:.2f}px">'
        f'<img src="{img_uri}" alt="">'
        + (grip_html(img_uri, box.sw, box.sh, grip_patch) if grip_patch else "") +
        f'<div class="glass" style="border-radius:{r_screen:.2f}px"></div>'
        f'</div>{island}</div>{camera}</div>'
    )

    tf = (f"translate3d(-50%,-50%,{box.z:.1f}px) rotateZ({rz}deg) rotateX({rx}deg) rotateY({ry}deg)")
    dim = (f'<div class="dim" style="border-radius:{r_outer:.2f}px;background:rgba(6,7,9,{box.dim:.3f})"></div>'
           if box.dim > 0 else "")
    return (f'<div class="device {kind}" style="left:{box.cx:.2f}px;top:{box.cy:.2f}px;'
            f'width:{ow:.2f}px;height:{oh:.2f}px;transform:{tf};">'
            + "".join(parts) + dim + "</div>")


def build_html(platform: str, pcfg: dict, panel: dict, design: dict,
               index: int = 0) -> tuple[str, str, list[str]]:
    W, H = pcfg["canvas"]
    kind = pcfg["device"]
    finish = panel.get("finish", pcfg.get("finish", "graphite"))
    layouts = pcfg["layouts"]
    warnings: list[str] = []

    # `layout` is a name, or {"portrait": name, "landscape": name} picked by the
    # capture's orientation.
    layout_name = panel.get("layout", "straight")
    img_path, is_ph, iw, ih = Path(), False, 1, 1
    if not (isinstance(layout_name, str) and "icons" in layouts.get(layout_name, {})):
        img_path, is_ph = resolve_input(panel)
        img_path = clean_capture(img_path, pcfg, platform)
        iw, ih = png_size(img_path)
    if isinstance(layout_name, dict):
        layout_name = layout_name["landscape" if iw > ih else "portrait"]
    if layout_name not in layouts:
        fail(f"panel {panel['id']}: unknown layout '{layout_name}' (have: {', '.join(layouts)})")
    lay = deep_merge(layouts[layout_name], panel.get("tweak", {}))
    if is_ph:
        warnings.append("placeholder")
    def wants_island(path: Path, w: int, h: int) -> bool:
        mode = pcfg.get("island", "auto")
        return (not has_baked_island(path, kind, w, h)) if mode == "auto" else bool(mode)

    # ---- copy block --------------------------------------------------------
    copy = lay.get("copy", "top")
    t = {**design["type"][platform], **lay.get("type", {})}
    head = panel.get("headline", "")
    sub = panel.get("subline", "")

    def lines(s: str) -> str:
        return "<br>".join(html.escape(x) for x in s.split("\n"))

    brand = ""
    if panel.get("brand"):
        logo = (REPO / design["logo"]).resolve().as_uri()
        brand = (f'<div class="brand"><img src="{logo}" style="height:{t["brand"]}px">'
                 f'<span style="font-size:{t["brand"] * 0.78:.1f}px">Dusk</span></div>')

    copy_css = (f"--h:{t['headline']}px;--s:{t['subline']}px;--gap:{t['gap']}px;"
                f"--brandgap:{t['brand_gap']}px;")
    if copy == "top":
        # Headline top is fixed per platform so the set lines up as a strip;
        # the brand lockup (panel 1) sits in the margin above it.
        top = lay.get("copy_top", t["copy_top"])
        copy_style = (f"left:{t['margin_x']}px;right:{t['margin_x']}px;top:{top}px;"
                      f"text-align:center;align-items:center;")
    else:  # left / right column, vertically centred on the device
        cx0, cx1 = lay["copy_x"]
        copy_style = (f"left:{cx0}px;width:{cx1 - cx0}px;top:{lay.get('copy_cy', H / 2)}px;"
                      f"transform:translateY(-50%);text-align:left;align-items:flex-start;")
    copy_html = (f'<header class="copy{"" if copy == "top" else " side"}" style="{copy_style}{copy_css}">{brand}'
                 f'<h1>{lines(head)}</h1>' + (f'<p>{lines(sub)}</p>' if sub else "") + "</header>")

    # ---- devices -----------------------------------------------------------
    rot = tuple(lay.get("rotate", [0, 0, 0]))
    cx, cy = lay["center"] if "center" in lay else lay["icons"]["center"]
    if "icons" in lay:
        sw = sh = 1.0
    elif "fit" in lay:
        # Largest screen that fits the box, whatever the capture's orientation.
        fw, fh = lay["fit"]
        k = min(fw / iw, fh / ih)
        sw, sh = iw * k, ih * k
    elif "screen_w" in lay:
        sw = lay["screen_w"]
        sh = sw * ih / iw
    else:
        sh = lay["screen_h"]
        sw = sh * iw / ih
    boxes: list[tuple[Box, str, bool]] = []

    if "second" in lay:
        sec = lay["second"]
        img2, ph2 = resolve_input(panel, "input2")
        img2 = clean_capture(img2, pcfg, platform)
        if ph2:
            warnings.append("placeholder2")
        i2w, i2h = png_size(img2)
        if "fit" in sec:
            k2 = min(sec["fit"][0] / i2w, sec["fit"][1] / i2h)
            s2w, s2h = i2w * k2, i2h * k2
        elif "screen_w" in sec:
            s2w = sec["screen_w"]
            s2h = s2w * i2h / i2w
        else:
            s2w = sw * sec.get("scale", 0.9)
            s2h = s2w * i2h / i2w
        boxes.append((Box(sec["center"][0], sec["center"][1], s2w, s2h,
                          tuple(sec.get("rotate", rot)), sec.get("z", -200), sec.get("dim", 0.18)),
                      img2.as_uri(), wants_island(img2, i2w, i2h)))
    if "icons" not in lay:
        boxes.append((Box(cx, cy, sw, sh, rot, lay.get("z", 0)), img_path.as_uri(),
                      wants_island(img_path, iw, ih)))

    s = min(sw, sh)
    light_deg = 90 if rot[1] > 0 else 270
    if "icons" in lay:
        devices, s = icon_grid_html(lay["icons"], panel.get("icons", []))
    else:
        parts_ = []
        for i, (b, uri, isl) in enumerate(boxes):
            if i > 0:  # front device of a pair: cast a soft shade onto the one behind
                parts_.append(shade_html(kind, b))
            parts_.append(device_html(kind, finish, uri, b, light_deg, isl, pcfg.get("grip_patch", 0.0)))
        devices = "".join(parts_)
        if "floats" in lay:
            devices += floating_icons_html(lay["floats"], panel.get("icons", []))

    # Shadow scale follows the device's short side.
    sh_amb = design["shadow"]
    shadow = (f"drop-shadow(0 {s * sh_amb['ambient_y']:.1f}px {s * sh_amb['ambient_blur']:.1f}px rgba(0,0,0,{sh_amb['ambient_a']})) "
              f"drop-shadow(0 {s * sh_amb['contact_y']:.1f}px {s * sh_amb['contact_blur']:.1f}px rgba(0,0,0,{sh_amb['contact_a']}))")

    persp = lay.get("perspective", 6000)
    stage = (f'<div class="stage" style="perspective:{persp}px;perspective-origin:{cx}px {cy}px;'
             f'filter:{shadow}">{devices}</div>')

    # ---- background ---------------------------------------------------------
    # Graphite base; the top tone cycles per panel (all neutral graphite/slate)
    # so the strip has rhythm, and a soft cool light falls off behind the device.
    bg = design["background"]
    tones = bg.get("tones") or [bg["top"]]
    top = tones[panel.get("tone", index) % len(tones)]
    mid = mix_hex(top, bg["bottom"], 0.62)
    if "glow_at" in lay:
        gx, gy = lay["glow_at"]
    else:
        gx, gy = cx, cy - (sh if sh > 1 else 0) * 0.28
    glow_r = max(W, H) * bg["glow_size"]
    background = (
        f'<div class="bg" style="background:'
        f'radial-gradient({glow_r:.0f}px {glow_r * 0.8:.0f}px at {gx:.0f}px {gy:.0f}px, {bg["glow"]}, transparent 72%),'
        f'radial-gradient(150% 95% at 50% -12%, {top} 0%, {mid} 50%, {bg["bottom"]} 100%);"></div>'
        f'<div class="vignette" style="background:radial-gradient(120% 100% at 50% 45%, transparent 55%, rgba(0,0,0,{bg["vignette"]}) 100%)"></div>'
    )

    css = STYLE_CSS.read_text()

    def page(pass_cls: str) -> str:
        return f"""<!doctype html><html class="{pass_cls}"><head><meta charset="utf-8">
<style>{css}
#canvas {{ width:{W}px; height:{H}px; }}
</style></head><body><div id="canvas">{background}{stage}{copy_html}</div></body></html>"""

    return page("pass-bg"), page("pass-fg"), warnings


def floating_icons_html(spots: list[dict], icons: list[dict]) -> str:
    """Large app icon tiles floating over/beside a device (Supporter panel).
    spots: [{"x", "y" (centre), "size", "rot"}], filled with icons in order."""
    out = []
    for spot, ic in zip(spots, icons):
        size = spot["size"]
        clip = squircle_path(size)
        src = (REPO / ic["src"]).resolve().as_uri()
        out.append(f'<div class="icon float" style="left:{spot["x"] - size / 2:.1f}px;top:{spot["y"] - size / 2:.1f}px;'
                   f'width:{size}px;height:{size}px;transform:rotate({spot.get("rot", 0)}deg)">'
                   f'<div class="icon-art" style="clip-path:path(\'{clip}\')"><img src="{src}" alt="">'
                   f'<div class="icon-rim" style="clip-path:path(\'{clip}\')"></div></div></div>')
    return "".join(out)


def squircle_path(size: float, n: float = 5.0, steps: int = 180) -> str:
    """iOS-style continuous-corner icon outline (superellipse), as an SVG path."""
    r = size / 2
    pts = []
    for i in range(steps):
        a = 2 * math.pi * i / steps
        c, s_ = math.cos(a), math.sin(a)
        x = r + r * math.copysign(abs(c) ** (2 / n), c)
        y = r + r * math.copysign(abs(s_) ** (2 / n), s_)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M" + " L".join(pts) + " Z"


def icon_grid_html(spec: dict, icons: list[dict]) -> tuple[str, float]:
    """A home-screen-like grid of app icons with labels (Supporter icons)."""
    cols = spec["columns"]
    size = spec["size"]
    gx, gy = spec["gap"]
    label = spec.get("label", 0)
    rows = math.ceil(len(icons) / cols)
    cell_h = size + (label * 1.9 if label else 0)
    total_w = cols * size + (cols - 1) * gx
    total_h = rows * cell_h + (rows - 1) * gy
    cx, cy = spec["center"]
    x0, y0 = cx - total_w / 2, cy - total_h / 2
    clip = squircle_path(size)
    out = []
    for i, ic in enumerate(icons):
        r, c = divmod(i, cols)
        n_in_row = min(cols, len(icons) - r * cols)
        row_off = (cols - n_in_row) * (size + gx) / 2
        x = x0 + row_off + c * (size + gx)
        y = y0 + r * (cell_h + gy)
        src = (REPO / ic["src"]).resolve().as_uri()
        lab = (f'<div class="icon-label" style="font-size:{label}px;top:{size + label * 0.55:.1f}px">'
               f'{html.escape(ic.get("label", ""))}</div>') if label else ""
        out.append(f'<div class="icon" style="left:{x:.1f}px;top:{y:.1f}px;width:{size}px;height:{size}px">'
                   f'<div class="icon-art" style="clip-path:path(\'{clip}\')"><img src="{src}" alt="">'
                   f'<div class="icon-rim" style="clip-path:path(\'{clip}\')"></div></div>{lab}</div>')
    return "".join(out), size * 1.6


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------
CHROME_FLAGS = [
    "--headless", "--hide-scrollbars", "--force-color-profile=srgb",
    "--disable-lcd-text", "--font-render-hinting=none",
    # 3D-stacked device layers at 2x blow the default tile budget
    # ("tile memory limits exceeded" -> layers silently missing).
    "--force-gpu-mem-available-mb=12288",
    "--default-background-color=00000000",
    "--virtual-time-budget=4000", "--run-all-compositor-stages-before-draw",
]


def chrome_shot(chrome: str, html_path: Path, raw: Path, W: int, H: int, ss: int) -> None:
    raw.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="dusk-compose-") as ud:
        cmd = [chrome, *CHROME_FLAGS, f"--force-device-scale-factor={ss}", f"--window-size={W},{H}",
               f"--user-data-dir={ud}", f"--screenshot={raw}", html_path.as_uri()]
        r = subprocess.run(cmd, capture_output=True, text=True)
    if not raw.exists():
        fail(f"chrome produced no screenshot for {html_path.name}:\n{r.stderr[-2000:]}")
    if png_size(raw) != (W * ss, H * ss):
        fail(f"{html_path.name}: chrome rendered {png_size(raw)}, expected {W * ss}x{H * ss}")
    if "tile memory limits exceeded" in r.stderr:
        fail(f"{html_path.name}: chrome dropped content (tile memory); raise --force-gpu-mem-available-mb")


def fit_args(W: int, H: int, ss: int, ow: int, oh: int) -> list[str]:
    # Fill to the target aspect first (centre crop of background margin), then
    # resample in linear light. Derived sizes (6.5") differ by <1% in aspect.
    scale = max(ow / W, oh / H)
    cw, ch = round(ow / scale * ss), round(oh / scale * ss)
    return ["-gravity", "center", "-crop", f"{cw}x{ch}+0+0", "+repage",
            "-colorspace", "RGB", "-filter", "Lanczos", "-resize", f"{ow}x{oh}!", "-colorspace", "sRGB"]


def render(chrome: str, magick: str, html_bg: Path, html_fg: Path, W: int, H: int,
           outputs: list[tuple[Path, int, int]], noise: float) -> None:
    """Two passes: the background alone at 1x, and devices + copy on
    transparent at SSx (supersampled). The background has nothing sharp in it,
    so it is blurred in 16-bit (turning Chrome's 8-bit gradient steps back into
    smooth ramps) and re-quantised with a fine ordered dither: no banding, and
    ~3x smaller than random noise because the pattern compresses."""
    raw_bg = html_bg.with_suffix(".raw.png")
    raw_fg = html_fg.with_suffix(".raw.png")
    chrome_shot(chrome, html_bg, raw_bg, W, H, 1)
    chrome_shot(chrome, html_fg, raw_fg, W, H, SS)
    for out, ow, oh in outputs:
        out.parent.mkdir(parents=True, exist_ok=True)
        cmd = [magick,
               "(", str(raw_bg), "-alpha", "off", "-depth", "16", *fit_args(W, H, 1, ow, oh),
               "-blur", f"0x{max(ow, oh) * noise:.1f}", "-ordered-dither", "o4x4,256", ")",
               "(", str(raw_fg), *fit_args(W, H, SS, ow, oh), ")",
               "-compose", "Over", "-composite",
               "-alpha", "off", "-depth", "8", "-strip", "-define", "png:color-type=2",
               "-define", "png:compression-level=9", f"PNG24:{out}"]
        subprocess.run(cmd, check=True)
        if png_size(out) != (ow, oh):
            fail(f"{out}: wrote {png_size(out)}, expected {ow}x{oh}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("platforms", nargs="*", default=["all"])
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    ap.add_argument("--only", action="append", default=[], help="panel id (repeatable)")
    ap.add_argument("--preview", action="store_true", help="also write a contact strip per platform")
    ap.add_argument("--preview-dir", default=str(WORK / "preview"))
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--strict", action="store_true",
                    help="final run: fail instead of falling back to placeholders or skipping")
    args = ap.parse_args()

    cfg = json.loads(Path(args.config).read_text())
    design = cfg["design"]
    plats = list(cfg["platforms"]) if "all" in args.platforms else args.platforms
    for p in plats:
        if p not in cfg["platforms"]:
            fail(f"unknown platform '{p}' (have: {', '.join(cfg['platforms'])})")

    chrome, magick = find_chrome(), find_magick()
    out_root = REPO / cfg["output"].format(version=cfg["version"])
    WORK.mkdir(parents=True, exist_ok=True)

    jobs = []
    written: dict[str, list[Path]] = {}
    for plat in plats:
        pcfg = cfg["platforms"][plat]
        W, H = pcfg["canvas"]
        for index, panel in enumerate(pcfg["panels"]):
            if args.only and panel["id"] not in args.only:
                continue
            if panel.get("enabled", True) is False:
                continue
            try:
                try:
                    doc_bg, doc_fg, warns = build_html(plat, pcfg, panel, design, index)
                except MissingInput:
                    # e.g. no icon-picker capture -> icon grid; no second
                    # capture -> single-device layout.
                    if "fallback_layout" not in panel:
                        raise
                    fb = {k: v for k, v in panel.items() if k != "fallback_layout"}
                    fb["layout"] = panel["fallback_layout"]
                    doc_bg, doc_fg, warns = build_html(plat, pcfg, fb, design, index)
                    warns.append("fallback layout")
            except MissingInput as e:
                if args.strict:
                    fail(str(e))
                print(f"  skipped {plat}/{panel['id']}: {e}")
                continue
            if args.strict and warns:
                fail(f"{plat}/{panel['id']}: raw capture missing, would use a placeholder")
            hp = WORK / plat / f"{panel['id']}.html"
            hp.parent.mkdir(parents=True, exist_ok=True)
            hp.write_text(doc_fg)
            hb = WORK / plat / f"{panel['id']}.bg.html"
            hb.write_text(doc_bg)
            outs = [(out_root / pcfg["folder"] / f"{panel['id']}.png", W, H)]
            for d in pcfg.get("derived", []):
                if d.get("enabled", True):
                    # Derived sizes default to a gitignored root (`derived_output`).
                    droot = REPO / d.get("output", cfg.get("derived_output", cfg["output"])).format(
                        version=cfg["version"])
                    outs.append((droot / d["folder"] / f"{panel['id']}.png", d["size"][0], d["size"][1]))
            written.setdefault(plat, []).append(outs[0][0])
            tag = f" [{', '.join(warns)}]" if warns else ""
            jobs.append((f"{plat}/{panel['id']}{tag}", hb, hp, W, H, outs))

    # Blur radius for the background dither, as a fraction of the long side.
    noise = design["background"].get("smooth", 0.0042)
    with futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        fs = {ex.submit(render, chrome, magick, hb, hp, W, H, outs, noise): name
              for name, hb, hp, W, H, outs in jobs}
        for f in futures.as_completed(fs):
            f.result()
            print(f"  rendered {fs[f]}")

    # A full run of a platform removes outputs whose panel left the config.
    if not args.only:
        for plat in plats:
            pcfg = cfg["platforms"][plat]
            keep = {f"{pn['id']}.png" for pn in pcfg["panels"] if pn.get("enabled", True) is not False}
            folders = [out_root / pcfg["folder"]]
            for d in pcfg.get("derived", []):
                folders.append(REPO / d.get("output", cfg.get("derived_output", cfg["output"])).format(
                    version=cfg["version"]) / d["folder"])
            for folder in folders:
                for f in sorted(folder.glob("*.png")) if folder.is_dir() else []:
                    if f.name not in keep:
                        f.unlink()
                        print(f"  removed stale {f.relative_to(REPO)}")

    if args.preview:
        pdir = Path(args.preview_dir)
        pdir.mkdir(parents=True, exist_ok=True)
        for plat, files in written.items():
            files = sorted(files)
            W, H = cfg["platforms"][plat]["canvas"]
            sheet = pdir / f"strip-{plat}.png"
            if H > W:  # portrait: one row, like the App Store strip
                cmd = [magick, *map(str, files), "-resize", "x900", "-bordercolor", "#2a2a2e",
                       "-border", "6", "+append", str(sheet)]
            else:      # landscape: a 3-column contact sheet
                rows = []
                for i in range(0, len(files), 3):
                    rows += ["(", *map(str, files[i:i + 3]), "-resize", "800x", "-bordercolor", "#2a2a2e",
                             "-border", "6", "+append", "-background", "#2a2a2e", "-gravity", "west",
                             "-extent", f"{3 * 812}x", ")"]
                cmd = [magick, *rows, "-append", str(sheet)]
            subprocess.run(cmd, check=True)
            print(f"  preview {sheet}")

    print(f"done -> {out_root.relative_to(REPO)}")


if __name__ == "__main__":
    main()
