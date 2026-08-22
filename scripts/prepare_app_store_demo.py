#!/usr/bin/env python3
"""Seed a deterministic MixaFrame demo library in an iOS Simulator container."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCREENSHOT_ROOT = ROOT / "AppStoreScreenshots"
PHOTO_DIRECTORY = SCREENSHOT_ROOT / "Assets" / "DemoPhotos"
DEMO_DATE = "2026-08-16T16:41:00Z"

COLLECTION_ID = "D0000000-0000-0000-0000-000000000001"


def photo(
    identifier: str,
    file_name: str,
    width: int,
    height: int,
    focal_x: float = 0.5,
    focal_y: float = 0.5,
) -> dict[str, object]:
    return {
        "id": identifier,
        "fileName": file_name,
        "pixelWidth": width,
        "pixelHeight": height,
        "focalX": focal_x,
        "focalY": focal_y,
        "focusSource": "automatic",
        "hasCompletedFocusDetection": True,
    }


def project(
    identifier: str,
    collection_id: str,
    name: str,
    photos: list[dict[str, object]],
    layout: str,
    layout_id: str | None = None,
) -> dict[str, object]:
    value: dict[str, object] = {
        "id": identifier,
        "collectionID": collection_id,
        "name": name,
        "createdAt": DEMO_DATE,
        "modifiedAt": DEMO_DATE,
        "photos": photos,
        "layout": layout,
        "canvas": "portrait",
        "outputMaxDimension": 4096,
        "outputFormat": "jpeg",
        "quality": "balanced",
        "spacing": 12,
        "backgroundHex": "111111",
    }
    if layout_id:
        value["layoutID"] = layout_id
    return value


def demo_library() -> list[dict[str, object]]:
    wildlife = [
        photo("A0000000-0000-0000-0000-000000000001", "winged-bird.jpg", 1168, 673, 0.54, 0.47),
        photo("A0000000-0000-0000-0000-000000000002", "walking-bird.jpg", 1792, 1470, 0.48, 0.53),
        photo("A0000000-0000-0000-0000-000000000003", "perched-bird.jpg", 1792, 1470, 0.52, 0.50),
        photo("A0000000-0000-0000-0000-000000000004", "ocelot.jpg", 2204, 2881, 0.58, 0.40),
        photo("A0000000-0000-0000-0000-000000000005", "jaguar-closeup.jpg", 802, 758, 0.48, 0.46),
    ]
    projects = [
        project(
            "B0000000-0000-0000-0000-000000000001",
            COLLECTION_ID,
            "Wild Encounters",
            wildlife,
            "featuredTop",
        ),
        project(
            "B0000000-0000-0000-0000-000000000002",
            COLLECTION_ID,
            "Birds in Motion",
            wildlife[:3],
            "featuredLeft",
        ),
        project(
            "B0000000-0000-0000-0000-000000000003",
            COLLECTION_ID,
            "Wildlife Portraits",
            wildlife[3:],
            "columns",
        ),
    ]
    return [
        {
            "id": COLLECTION_ID,
            "name": "Nature Stories",
            "createdAt": DEMO_DATE,
            "modifiedAt": DEMO_DATE,
            "projects": projects,
        },
        {
            "id": "D0000000-0000-0000-0000-000000000002",
            "name": "Bird Collection",
            "createdAt": DEMO_DATE,
            "modifiedAt": DEMO_DATE,
            "projects": [],
        },
        {
            "id": "D0000000-0000-0000-0000-000000000003",
            "name": "Big Cats",
            "createdAt": DEMO_DATE,
            "modifiedAt": DEMO_DATE,
            "projects": [],
        },
    ]


def seed_container(container: Path) -> None:
    destination = container / "Library" / "Application Support" / "MixaFrame"
    photos_destination = destination / "Photos"

    for generated_directory in (
        "Photos",
        "Previews",
        "Thumbnails",
        "ProjectThumbnails",
        "Exports",
    ):
        shutil.rmtree(destination / generated_directory, ignore_errors=True)
    photos_destination.mkdir(parents=True, exist_ok=True)

    for asset in sorted(PHOTO_DIRECTORY.glob("*.jpg")):
        shutil.copy2(asset, photos_destination / asset.name)

    destination.mkdir(parents=True, exist_ok=True)
    library_path = destination / "collections.json"
    library_path.write_text(json.dumps(demo_library(), indent=2, sort_keys=True) + "\n")
    print(f"Seeded {library_path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", required=True, type=Path, help="Simulator app data container")
    args = parser.parse_args()

    missing = sorted(
        name
        for name in (
            "jaguar-closeup.jpg",
            "ocelot.jpg",
            "perched-bird.jpg",
            "walking-bird.jpg",
            "winged-bird.jpg",
        )
        if not (PHOTO_DIRECTORY / name).exists()
    )
    if missing:
        raise FileNotFoundError(f"Missing demo photos: {', '.join(missing)}")
    seed_container(args.container)


if __name__ == "__main__":
    main()
