"""Generate Android launcher / Play Store icons from the ice-arrow brand mark."""

from __future__ import annotations

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "brand" / "aurora_logo_ice_arrow_faceted.jpg"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
BRAND = ROOT / "assets" / "brand"

LEGACY = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

FOREGROUND = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}


def main() -> None:
    src = Image.open(SRC).convert("RGBA")
    master = src.resize((1024, 1024), Image.Resampling.LANCZOS)

    bg = master.getpixel((8, 8))[:3]
    bg_hex = "#{:02X}{:02X}{:02X}".format(*bg)
    print("bg_hex", bg_hex, bg)

    play = master.resize((512, 512), Image.Resampling.LANCZOS).convert("RGB")
    play.save(BRAND / "ic_launcher-playstore.png", "PNG", optimize=True)
    master.convert("RGB").save(
        BRAND / "aurora_logo_ice_arrow_faceted_1024.png", "PNG", optimize=True
    )
    master.convert("RGB").save(
        BRAND / "aurora_logo_ice_arrow_faceted.png", "PNG", optimize=True
    )

    for folder, size in LEGACY.items():
        out = RES / folder
        out.mkdir(parents=True, exist_ok=True)
        img = master.resize((size, size), Image.Resampling.LANCZOS).convert("RGB")
        img.save(out / "ic_launcher.png", "PNG", optimize=True)
        print("legacy", folder, size)

    for folder, size in FOREGROUND.items():
        out = RES / folder
        out.mkdir(parents=True, exist_ok=True)
        # Full-bleed adaptive foreground; system mask applies final shape.
        img = master.resize((size, size), Image.Resampling.LANCZOS)
        img.save(out / "ic_launcher_foreground.png", "PNG", optimize=True)
        print("fg", folder, size)

    colors = RES / "values" / "colors.xml"
    colors.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        f'    <color name="ic_launcher_background">{bg_hex}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    print("wrote colors", bg_hex)

    for folder, size in LEGACY.items():
        im = Image.open(RES / folder / "ic_launcher.png")
        assert im.size == (size, size), (folder, im.size)
    for folder, size in FOREGROUND.items():
        im = Image.open(RES / folder / "ic_launcher_foreground.png")
        assert im.size == (size, size), (folder, im.size)

    print("OK all sizes")
    print("playstore", Image.open(BRAND / "ic_launcher-playstore.png").size)


if __name__ == "__main__":
    main()
