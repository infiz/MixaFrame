#!/usr/bin/env python3
"""Export approved creative artwork at Apple's placement-specific image sizes."""

from pathlib import Path
import hashlib
import json
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image, ImageCms, ImageDraw


ROOT = Path(__file__).resolve().parent.parent / "AppStoreAssets" / "Creative"
# Art-safe bounds come from Apple's downloadable Photoshop templates, Oct 7, 2026.
ASSETS = (
    ("header.png", "MixaFrame-Header-3840x1646.png", (3840, 1646), (1097, 493, 2743, 1154)),
    ("search-results.png", "MixaFrame-Search-Results-3840x2560.png", (3840, 2560), (836, 765, 3004, 1795)),
)


def main() -> None:
    previews = ROOT / "Previews"
    previews.mkdir(parents=True, exist_ok=True)
    profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    manifest = []
    for source_name, output_name, size, safe_area in ASSETS:
        with Image.open(ROOT / "Sources" / source_name) as source:
            source_size = source.size
            # The generation tool returns smaller rasters; resample to exact upload sizes.
            output = source.convert("RGB").resize(size, Image.Resampling.LANCZOS)
        output_path = ROOT / output_name
        output.save(output_path, icc_profile=profile, optimize=True)
        with Image.open(output_path) as saved:
            saved.verify()
        with Image.open(output_path) as saved:
            assert saved.size == size and saved.mode == "RGB"
            assert "transparency" not in saved.info
            assert saved.info.get("icc_profile") == profile
        # Diagnostic preview only: this green guide is never added to upload artwork.
        guide = output.copy()
        ImageDraw.Draw(guide).rectangle(safe_area, outline="#16A34A", width=8)
        guide.thumbnail((1440, 1000), Image.Resampling.LANCZOS)
        guide.save(previews / output_name.replace(".png", "-safe-area.jpg"), quality=92)
        crop = output.crop(safe_area)
        crop.thumbnail((1200, 600), Image.Resampling.LANCZOS)
        crop.save(previews / output_name.replace(".png", "-safe-crop.jpg"), quality=92)
        manifest.append({
            "file": output_name, "size": list(size), "mode": "RGB", "color_space": "sRGB",
            "alpha": False, "source_size": list(source_size), "resampled": source_size != size,
            "bytes": output_path.stat().st_size,
            "sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
            "art_safe_area": list(safe_area),
        })
    (ROOT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with ZipFile(ROOT / "MixaFrame-App-Store-Header-and-Search-Results.zip", "w", ZIP_DEFLATED) as archive:
        for asset in manifest:
            archive.write(ROOT / asset["file"], asset["file"])
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
