#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError as exc:
    raise SystemExit("Pillow is required to regenerate the app icon: python3 -m pip install Pillow") from exc


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
ICONSET = ROOT / ".build" / "ZenithOSIcon.iconset"
ICNS = RESOURCES / "ZenithOSIcon.icns"

CANVAS = 1024
BRAND_TOP = (155, 251, 227)
BRAND_BOTTOM = (2, 178, 134)
BLACK = (5, 8, 7, 255)
BLACK_LIFTED = (8, 13, 11, 255)
STROKE = (25, 56, 48, 255)

ZENITH_POINTS = [
    (164.698, 0),
    (98.4224, 0),
    (0, 125.778),
    (0, 192.501),
    (98.4224, 192.501),
    (0, 318.283),
    (0, 385),
    (279, 385),
    (279, 335.363),
    (52.4707, 335.363),
    (164.698, 192.501),
    (279, 192.501),
    (279, 142.863),
    (52.4707, 142.863),
]

ICON_SIZES = [
    (16, 1),
    (16, 2),
    (32, 1),
    (32, 2),
    (128, 1),
    (128, 2),
    (256, 1),
    (256, 2),
    (512, 1),
    (512, 2),
]


def lerp(a: int, b: int, t: float) -> int:
    return round(a + (b - a) * t)


def rounded_backdrop() -> Image.Image:
    image = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, CANVAS, CANVAS), radius=224, fill=BLACK)
    draw.rounded_rectangle((56, 56, 968, 968), radius=196, fill=BLACK_LIFTED, outline=STROKE, width=2)
    return image


def mark_mask() -> Image.Image:
    mask = Image.new("L", (CANVAS, CANVAS), 0)
    draw = ImageDraw.Draw(mask)
    scale = 1.8
    offset_x = 260
    offset_y = 154
    points = [(offset_x + x * scale, offset_y + y * scale) for x, y in ZENITH_POINTS]
    draw.polygon(points, fill=255)
    return mask


def aqua_gradient(mask: Image.Image) -> Image.Image:
    gradient = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    pixels = gradient.load()
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        color = tuple(lerp(BRAND_TOP[i], BRAND_BOTTOM[i], t) for i in range(3)) + (255,)
        for x in range(CANVAS):
            pixels[x, y] = color
    gradient.putalpha(mask)
    return gradient


def render_master() -> Image.Image:
    image = rounded_backdrop()
    mask = mark_mask()
    glow = aqua_gradient(mask.filter(ImageFilter.GaussianBlur(24)))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(24)).point(lambda value: min(150, value)))
    image.alpha_composite(glow)
    image.alpha_composite(aqua_gradient(mask))
    return image


def write_iconset(master: Image.Image) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)

    for size, scale in ICON_SIZES:
        pixels = size * scale
        filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        output = master.resize((pixels, pixels), Image.Resampling.LANCZOS)
        output.save(ICONSET / filename)


def main() -> None:
    RESOURCES.mkdir(parents=True, exist_ok=True)
    write_iconset(render_master())
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(f"Generated {ICNS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
