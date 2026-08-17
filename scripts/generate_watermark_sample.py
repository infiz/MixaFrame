#!/usr/bin/env python3
"""Render a sample collage with MixaFrame's current free-export watermark."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent.parent
PHOTO_DIRECTORY = ROOT / "AppStoreScreenshots" / "Assets" / "DemoPhotos"
OUTPUT_DIRECTORY = ROOT / "AppStoreScreenshots" / "Samples"
OUTPUT_PATH = OUTPUT_DIRECTORY / "MixaFrame-Free-Watermark-Sample.jpg"

WIDTH = 1242
GAP = 12
BACKGROUND = (17, 17, 17)


def photo(name: str) -> Image.Image:
    return Image.open(PHOTO_DIRECTORY / name).convert("RGB")


def add_row(canvas: Image.Image, names: tuple[str, ...], top: int) -> int:
    images = [photo(name) for name in names]
    available_width = WIDTH - GAP * (len(images) - 1)
    ratios = [image.width / image.height for image in images]
    height = round(available_width / sum(ratios))
    widths = [round(height * ratio) for ratio in ratios]
    widths[-1] += available_width - sum(widths)

    left = 0
    for image, cell_width in zip(images, widths):
        resized = image.resize((cell_width, height), Image.Resampling.LANCZOS)
        canvas.paste(resized, (left, top))
        left += cell_width + GAP
    return top + height


def tracked_text_layer(
    size: tuple[int, int],
    text: str,
    font: ImageFont.FreeTypeFont,
    tracking: float,
    fill: tuple[int, int, int, int],
) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    widths = [draw.textlength(character, font=font) for character in text]
    text_width = sum(widths) + tracking * max(0, len(text) - 1)
    bounds = draw.textbbox((0, 0), text, font=font)
    text_height = bounds[3] - bounds[1]
    x = (size[0] - text_width) / 2
    y = (size[1] - text_height) / 2 - bounds[1]
    for character, width in zip(text, widths):
        draw.text((x, y), character, font=font, fill=fill)
        x += width + tracking
    return layer


def add_watermark(canvas: Image.Image) -> None:
    shortest_side = min(canvas.size)
    brand_size = max(18, round(shortest_side * 0.04))
    caption_size = max(6, round(brand_size * 0.3))
    brand_font = ImageFont.truetype(
        "/System/Library/Fonts/Avenir Next.ttc", brand_size, index=2
    )
    caption_font = ImageFont.truetype(
        "/System/Library/Fonts/SFNS.ttf", caption_size
    )
    brand_tracking = brand_size * 0.018
    caption_tracking = caption_size * 0.14

    measure = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    brand_width = measure.textlength("MixaFrame", font=brand_font) + brand_tracking * 8
    caption_width = measure.textlength("CREATED WITH", font=caption_font) + caption_tracking * 11
    brand_bounds = measure.textbbox((0, 0), "MixaFrame", font=brand_font)
    caption_bounds = measure.textbbox((0, 0), "CREATED WITH", font=caption_font)
    brand_height = brand_bounds[3] - brand_bounds[1]
    caption_height = caption_bounds[3] - caption_bounds[1]

    horizontal_padding = brand_size * 0.78
    vertical_padding = brand_size * 0.38
    line_spacing = brand_size * 0.08
    badge_width = round(max(brand_width, caption_width) + horizontal_padding * 2)
    badge_height = round(
        caption_height + line_spacing + brand_height + vertical_padding * 2
    )
    margin = max(brand_size * 0.72, shortest_side * 0.025)
    left = round(canvas.width - badge_width - margin)
    top = round(canvas.height - badge_height - margin)

    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        (left, top, left + badge_width, top + badge_height),
        radius=badge_height // 2,
        fill=(0, 0, 0, 173),
        outline=(255, 255, 255, 56),
        width=max(1, round(brand_size * 0.025)),
    )

    caption_layer = tracked_text_layer(
        (badge_width, round(caption_height + 8)),
        "CREATED WITH",
        caption_font,
        caption_tracking,
        (255, 255, 255, 209),
    )
    content_height = caption_height + line_spacing + brand_height
    caption_y = round(top + (badge_height - content_height) / 2)
    overlay.alpha_composite(caption_layer, (left, caption_y))

    brand_layer = tracked_text_layer(
        (badge_width, round(brand_height + 18)),
        "MixaFrame",
        brand_font,
        brand_tracking,
        (255, 255, 255, 255),
    )
    brand_y = round(caption_y + caption_height + line_spacing)
    shadow = brand_layer.getchannel("A").filter(
        ImageFilter.GaussianBlur(radius=brand_size * 0.12)
    )
    shadow_layer = Image.new("RGBA", brand_layer.size, (0, 0, 0, 0))
    shadow_layer.putalpha(shadow.point(lambda alpha: round(alpha * 0.45)))
    overlay.alpha_composite(
        shadow_layer,
        (left, brand_y + round(brand_size * 0.06)),
    )
    overlay.alpha_composite(brand_layer, (left, brand_y))
    canvas.paste(Image.alpha_composite(canvas.convert("RGBA"), overlay).convert("RGB"))


def main() -> None:
    rows = (
        ("winged-bird.jpg",),
        ("walking-bird.jpg", "perched-bird.jpg"),
        ("ocelot.jpg", "jaguar-closeup.jpg"),
    )
    row_heights = []
    for names in rows:
        images = [photo(name) for name in names]
        available_width = WIDTH - GAP * (len(images) - 1)
        row_heights.append(round(available_width / sum(i.width / i.height for i in images)))
    height = sum(row_heights) + GAP * (len(rows) - 1)
    canvas = Image.new("RGB", (WIDTH, height), BACKGROUND)

    top = 0
    for names in rows:
        top = add_row(canvas, names, top) + GAP

    add_watermark(canvas)
    OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    canvas.save(OUTPUT_PATH, "JPEG", quality=94, optimize=True)
    print(OUTPUT_PATH)


if __name__ == "__main__":
    main()
