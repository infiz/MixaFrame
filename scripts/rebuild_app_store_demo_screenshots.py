#!/usr/bin/env python3
"""Reframe MixaFrame demo screenshots without cropping animal bodies."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parent.parent
SCREENSHOT_ROOT = ROOT / "AppStoreScreenshots"
RAW_DIRECTORY = SCREENSHOT_ROOT / "Raw"
PHOTO_DIRECTORY = SCREENSHOT_ROOT / "Assets" / "DemoPhotos"

PURPLE = (101, 82, 246)
YELLOW = (255, 215, 0)


@dataclass(frozen=True)
class Cell:
    photo: str
    x: int
    y: int
    width: int
    height: int


def photo(name: str) -> Image.Image:
    return Image.open(PHOTO_DIRECTORY / name).convert("RGB")


def fit(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    """Fit the complete source image inside a cell without cropping."""
    scale = min(size[0] / image.width, size[1] / image.height)
    return image.resize(
        (round(image.width * scale), round(image.height * scale)),
        Image.Resampling.LANCZOS,
    )


def paste_fitted(
    canvas: Image.Image,
    image: Image.Image,
    frame: tuple[int, int, int, int],
    background: tuple[int, int, int],
) -> None:
    x, y, width, height = frame
    canvas.paste(background, (x, y, x + width, y + height))
    fitted = fit(image, (width, height))
    left = x + (width - fitted.width) // 2
    top = y + (height - fitted.height) // 2
    canvas.paste(fitted, (left, top))


def row(
    names: tuple[str, ...],
    x: int,
    y: int,
    width: int,
    gap: int = 10,
) -> tuple[list[Cell], int]:
    """Build one uncropped row whose widths follow the source aspect ratios."""
    images = [photo(name) for name in names]
    ratios = [image.width / image.height for image in images]
    available_width = width - gap * (len(names) - 1)
    height = round(available_width / sum(ratios))
    widths = [round(height * ratio) for ratio in ratios]
    widths[-1] += available_width - sum(widths)

    cells: list[Cell] = []
    cursor = x
    for name, cell_width in zip(names, widths):
        cells.append(Cell(name, cursor, y, cell_width, height))
        cursor += cell_width + gap
    return cells, height


def collage(
    canvas: Image.Image,
    rows: tuple[tuple[str, ...], ...],
    x: int,
    y: int,
    width: int,
    background: tuple[int, int, int],
    gap: int = 10,
) -> int:
    cursor = y
    for names in rows:
        cells, height = row(names, x, cursor, width, gap)
        for cell in cells:
            paste_fitted(
                canvas,
                photo(cell.photo),
                (cell.x, cell.y, cell.width, cell.height),
                background,
            )
        cursor += height + gap
    return cursor - gap


def clear(canvas: Image.Image, box: tuple[int, int, int, int], color: str) -> None:
    ImageDraw.Draw(canvas).rectangle(box, fill=color)


def rebuild_editor_overview() -> None:
    path = RAW_DIRECTORY / "01-smart-collage.png"
    canvas = Image.open(path).convert("RGB")
    clear(canvas, (0, 348, canvas.width, 2160), "white")
    collage(
        canvas,
        (
            ("winged-bird.jpg",),
            ("walking-bird.jpg", "perched-bird.jpg"),
            ("ocelot.jpg", "jaguar-closeup.jpg"),
        ),
        48,
        430,
        1110,
        (255, 255, 255),
        12,
    )
    canvas.save(path, "PNG", compress_level=9)


def rebuild_layout_picker() -> None:
    path = RAW_DIRECTORY / "02-layouts-portrait.png"
    canvas = Image.open(path).convert("RGB")
    clear(canvas, (230, 348, 978, 1285), "white")
    collage(
        canvas,
        (
            ("winged-bird.jpg",),
            ("walking-bird.jpg", "perched-bird.jpg"),
        ),
        238,
        400,
        730,
        (255, 255, 255),
        8,
    )
    canvas.save(path, "PNG", compress_level=9)


def rebuild_focus_panel() -> None:
    path = RAW_DIRECTORY / "03-smart-focus.png"
    canvas = Image.open(path).convert("RGB")
    clear(canvas, (230, 348, 978, 1285), "black")
    collage(
        canvas,
        (
            ("winged-bird.jpg",),
            ("walking-bird.jpg", "perched-bird.jpg"),
        ),
        238,
        400,
        730,
        (0, 0, 0),
        8,
    )
    canvas.save(path, "PNG", compress_level=9)


def dashed_rectangle(
    draw: ImageDraw.ImageDraw,
    box: tuple[int, int, int, int],
    fill: tuple[int, int, int],
    width: int,
    dash: int,
    space: int,
) -> None:
    left, top, right, bottom = box
    for x in range(left, right, dash + space):
        draw.line((x, top, min(x + dash, right), top), fill=fill, width=width)
        draw.line((x, bottom, min(x + dash, right), bottom), fill=fill, width=width)
    for y in range(top, bottom, dash + space):
        draw.line((left, y, left, min(y + dash, bottom)), fill=fill, width=width)
        draw.line((right, y, right, min(y + dash, bottom)), fill=fill, width=width)


def rebuild_photo_adjustment() -> None:
    path = RAW_DIRECTORY / "04-adjust-photo.png"
    canvas = Image.open(path).convert("RGB")
    clear(canvas, (0, 470, canvas.width, 1800), "black")

    source = photo("ocelot.jpg")
    fitted = fit(source, (930, 1215))
    left = (canvas.width - fitted.width) // 2
    top = 525
    canvas.paste(fitted, (left, top))

    draw = ImageDraw.Draw(canvas)
    crop_box = (left + 35, top + 35, left + fitted.width - 35, top + fitted.height - 35)
    dashed_rectangle(draw, crop_box, YELLOW, 9, 24, 16)

    label_font = ImageFont.truetype(
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf", 30
    )
    label = "COLLAGE CROP"
    bounds = draw.textbbox((0, 0), label, font=label_font)
    label_width = bounds[2] - bounds[0] + 42
    draw.rounded_rectangle(
        (crop_box[0] + 10, crop_box[1] + 12, crop_box[0] + 10 + label_width, crop_box[1] + 64),
        radius=24,
        fill=YELLOW,
    )
    draw.text(
        (crop_box[0] + 31, crop_box[1] + 19),
        label,
        font=label_font,
        fill="black",
    )

    focus_x = left + round(fitted.width * 0.64)
    focus_y = top + round(fitted.height * 0.37)
    draw.ellipse(
        (focus_x - 42, focus_y - 42, focus_x + 42, focus_y + 42),
        fill=(255, 255, 255),
        outline=(255, 255, 255),
        width=4,
    )
    draw.ellipse(
        (focus_x - 34, focus_y - 34, focus_x + 34, focus_y + 34),
        fill=(109, 89, 246),
    )
    draw.ellipse(
        (focus_x - 6, focus_y - 6, focus_x + 6, focus_y + 6), fill="white"
    )
    canvas.save(path, "PNG", compress_level=9)


def rebuild_export_preview() -> None:
    path = RAW_DIRECTORY / "05-export-preview.png"
    canvas = Image.open(path).convert("RGB")
    clear(canvas, (0, 460, canvas.width, 2105), "black")
    collage_bottom = collage(
        canvas,
        (
            ("winged-bird.jpg",),
            ("walking-bird.jpg", "perched-bird.jpg"),
        ),
        0,
        500,
        canvas.width,
        (0, 0, 0),
        12,
    )

    draw = ImageDraw.Draw(canvas)
    control_y = 1935
    draw.rounded_rectangle(
        (310, control_y - 58, 900, control_y + 58),
        radius=50,
        fill=(18, 18, 18),
    )
    control_font = ImageFont.truetype(
        "/System/Library/Fonts/Supplemental/Arial.ttf", 42
    )
    symbol_font = ImageFont.truetype(
        "/System/Library/Fonts/Supplemental/Arial.ttf", 58
    )
    draw.text((350, control_y - 38), "−", font=symbol_font, fill="white")
    draw.text((480, control_y - 24), "100%", font=control_font, fill="white")
    draw.text((681, control_y - 38), "+", font=symbol_font, fill="white")
    reset_font = ImageFont.truetype(
        "/System/Library/Fonts/Supplemental/Arial.ttf", 32
    )
    draw.text((793, control_y - 18), "Reset", font=reset_font, fill="white")

    watermark_font = ImageFont.truetype(
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf", 36
    )
    draw.rounded_rectangle(
        (930, control_y - 48, 1180, control_y + 48),
        radius=42,
        fill=(18, 18, 18),
    )
    draw.text((957, control_y - 22), "MixaFrame", font=watermark_font, fill="white")

    # Keep a deliberate breathing area between the image and manipulation controls.
    if collage_bottom > control_y - 80:
        raise ValueError("Export collage overlaps its preview controls")
    canvas.save(path, "PNG", compress_level=9)


def rebuild_featured_layout() -> None:
    path = RAW_DIRECTORY / "06-featured-layout.png"
    canvas = Image.open(path).convert("RGB")
    clear(canvas, (0, 700, canvas.width, 2150), "black")

    x = 48
    y = 740
    width = 1110
    gap = 12
    top_height = round(width / (1168 / 673))
    paste_fitted(
        canvas,
        photo("winged-bird.jpg"),
        (x, y, width, top_height),
        (0, 0, 0),
    )

    lower_y = y + top_height + gap
    lower_height = 790
    ocelot_width = round(lower_height * (2204 / 2881))
    right_x = x + ocelot_width + gap
    right_width = width - ocelot_width - gap
    paste_fitted(
        canvas,
        photo("ocelot.jpg"),
        (x, lower_y, ocelot_width, lower_height),
        (0, 0, 0),
    )

    walking = photo("walking-bird.jpg")
    walking_height = round(right_width / (walking.width / walking.height))
    paste_fitted(
        canvas,
        walking,
        (right_x, lower_y, right_width, walking_height),
        (0, 0, 0),
    )
    paste_fitted(
        canvas,
        photo("perched-bird.jpg"),
        (
            right_x,
            lower_y + walking_height + gap,
            right_width,
            lower_height - walking_height - gap,
        ),
        (0, 0, 0),
    )
    canvas.save(path, "PNG", compress_level=9)


def project_thumbnail(kind: str, size: tuple[int, int]) -> Image.Image:
    thumbnail = Image.new("RGB", size, "black")
    gap = 3
    if kind == "wildlife":
        top_height = round(size[0] / (1168 / 673))
        paste_fitted(
            thumbnail,
            photo("winged-bird.jpg"),
            (0, 0, size[0], min(top_height, size[1] - 54)),
            (0, 0, 0),
        )
        lower_y = min(top_height, size[1] - 54) + gap
        lower_height = size[1] - lower_y
        left_width = round((size[0] - gap) * 0.56)
        paste_fitted(
            thumbnail,
            photo("walking-bird.jpg"),
            (0, lower_y, left_width, lower_height),
            (0, 0, 0),
        )
        paste_fitted(
            thumbnail,
            photo("perched-bird.jpg"),
            (left_width + gap, lower_y, size[0] - left_width - gap, lower_height),
            (0, 0, 0),
        )
    elif kind == "birds":
        left_width = round((size[0] - gap) * 0.58)
        paste_fitted(
            thumbnail,
            photo("walking-bird.jpg"),
            (0, 0, left_width, size[1]),
            (0, 0, 0),
        )
        right_width = size[0] - left_width - gap
        top_height = (size[1] - gap) // 2
        paste_fitted(
            thumbnail,
            photo("winged-bird.jpg"),
            (left_width + gap, 0, right_width, top_height),
            (0, 0, 0),
        )
        paste_fitted(
            thumbnail,
            photo("perched-bird.jpg"),
            (
                left_width + gap,
                top_height + gap,
                right_width,
                size[1] - top_height - gap,
            ),
            (0, 0, 0),
        )
    else:
        left_width = round((size[0] - gap) * 0.48)
        paste_fitted(
            thumbnail,
            photo("ocelot.jpg"),
            (0, 0, left_width, size[1]),
            (0, 0, 0),
        )
        paste_fitted(
            thumbnail,
            photo("jaguar-closeup.jpg"),
            (left_width + gap, 0, size[0] - left_width - gap, size[1]),
            (0, 0, 0),
        )
    return thumbnail


def rounded(image: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, image.width, image.height), radius=radius, fill=255
    )
    result = image.convert("RGBA")
    result.putalpha(mask)
    return result


def rebuild_saved_project() -> None:
    base_path = RAW_DIRECTORY / "01-smart-collage.png"
    output_path = RAW_DIRECTORY / "07-saved-project.png"
    canvas = Image.open(base_path).convert("RGB")
    draw = ImageDraw.Draw(canvas)

    background = (242, 242, 247)
    navigation = (247, 247, 250)
    draw.rectangle((0, 150, canvas.width, canvas.height), fill=background)
    draw.rectangle((0, 150, canvas.width, 430), fill=navigation)
    draw.line((0, 429, canvas.width, 429), fill=(220, 220, 225), width=2)

    regular = "/System/Library/Fonts/Supplemental/Arial.ttf"
    bold = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
    navigation_font = ImageFont.truetype(regular, 43)
    title_font = ImageFont.truetype(bold, 58)
    row_title_font = ImageFont.truetype(bold, 38)
    detail_font = ImageFont.truetype(regular, 29)
    saved_font = ImageFont.truetype(regular, 25)
    plus_font = ImageFont.truetype(regular, 58)
    chevron_font = ImageFont.truetype(regular, 56)

    draw.text((46, 205), "‹", font=plus_font, fill=PURPLE)
    draw.text((86, 218), "MixaFrame", font=navigation_font, fill=PURPLE)
    draw.text((1090, 197), "+", font=plus_font, fill=PURPLE)
    draw.text((48, 326), "Wild Encounters", font=title_font, fill="black")

    rows = (
        (
            "wildlife",
            "Rainforest Collection",
            "5 photos · Smart Grid",
            "Last saved Aug 16, 9:41 AM",
        ),
        (
            "birds",
            "Birds in Motion",
            "3 photos · Featured",
            "Last saved Aug 15, 6:24 PM",
        ),
        (
            "portraits",
            "Wildlife Portraits",
            "2 photos · Grid",
            "Last saved Aug 14, 3:18 PM",
        ),
    )

    row_left = 32
    row_width = canvas.width - row_left * 2
    row_height = 254
    row_gap = 22
    first_y = 474
    thumbnail_size = (240, 184)

    for index, (kind, title, detail, saved) in enumerate(rows):
        top = first_y + index * (row_height + row_gap)
        draw.rounded_rectangle(
            (row_left, top, row_left + row_width, top + row_height),
            radius=24,
            fill="white",
        )
        thumbnail = rounded(project_thumbnail(kind, thumbnail_size), 18)
        canvas.paste(thumbnail, (68, top + 35), thumbnail)
        text_x = 340
        draw.text((text_x, top + 43), title, font=row_title_font, fill=(20, 20, 23))
        draw.text((text_x, top + 100), detail, font=detail_font, fill=(105, 105, 112))
        draw.text((text_x, top + 151), saved, font=saved_font, fill=(150, 150, 158))
        draw.text((1111, top + 88), "›", font=chevron_font, fill=(176, 176, 183))

    hint_top = first_y + len(rows) * (row_height + row_gap) + 60
    draw.rounded_rectangle(
        (145, hint_top, canvas.width - 145, hint_top + 104),
        radius=52,
        fill=(232, 230, 253),
    )
    hint_font = ImageFont.truetype(bold, 31)
    hint = "Tap a saved project to continue editing"
    bounds = draw.textbbox((0, 0), hint, font=hint_font)
    hint_width = bounds[2] - bounds[0]
    draw.text(
        ((canvas.width - hint_width) // 2, hint_top + 33),
        hint,
        font=hint_font,
        fill=PURPLE,
    )

    canvas.save(output_path, "PNG", compress_level=9)


def main() -> None:
    required = {
        "ocelot.jpg",
        "walking-bird.jpg",
        "winged-bird.jpg",
        "jaguar-closeup.jpg",
        "perched-bird.jpg",
    }
    missing = sorted(name for name in required if not (PHOTO_DIRECTORY / name).exists())
    if missing:
        raise FileNotFoundError(f"Missing demo photos: {', '.join(missing)}")

    rebuild_editor_overview()
    rebuild_layout_picker()
    rebuild_focus_panel()
    rebuild_photo_adjustment()
    rebuild_export_preview()
    rebuild_featured_layout()
    rebuild_saved_project()
    print("Rebuilt AppStoreScreenshots/Raw with full-source animal framing")


if __name__ == "__main__":
    main()
