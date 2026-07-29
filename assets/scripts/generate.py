# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools>=4.53", "uharfbuzz>=0.39", "cairosvg>=2.7"]
# ///
"""Generates the temporary 0.1 brand sources and exports (issue #85).

Everything is derived from the two variable fonts already bundled with the
app (assets/fonts/Fraunces-Variable.ttf, WorkSans-Variable.ttf) plus the
approved product palette (app/lib/core/theme/app_theme.dart, itself ported
from prototype/styles.css). No hand-drawn artwork exists: the temporary
mark is pure typography, so this script IS the editable source of record —
rerunning it reproduces every committed SVG and PNG bit-for-bit.

Run from the repository root:

    uv run assets/scripts/generate.py

It writes:
  - canonical SVG sources under assets/{brand,app-icon,splash}/**/source/
  - PNG exports under assets/**/exports/ and assets/app-icon/web/
  - the live Flutter web icons (app/web/favicon.png, app/web/icons/*)
  - the website favicon (website/assets/favicon.png)
and prints the pixel metrics used by the inline splash markup in
app/web/index.html (which embeds a copy of the wordmark/lettermark paths).
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import cairosvg
import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.misc.transform import Transform
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
FONTS = ROOT / "app" / "assets" / "fonts"

# approved product palette — app/lib/core/theme/app_theme.dart
TERRACOTTA = "#A44732"
INK = "#2A1F1B"
WHITE = "#FFFFFF"

# Fraunces is pinned to the exact instance the Flutter app renders:
# weight 600 (pubspec.yaml font config), every other axis at its
# default (opsz 9, SOFT 0, WONK 1) — Flutter applies no optical sizing.
FRAUNCES_AXES = {"wght": 600, "opsz": 9, "SOFT": 0, "WONK": 1}
WORKSANS_AXES = {"wght": 400}


class Shaped:
    """A harfbuzz-shaped run reduced to positioned SVG path data."""

    def __init__(self, font_path: Path, axes: dict, text: str):
        ttfont = instantiateVariableFont(
            TTFont(font_path), axes, inplace=False, updateFontNames=False
        )
        buf_bytes = io.BytesIO()
        ttfont.save(buf_bytes)
        face = hb.Face(buf_bytes.getvalue())
        font = hb.Font(face)
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(font, buf)

        self.upem = ttfont["head"].unitsPerEm
        glyph_order = ttfont.getGlyphOrder()
        glyph_set = ttfont.getGlyphSet()

        paths = []
        x = 0.0
        bounds = BoundsPen(glyph_set)
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            name = glyph_order[info.codepoint]
            offset = Transform().translate(x + pos.x_offset, pos.y_offset)
            svg_pen = SVGPathPen(glyph_set, ntos=lambda v: f"{v:.1f}")
            glyph_set[name].draw(TransformPen(svg_pen, offset))
            d = svg_pen.getCommands()
            if d:
                paths.append(d)
            glyph_set[name].draw(TransformPen(bounds, offset))
            x += pos.x_advance
        self.advance = x
        self.path = " ".join(paths)
        # font-unit tight bbox, y-up
        self.xmin, self.ymin, self.xmax, self.ymax = bounds.bounds

    def width_at(self, height_px: float) -> float:
        return height_px * (self.xmax - self.xmin) / (self.ymax - self.ymin)

    def svg_group(self, scale: float, tx: float, ty: float, fill: str) -> str:
        """Path group placed with its bbox top-left at (tx, ty), y-down."""
        t = (
            f"translate({tx:.2f} {ty:.2f}) scale({scale:.6f} {-scale:.6f}) "
            f"translate({-self.xmin:.1f} {-self.ymax:.1f})"
        )
        return f'<g transform="{t}"><path fill="{fill}" d="{self.path}"/></g>'


def svg_doc(width: float, height: float, body: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="0 0 {width:g} {height:g}" '
        f'width="{width:g}" height="{height:g}">\n{body}\n</svg>\n'
    )


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    print(f"  {path.relative_to(ROOT)}")


def png(svg: str, path: Path, width: int, height: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        bytestring=svg.encode(),
        write_to=str(path),
        output_width=width,
        output_height=height,
    )
    print(f"  {path.relative_to(ROOT)}")


def wordmark_svg(shaped: Shaped, height: float, fill: str, pad: float) -> str:
    scale = height / (shaped.ymax - shaped.ymin)
    w = shaped.width_at(height) + 2 * pad
    h = height + 2 * pad
    return svg_doc(w, h, shaped.svg_group(scale, pad, pad, fill))


def centered_glyph(
    shaped: Shaped, canvas: float, glyph_h: float, fill: str
) -> str:
    scale = glyph_h / (shaped.ymax - shaped.ymin)
    w = shaped.width_at(glyph_h)
    return shaped.svg_group(
        scale, (canvas - w) / 2, (canvas - glyph_h) / 2, fill
    )


def main() -> None:
    fraunces = FONTS / "Fraunces-Variable.ttf"
    worksans = FONTS / "WorkSans-Variable.ttf"

    wordmark = Shaped(fraunces, FRAUNCES_AXES, "tekir")
    lettermark = Shaped(fraunces, FRAUNCES_AXES, "t")
    # the prototype tagline wraps inside max-width 22em (styles.css
    # .splash-screen__tag); at 14px on a 360dp frame that is two lines.
    tagline_lines = [
        Shaped(worksans, WORKSANS_AXES, "İstanbul'un sokak kedilerini keşfet,"),
        Shaped(worksans, WORKSANS_AXES, "onlara göz kulak ol."),
    ]

    brand_src = ASSETS / "brand" / "temporary" / "source"
    brand_exp = ASSETS / "brand" / "temporary" / "exports"

    # ---- canonical wordmark / lettermark sources (terracotta, tight bbox
    # plus a small pad so strokes never touch the canvas edge)
    write(brand_src / "tekir-wordmark.svg", wordmark_svg(wordmark, 480, TERRACOTTA, 24))
    write(
        brand_src / "tekir-lettermark.svg",
        wordmark_svg(lettermark, 480, TERRACOTTA, 24),
    )

    # ---- transparent wordmark PNGs, three approved colors, two sizes
    for color, cname in ((TERRACOTTA, "terracotta"), (INK, "ink"), (WHITE, "white")):
        for h in (128, 512):
            pad = h * 0.05
            svg = wordmark_svg(wordmark, h, color, pad)
            png(
                svg,
                brand_exp / f"tekir-wordmark-{cname}-h{h}.png",
                round(wordmark.width_at(h) + 2 * pad),
                round(h + 2 * pad),
            )

    # ---- app icon master: full-bleed terracotta, white lettermark at 45%
    # of the canvas — inside the maskable safe zone (circle, r = 40% of
    # size) with margin, and still legible at favicon sizes.
    icon_body = (
        f'<rect width="1024" height="1024" fill="{TERRACOTTA}"/>'
        + centered_glyph(lettermark, 1024, 460, WHITE)
    )
    icon_svg = svg_doc(1024, 1024, icon_body)
    write(ASSETS / "app-icon" / "source" / "app-icon.svg", icon_svg)

    web_icons = ASSETS / "app-icon" / "web"
    for name, size in (
        ("Icon-192.png", 192),
        ("Icon-512.png", 512),
        ("Icon-maskable-192.png", 192),
        ("Icon-maskable-512.png", 512),
        ("favicon-32.png", 32),
    ):
        png(icon_svg, web_icons / name, size, size)
    png(icon_svg, brand_exp / "github-avatar.png", 500, 500)
    png(icon_svg, brand_exp / "firebase-icon.png", 512, 512)

    # ---- wire the generated icons into the live targets
    import shutil

    app_web = ROOT / "app" / "web"
    for name in (
        "Icon-192.png",
        "Icon-512.png",
        "Icon-maskable-192.png",
        "Icon-maskable-512.png",
    ):
        shutil.copyfile(web_icons / name, app_web / "icons" / name)
        print(f"  app/web/icons/{name}")
    shutil.copyfile(web_icons / "favicon-32.png", app_web / "favicon.png")
    print("  app/web/favicon.png")
    website_fav = ROOT / "website" / "assets" / "favicon.png"
    shutil.copyfile(web_icons / "favicon-32.png", website_fav)
    print(f"  {website_fav.relative_to(ROOT)}")

    # ---- ios: fill the Runner appiconset from the same master (sizes are
    # read from the checked-in Contents.json so Xcode stays the authority
    # on which slots exist), plus the native launch image — the splash
    # tile at 84pt, composited by LaunchScreen.storyboard over the same
    # terracotta the storyboard background carries.
    ios_iconset = ROOT / "app" / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    if ios_iconset.exists():
        contents = json.loads((ios_iconset / "Contents.json").read_text())
        for name in sorted(
            {img["filename"] for img in contents["images"] if "filename" in img}
        ):
            img = next(i for i in contents["images"] if i.get("filename") == name)
            points = float(img["size"].split("x")[0])
            scale = int(img["scale"].rstrip("x"))
            side = round(points * scale)
            png(icon_svg, ios_iconset / name, side, side)

    # ---- android: legacy launcher mipmaps from the full-bleed master,
    # plus the adaptive-icon foreground layer — lettermark on transparent,
    # sized so the visible 72dp of the 108dp canvas shows the glyph at the
    # same 45% the other platforms use (45% × 72/108 = 30% of the canvas),
    # comfortably inside the 66dp safe zone. the same layer serves as the
    # android 13 monochrome (themed-icon) source.
    android_res = ROOT / "app" / "android" / "app" / "src" / "main" / "res"
    if android_res.exists():
        densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
        fg_body = centered_glyph(lettermark, 108, 108 * 0.30, WHITE)
        fg_svg = svg_doc(108, 108, fg_body)
        for density, factor in densities.items():
            png(
                icon_svg,
                android_res / f"mipmap-{density}" / "ic_launcher.png",
                round(48 * factor),
                round(48 * factor),
            )
            png(
                fg_svg,
                android_res / f"mipmap-{density}" / "ic_launcher_foreground.png",
                round(108 * factor),
                round(108 * factor),
            )

    # ---- play listing exports: 512 icon and the required 1024x500
    # feature graphic (wordmark centered on terracotta)
    play_dir = ASSETS / "app-icon" / "android"
    png(icon_svg, play_dir / "play-icon-512.png", 512, 512)
    fg_h = 120.0
    feature_body = (
        f'<rect width="1024" height="500" fill="{TERRACOTTA}"/>'
        + wordmark.svg_group(
            fg_h / (wordmark.ymax - wordmark.ymin),
            (1024 - wordmark.width_at(fg_h)) / 2,
            (500 - fg_h) / 2,
            WHITE,
        )
    )
    png(
        svg_doc(1024, 500, feature_body),
        ASSETS / "store" / "listing" / "play-feature-graphic.png",
        1024,
        500,
    )

    # ---- splash mark: the prototype's 84px tile (radius 28, white 14%)
    # holding the lettermark where the placeholder paw used to be
    # (prototype/styles.css .splash-screen__mark; issue #85 replaces the
    # paw with the wordmark-derived temporary mark).
    mark_body = (
        '<rect width="84" height="84" rx="28" fill="#FFFFFF" fill-opacity="0.14"/>'
        + centered_glyph(lettermark, 84, 40, WHITE)
    )
    mark_svg = svg_doc(84, 84, mark_body)
    write(ASSETS / "splash" / "source" / "splash-mark.svg", mark_svg)

    ios_launch = (
        ROOT / "app" / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
    )
    if ios_launch.exists():
        for scale in (1, 2, 3):
            suffix = "" if scale == 1 else f"@{scale}x"
            png(mark_svg, ios_launch / f"LaunchImage{suffix}.png", 84 * scale, 84 * scale)

    # android native launch drawable: the same 84dp tile per density
    # (drawable/launch_background.xml centers it on terracotta)
    if android_res.exists():
        for density, factor in densities.items():
            png(
                mark_svg,
                android_res / f"drawable-{density}" / "splash_mark.png",
                round(84 * factor),
                round(84 * factor),
            )

    # ---- full splash reference frame: the prototype composition
    # (splash-screen: centered column, gap 16) on a 360x780dp viewport
    # rendered at 3x for a 1080x2340 export.
    fw, fh = 360.0, 780.0
    word_h = 30 * (wordmark.ymax - wordmark.ymin) / wordmark.upem
    gap = 16.0
    tag_line_h = 14 * 1.5  # prototype line-height 1.5
    total = 84 + gap + word_h + gap + tag_line_h * len(tagline_lines)
    y = (fh - total) / 2
    parts = [f'<rect width="{fw:g}" height="{fh:g}" fill="{TERRACOTTA}"/>']
    parts.append(
        f'<g transform="translate({(fw - 84) / 2:.2f} {y:.2f})">{mark_body}</g>'
    )
    y += 84 + gap
    scale = 30 / wordmark.upem
    parts.append(
        wordmark.svg_group(scale, (fw - wordmark.width_at(word_h)) / 2, y, WHITE)
    )
    y += word_h + gap
    for line in tagline_lines:
        line_h = 14 * (line.ymax - line.ymin) / line.upem
        line_w = line.width_at(line_h)
        line_y = y + (tag_line_h - line_h) / 2
        parts.append(
            '<g fill-opacity="0.82">'
            + line.svg_group(14 / line.upem, (fw - line_w) / 2, line_y, WHITE)
            + "</g>"
        )
        y += tag_line_h
    splash_svg = svg_doc(fw, fh, "\n".join(parts))
    write(ASSETS / "splash" / "source" / "splash-screen.svg", splash_svg)
    png(splash_svg, ASSETS / "splash" / "exports" / "splash-1080x2340.png", 1080, 2340)

    # ---- metrics for the inline pre-flutter splash in app/web/index.html
    print("\ninline splash metrics (app/web/index.html):")
    print(
        f"  wordmark tight box at font-size 30px: "
        f"{wordmark.width_at(word_h):.2f} x {word_h:.2f} px"
    )
    lm_h = 40.0
    print(f"  lettermark at {lm_h:g}px tall: {lettermark.width_at(lm_h):.2f} px wide")
    print(f"  wordmark viewBox: 0 0 {wordmark.xmax - wordmark.xmin:.1f} "
          f"{wordmark.ymax - wordmark.ymin:.1f}")


if __name__ == "__main__":
    main()
