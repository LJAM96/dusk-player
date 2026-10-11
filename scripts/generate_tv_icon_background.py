"""Generates the Back layer of the tvOS app icon (AppIconTV.brandassets): a
very dark charcoal field with a slight top-to-bottom gradient, like the iOS
icon's dark fill. The Front layer (the Dusk mark) is untouched.

Usage (needs Pillow + NumPy):
    python3 scripts/generate_tv_icon_background.py apply [variant]
        Writes the Back layer PNGs for both image stacks (default: charcoal).
    python3 scripts/generate_tv_icon_background.py preview <out-dir>
        Renders every variant as a flattened icon (Back + Front) for review.

Switching variants: `apply <name>`, then rebuild. Variants are
(top, bottom) hex colors; equal colors give a flat field."""
import os, sys
import numpy as np
from PIL import Image, ImageDraw

VARIANTS = {
    "original": ("#090A0F", "#090A0F"),  # the near-black it shipped with
    "flat": ("#1C1C1E", "#1C1C1E"),
    "charcoal": ("#26262A", "#1A1A1D"),  # recommended
    "graphite": ("#2C2C30", "#1E1E21"),
}
DEFAULT = "charcoal"

STACKS = "Dusk/Resources/Assets.xcassets/AppIconTV.brandassets"
BACKS = {
    f"{STACKS}/App Icon.imagestack/Back.imagestacklayer/Content.imageset/400x240-back.png": (400, 240),
    f"{STACKS}/App Icon.imagestack/Back.imagestacklayer/Content.imageset/800x480-back.png": (800, 480),
    f"{STACKS}/App Icon - App Store.imagestack/Back.imagestacklayer/Content.imageset/1280x768-back.png": (1280, 768),
}
FRONT = f"{STACKS}/App Icon.imagestack/Front.imagestacklayer/Content.imageset/432.png"


def hexc(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], dtype=np.float64)


def background(variant, size):
    top, bottom = (hexc(c) for c in VARIANTS[variant])
    w, h = size
    v = (np.arange(h, dtype=np.float64) / (h - 1))[:, None, None]
    field = top * (1 - v) + bottom * v
    field = np.broadcast_to(field, (h, w, 3)).copy()
    # A little noise keeps the 8-bit gradient from banding.
    field += np.random.default_rng(7).uniform(-0.5, 0.5, field.shape)
    return Image.fromarray(np.clip(field + 0.5, 0, 255).astype(np.uint8))


def apply(variant):
    for path, size in BACKS.items():
        background(variant, size).save(path, optimize=True)
    print(f"applied {variant}: {VARIANTS[variant]}")


def preview(out):
    # Flattened like the home screen at rest: the @2x Front layer centered on
    # the @2x Back layer, rounded corners.
    os.makedirs(out, exist_ok=True)
    w, h = 800, 480
    front = Image.open(FRONT).convert("RGBA")
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=24, fill=255)
    tiles = []
    for name in VARIANTS:
        icon = background(name, (w, h)).convert("RGBA")
        icon.alpha_composite(front, ((w - front.width) // 2, (h - front.height) // 2))
        icon.putalpha(mask)
        icon.save(f"{out}/tv-icon-{name}.png")
        tiles.append((name, icon))
    # Side-by-side sheet on a dark and a mid-grey backdrop.
    tw, th, pad = 480, 288, 40
    sheet = Image.new("RGB", (len(tiles) * (tw + pad) + pad, 2 * (th + pad) + pad))
    for row, backdrop in enumerate([(0, 0, 0), (58, 58, 62)]):
        ImageDraw.Draw(sheet).rectangle((0, row * (th + pad), sheet.width, (row + 1) * (th + pad) + pad), fill=backdrop)
        for i, (name, icon) in enumerate(tiles):
            sheet.paste(icon.resize((tw, th), Image.LANCZOS), (pad + i * (tw + pad), pad + row * (th + pad)), icon.resize((tw, th), Image.LANCZOS))
    sheet.save(f"{out}/tv-icon-variants.png")
    print(f"previews in {out}")


if __name__ == "__main__":
    if sys.argv[1] == "apply":
        apply(sys.argv[2] if len(sys.argv) > 2 else DEFAULT)
    elif sys.argv[1] == "preview":
        preview(sys.argv[2])
