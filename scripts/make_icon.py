#!/usr/bin/env python3
"""
Generate the OpenClaw Monitor app icon.

Design: Three tapering claw-mark slashes on a dark navy background,
        with a subtle blue glow and a green status dot.

Usage:
    python3 scripts/make_icon.py          # from project root
    pip3 install Pillow                    # if not already installed
"""

import math
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("Pillow not found.  Run:  pip3 install Pillow")

# ── Design tokens (all coordinates are for SIZE=1024; scaled automatically) ──

SIZE = 1024

BG_COLOR   = (14, 20, 40)          # deep navy
CLAW_MID   = (218, 235, 255)       # bright icy blue-white (center slash)
CLAW_SIDE  = (148, 178, 235)       # slightly dimmer (outer slashes)
GLOW_COLOR = (70, 115, 255, 65)    # blue-purple glow
DOT_GREEN  = (60, 195, 105)        # macOS-style green
DOT_HL     = (215, 255, 225, 180)  # dot highlight


# ── Bezier helpers ────────────────────────────────────────────────────────────

def bezier_points(p0, ctrl, p2, steps=120):
    """Quadratic bezier from p0 → ctrl → p2."""
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt * mt * p0[0] + 2 * mt * t * ctrl[0] + t * t * p2[0]
        y = mt * mt * p0[1] + 2 * mt * t * ctrl[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def draw_tapered_slash(draw, p0, ctrl, p2, peak_width, color, steps=120):
    """
    Draw a claw-mark slash: thick in the middle, tapering to sharp tips.
    Uses a sin envelope so the width is 0 at both endpoints and
    peak_width at the midpoint.
    """
    pts = bezier_points(p0, ctrl, p2, steps)
    n = len(pts) - 1
    for i in range(n):
        t = i / n
        # sin taper: 0 → peak → 0; keep at least 15% width to avoid gaps
        width = max(1, int(peak_width * max(0.15, math.sin(math.pi * t))))
        draw.line([pts[i], pts[i + 1]], fill=color, width=width)


# ── Rendering ─────────────────────────────────────────────────────────────────

def make_icon(size: int) -> "Image.Image":
    s = size / SIZE   # uniform scale factor

    img  = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # ── Background: dark navy rounded rectangle ───────────────────────────────
    draw.rounded_rectangle(
        [0, 0, size - 1, size - 1],
        radius=int(218 * s),
        fill=BG_COLOR + (255,),
    )

    # ── Three claw-mark slashes ───────────────────────────────────────────────
    # All coordinates are for a 1024-px canvas; scaled by s.
    # Control point is shifted ~40 px right of the straight-line midpoint
    # so each slash curves very slightly rightward — like a natural talon.
    #
    #    LEFT        CENTER       RIGHT
    #   (200,190)  (385,162)   (565,190)
    #       ↘          ↘           ↘
    #   (460,770)  (640,758)   (815,770)

    slashes = [
        # (start,        control,      end)
        ((200, 190),  (360, 480),  (460, 770)),   # left
        ((385, 162),  (558, 462),  (640, 758)),   # center — brightest
        ((565, 190),  (730, 480),  (815, 770)),   # right
    ]
    peak_widths = [int(54 * s), int(62 * s), int(54 * s)]
    colors      = [CLAW_SIDE + (215,), CLAW_MID + (255,), CLAW_SIDE + (215,)]

    def scale_pt(pt):
        return (int(pt[0] * s), int(pt[1] * s))

    # Pass 1: glow (wide, blurred, drawn on separate layer)
    glow_img  = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow_img)
    for (p0, ctrl, p2), pw in zip(slashes, peak_widths):
        draw_tapered_slash(
            glow_draw,
            scale_pt(p0), scale_pt(ctrl), scale_pt(p2),
            pw + int(46 * s),
            GLOW_COLOR,
        )
    blur_r = max(1, int(22 * s))
    glow_img = glow_img.filter(ImageFilter.GaussianBlur(blur_r))
    img = Image.alpha_composite(img, glow_img)
    draw = ImageDraw.Draw(img)

    # Pass 2: claw marks
    for (p0, ctrl, p2), pw, color in zip(slashes, peak_widths, colors):
        draw_tapered_slash(
            draw,
            scale_pt(p0), scale_pt(ctrl), scale_pt(p2),
            pw,
            color,
        )

    # ── Green status dot (bottom-right) ───────────────────────────────────────
    dr = int(76 * s)
    dx = int(840 * s)
    dy = int(838 * s)

    # Outer ring (subtle darker rim for depth)
    draw.ellipse(
        [dx - dr - int(5*s), dy - dr - int(5*s),
         dx + dr + int(5*s), dy + dr + int(5*s)],
        fill=(20, 50, 30, 120),
    )
    # Main dot
    draw.ellipse([dx - dr, dy - dr, dx + dr, dy + dr],
                 fill=DOT_GREEN + (255,))
    # Specular highlight
    hl_w = int(26 * s)
    draw.ellipse(
        [dx - hl_w, dy - int(52*s), dx + hl_w, dy - int(18*s)],
        fill=DOT_HL,
    )

    return img


# ── Iconset entries (filename → render size in px) ───────────────────────────

ICONSET = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    scripts_dir  = os.path.dirname(os.path.abspath(__file__))
    iconset_dir  = os.path.join(scripts_dir, "AppIcon.iconset")
    icns_path    = os.path.join(scripts_dir, "AppIcon.icns")

    os.makedirs(iconset_dir, exist_ok=True)

    print("→ Rendering icon at 1024 × 1024…")
    base = make_icon(1024)

    for filename, px in ICONSET:
        out_path = os.path.join(iconset_dir, filename)
        if px == 1024:
            base.save(out_path)
        else:
            base.resize((px, px), Image.LANCZOS).save(out_path)
        print(f"   {filename:28s}  ({px}×{px})")

    print("→ Running iconutil…")
    result = subprocess.run(
        ["iconutil", "-c", "icns", iconset_dir, "-o", icns_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    shutil.rmtree(iconset_dir)
    size_kb = os.path.getsize(icns_path) // 1024
    print(f"\n✓  {icns_path}  ({size_kb} KB)")
    print("   Run 'make dmg' to bundle it into the next release.")


if __name__ == "__main__":
    main()
