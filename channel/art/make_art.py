#!/usr/bin/env python3
"""Draws the channel's images and subsets its fonts. Needs pillow and fonttools.

Run from anywhere: python make_art.py  (writes into ../images and ../fonts)
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
IMAGES = HERE.parent / "images"
FONTS = HERE.parent / "fonts"
INTER = "/usr/share/fonts/inter/Inter.ttc"
INTER_MEDIUM, INTER_SEMIBOLD = 10, 12            # face indexes in Inter.ttc
SYMBOLS = "/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf"

# Ember palette (matches ~/.config/waybar/style.css)
BASE = (0x1A, 0x14, 0x1B)
TEXT = (0xF0, 0xE4, 0xD4)
AMBER = (0xE8, 0x9B, 0x5E)
MUTED = (0xB5, 0xA6, 0x98)
KEYCAP = (0x33, 0x29, 0x31)

GLYPH = {"web": "\U000F059F", "play_pause": "\U000F040E", "asterisk": "\U000F06C4",
         "rewind": "\U000F045F", "ff": "\U000F0211", "replay": "\U000F0459",
         "back": "\U000F004D", "arrows": "\U000F0041"}


def inter(size, face=INTER_MEDIUM):
    return ImageFont.truetype(INTER, size, index=face)


def symbols(size):
    return ImageFont.truetype(SYMBOLS, size)


def glow_background(w, h):
    """Ember base with a soft warm glow behind the centre."""
    im = Image.new("RGB", (w, h), BASE)
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse((w * 0.2, h * 0.05, w * 0.8, h * 0.95), fill=60)
    glow = glow.filter(ImageFilter.GaussianBlur(min(w, h) / 5))
    return Image.composite(Image.new("RGB", (w, h), AMBER), im, glow)


def brand(w, h, icon_px, label_px, gap):
    im = glow_background(w, h)
    d = ImageDraw.Draw(im)
    icon, label = symbols(icon_px), inter(label_px, INTER_SEMIBOLD)
    ib = d.textbbox((0, 0), GLYPH["web"], font=icon)
    lb = d.textbbox((0, 0), "Browser", font=label)
    total = (ib[3] - ib[1]) + gap + (lb[3] - lb[1])
    y = (h - total) / 2
    d.text(((w - (ib[2] - ib[0])) / 2 - ib[0], y - ib[1]), GLYPH["web"], font=icon, fill=AMBER)
    y += (ib[3] - ib[1]) + gap
    d.text(((w - (lb[2] - lb[0])) / 2 - lb[0], y - lb[1]), "Browser", font=label, fill=TEXT)
    return im


def nine_patch(radius, name):
    """White rounded rect as a Roku 9-patch; tint it with a Poster's blendColor."""
    s = 8
    inner = radius * 2 + 2
    big = Image.new("L", (inner * s, inner * s), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, inner * s - 1, inner * s - 1), radius * s, fill=255)
    mask = big.resize((inner, inner), Image.LANCZOS)
    im = Image.new("RGBA", (inner + 2, inner + 2), (0, 0, 0, 0))
    im.paste(Image.new("RGBA", (inner, inner), (255, 255, 255, 255)), (1, 1), mask)
    for i in (radius + 1, radius + 2):                # stretchable middle, marked on top and left
        im.putpixel((i, 0), (0, 0, 0, 255))
        im.putpixel((0, i), (0, 0, 0, 255))
    im.save(IMAGES / f"{name}.9.png")


def nine_patch_ring(radius, stroke, name):
    """White rounded outline as a 9-patch, for highlighting what's under the cursor."""
    s = 8
    inner = radius * 2 + 2
    big = Image.new("L", (inner * s, inner * s), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, inner * s - 1, inner * s - 1), radius * s, outline=255,
                                          width=stroke * s)
    mask = big.resize((inner, inner), Image.LANCZOS)
    im = Image.new("RGBA", (inner + 2, inner + 2), (0, 0, 0, 0))
    im.paste(Image.new("RGBA", (inner, inner), (255, 255, 255, 255)), (1, 1), mask)
    for i in (radius + 1, radius + 2):
        im.putpixel((i, 0), (0, 0, 0, 255))
        im.putpixel((0, i), (0, 0, 0, 255))
    im.save(IMAGES / f"{name}.9.png")


def cursor():
    s = 8
    pts = [(0, 0), (0, 25), (6.5, 19.5), (10.5, 28.5), (14.5, 26.8), (10.6, 18), (19, 18)]
    size = 40
    shadow = Image.new("L", (size * s, size * s), 0)
    ImageDraw.Draw(shadow).polygon([((x + 4) * s, (y + 5) * s) for x, y in pts], fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(2.2 * s))
    im = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    im.putalpha(shadow)
    d = ImageDraw.Draw(im)
    poly = [((x + 3) * s, (y + 3) * s) for x, y in pts]
    d.polygon(poly, fill=BASE + (255,))
    # Inset the white body so the dark edge reads as an outline.
    cx, cy = 3 + 6, 3 + 14
    inset = [(cx + (x - cx) * 0.86, cy + (y - cy) * 0.86) for x, y in [(px / s, py / s) for px, py in poly]]
    d.polygon([(x * s, y * s) for x, y in inset], fill=(255, 255, 255, 255))
    im.resize((size, size), Image.LANCZOS).save(IMAGES / "cursor.png")


def ring():
    s, size = 8, 96
    im = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    ImageDraw.Draw(im).ellipse((6 * s, 6 * s, (size - 6) * s, (size - 6) * s), outline=(255, 255, 255, 255),
                               width=5 * s)
    im.resize((size, size), Image.LANCZOS).save(IMAGES / "ring.png")


def spinner():
    s, size = 8, 64
    im = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    box = (5 * s, 5 * s, (size - 5) * s, (size - 5) * s)
    for i in range(36):                               # arc that fades towards its tail
        a = 255 * (i + 1) // 36
        d.arc(box, -90 + i * 8, -90 + i * 8 + 9, fill=AMBER + (a,), width=6 * s)
    im.resize((size, size), Image.LANCZOS).save(IMAGES / "spinner.png")


def hints():
    """Bottom hint bar explaining the remote."""
    items = [("arrows", "Move"), ("OK", "Click"), ("play_pause", "Search / address"),
             ("asterisk", "Menu"), ("rewind+ff", "Page up / down"), ("replay", "Reload"),
             ("back", "Back")]
    s = 2
    label, okf, icon = inter(19 * s), inter(15 * s, INTER_SEMIBOLD), symbols(22 * s)
    tmp = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    cap_h, pad, gap_item, gap_in = 34 * s, 22 * s, 26 * s, 10 * s

    def cap_width(key):
        if key == "OK":
            return 46 * s
        return (34 if "+" not in key else 60) * s

    width = pad * 2 + sum(cap_width(k) + gap_in + tmp.textbbox((0, 0), t, font=label)[2] for k, t in items) \
        + gap_item * (len(items) - 1)
    height = 56 * s
    im = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, width - 1, height - 1), height // 2, fill=BASE + (255,))
    x = pad
    for key, text in items:
        cw = cap_width(key)
        top = (height - cap_h) // 2
        d.rounded_rectangle((x, top, x + cw, top + cap_h), 9 * s, fill=KEYCAP + (255,))
        if key == "OK":
            b = d.textbbox((0, 0), "OK", font=okf)
            d.text((x + (cw - b[2]) / 2 - b[0] / 2, top + (cap_h - (b[3] - b[1])) / 2 - b[1]), "OK", font=okf,
                   fill=TEXT)
        else:
            glyphs = [GLYPH[k] for k in key.split("+")]
            gw = [d.textbbox((0, 0), g, font=icon) for g in glyphs]
            total = sum(b[2] - b[0] for b in gw) + 4 * s * (len(glyphs) - 1)
            gx = x + (cw - total) / 2
            for g, b in zip(glyphs, gw):
                d.text((gx - b[0], top + (cap_h - (b[3] - b[1])) / 2 - b[1]), g, font=icon, fill=AMBER)
                gx += b[2] - b[0] + 4 * s
        x += cw + gap_in
        b = d.textbbox((0, 0), text, font=label)
        d.text((x, (height - (b[3] - b[1])) / 2 - b[1]), text, font=label, fill=TEXT)
        x += b[2] + gap_item
    im.resize((width // s, height // s), Image.LANCZOS).save(IMAGES / "hints.png")


def fonts():
    FONTS.mkdir(exist_ok=True)
    unicodes = "U+0020-007E,U+00A0-024F,U+2010-2044,U+20AC,U+2122,U+2190-21FF,U+2022,U+2026,U+25B6"
    for face, name in ((INTER_MEDIUM, "Inter-Medium"), (INTER_SEMIBOLD, "Inter-SemiBold")):
        subprocess.run([sys.executable, "-m", "fontTools.subset", INTER, f"--font-number={face}",
                        f"--unicodes={unicodes}", "--layout-features=kern,liga,calt",
                        f"--output-file={FONTS / (name + '.ttf')}"], check=True)


if __name__ == "__main__":
    IMAGES.mkdir(exist_ok=True)
    brand(290, 218, 92, 30, 10).save(IMAGES / "icon_hd.png")
    brand(540, 405, 170, 54, 18).save(IMAGES / "icon_fhd.png")
    brand(1280, 720, 170, 52, 22).save(IMAGES / "splash_hd.png")
    brand(1920, 1080, 255, 78, 33).save(IMAGES / "splash_fhd.png")
    nine_patch(22, "pill")
    nine_patch(28, "card")
    nine_patch(14, "focus")
    nine_patch_ring(10, 3, "ring")
    cursor()
    ring()
    spinner()
    hints()
    fonts()
    print("art written to", IMAGES, "and", FONTS)
