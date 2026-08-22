#!/usr/bin/env python3
"""Build MixaFrame's 6.5-inch iPhone App Store promotional screenshots."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent.parent
SCREENSHOT_ROOT = ROOT / "AppStoreScreenshots"
RAW_DIRECTORY = SCREENSHOT_ROOT / "iPhone" / "Raw"
OUTPUT_DIRECTORY = SCREENSHOT_ROOT / "iPhone" / "Promotional"
BACKGROUND_PATH = SCREENSHOT_ROOT / "Assets" / "promo-background.png"

CANVAS_SIZE = (1284, 2778)
SCREEN_SIZE = (1028, 2234)
SCREEN_LEFT = (CANVAS_SIZE[0] - SCREEN_SIZE[0]) // 2
SCREEN_TOP = 544
SCREEN_RADIUS = 58

TITLE_FONT_PATH = Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf")
EYEBROW_FONT_PATH = Path("/System/Library/Fonts/SFNS.ttf")


@dataclass(frozen=True)
class Promotion:
    output_name: str
    source_name: str
    title: tuple[str, ...]


PROMOTIONS = (
    Promotion(
        "01-one-story.png",
        "01-smart-collage.png",
        ("Turn photos into", "one story."),
    ),
    Promotion(
        "02-layouts-that-fit.png",
        "02-layouts-portrait.png",
        ("Find a layout", "that truly fits."),
    ),
    Promotion(
        "03-smart-focus.png",
        "03-smart-focus.png",
        ("Smart focus keeps", "subjects in frame."),
    ),
    Promotion(
        "04-adjust-every-photo.png",
        "04-adjust-photo.png",
        ("Crop. Reposition.", "Pinch to zoom."),
    ),
    Promotion(
        "05-featured-layout.png",
        "06-featured-layout.png",
        ("One photo leads.", "The rest support it."),
    ),
    Promotion(
        "06-export-preview.png",
        "05-export-preview.png",
        ("Preview every detail", "before you export."),
    ),
    Promotion(
        "07-saved-projects.png",
        "07-saved-project.png",
        ("Projects stay saved.", "Re-edit anytime."),
    ),
)


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    scale = max(size[0] / image.width, size[1] / image.height)
    resized = image.resize(
        (round(image.width * scale), round(image.height * scale)),
        Image.Resampling.LANCZOS,
    )
    left = (resized.width - size[0]) // 2
    top = (resized.height - size[1]) // 2
    return resized.crop((left, top, left + size[0], top + size[1]))


def centered_text(
    draw: ImageDraw.ImageDraw,
    y: int,
    text: str,
    font: ImageFont.FreeTypeFont,
    fill: str,
) -> None:
    bounds = draw.textbbox((0, 0), text, font=font)
    width = bounds[2] - bounds[0]
    draw.text(((CANVAS_SIZE[0] - width) / 2, y), text, font=font, fill=fill)


def title_layer(lines: tuple[str, ...]) -> Image.Image:
    layer = Image.new("RGBA", (CANVAS_SIZE[0], 504), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    eyebrow_font = ImageFont.truetype(str(EYEBROW_FONT_PATH), 27)
    title_font = ImageFont.truetype(str(TITLE_FONT_PATH), 89)

    centered_text(draw, 35, "M I X A F R A M E", eyebrow_font, "#5B4CF0")
    for index, line in enumerate(lines):
        centered_text(draw, 105 + index * 105, line, title_font, "#17141F")
    return layer


def rounded_screen(source_path: Path) -> Image.Image:
    screen = Image.open(source_path).convert("RGB").resize(
        SCREEN_SIZE, Image.Resampling.LANCZOS
    )
    mask = Image.new("L", SCREEN_SIZE, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, SCREEN_SIZE[0], SCREEN_SIZE[1]),
        radius=SCREEN_RADIUS,
        fill=255,
    )
    result = screen.convert("RGBA")
    result.putalpha(mask)
    return result


def screen_shadow() -> Image.Image:
    padding = 60
    shadow = Image.new(
        "RGBA", (SCREEN_SIZE[0] + padding * 2, SCREEN_SIZE[1] + padding * 2)
    )
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle(
        (padding, padding - 24, padding + SCREEN_SIZE[0], padding - 24 + SCREEN_SIZE[1]),
        radius=SCREEN_RADIUS,
        fill=(23, 20, 31, 72),
    )
    return shadow.filter(ImageFilter.GaussianBlur(28))


def generate(promotion: Promotion, background: Image.Image, shadow: Image.Image) -> Path:
    source_path = RAW_DIRECTORY / promotion.source_name
    if not source_path.exists():
        raise FileNotFoundError(f"Missing raw screenshot: {source_path}")

    composition = background.copy().convert("RGBA")
    composition.alpha_composite(title_layer(promotion.title), (0, 0))
    composition.alpha_composite(shadow, (SCREEN_LEFT - 60, SCREEN_TOP - 36))
    composition.alpha_composite(rounded_screen(source_path), (SCREEN_LEFT, SCREEN_TOP))

    output_path = OUTPUT_DIRECTORY / promotion.output_name
    composition.convert("RGB").save(output_path, "PNG", compress_level=9)
    return output_path


def main() -> None:
    if not BACKGROUND_PATH.exists():
        raise FileNotFoundError(f"Missing promotional background: {BACKGROUND_PATH}")

    OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    background = cover(Image.open(BACKGROUND_PATH).convert("RGB"), CANVAS_SIZE)
    shadow = screen_shadow()

    for promotion in PROMOTIONS:
        output_path = generate(promotion, background, shadow)
        print(f"Created {output_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
