# MixaFrame — Header and Search Results

Prepared October 7, 2026. These are dedicated creative assets for the iOS/iPadOS
App Store Header and Search Results placements, separate from product screenshots.

## Upload files

| Placement | File | Dimensions |
| --- | --- | --- |
| Header | `MixaFrame-Header-3840x1646.png` | 3840 × 1646 |
| Search Results | `MixaFrame-Search-Results-3840x2560.png` | 3840 × 2560 |

Both files are opaque RGB PNGs with an embedded sRGB profile. The ZIP contains
only these two upload files. `manifest.json` records dimensions, source dimensions,
file sizes, hashes, and validation results.

## Design and verification

The matching wildlife collages use MixaFrame's existing warm ivory and lavender
visual identity and reference its existing jaguar, toucan, and macaw demo photos.
They were created with the built-in image generation tool and refined for cropping.
They are promotional artwork, rather than captures of the app's interface.
No copy, logos, device frames, prices, awards, or download buttons are included.

The generated source rasters are preserved under `Sources/`. They were resampled
with Lanczos to Apple's exact upload dimensions; they were not generated natively
at the final pixel dimensions. The complete prompt set is in `Sources/prompts.json`.

Apple's October 7, 2026 Photoshop templates specify these central art-safe bounds:

- Header: x 1097–2743, y 493–1154 (1646 × 661).
- Search Results: x 836–3004, y 765–1795 (2168 × 1030).

The jaguar face, toucan beak, and macaws were visually checked in those crops.
Decorative photo edges, borders, and foliage can crop. `Previews/` includes guide
overlays and safe-area crops for inspection; do not upload those diagnostic JPEGs.
These previews represent art-safe bounds, not full App Store Connect device previews.

## App Store Connect

1. Open MixaFrame → the iOS version → Product Page Information → Header and Search Results.
2. Upload the Header PNG in Header, and the Search Results PNG in Search Results.
3. Use Preview to check iPhone and iPad orientations before submitting for review.
4. Submit the assets with the version, or use Asset Library for a standalone asset submission.

The dedicated files use different aspect ratios; the universal-asset option to
reuse a header in search results does not apply to this pair. Upload and review
submission have not been performed.

## Re-export

From the repository root, with Pillow installed:

```sh
python3 scripts/export_app_store_creative_assets.py
```

This regenerates the final PNGs, diagnostic previews, manifest, and ZIP from the
saved approved sources, verifying dimensions, RGB mode, sRGB profile, and absence
of alpha/transparency.

## Apple references

- [Creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)
- [Asset best practices and templates](https://developer.apple.com/app-store/asset-best-practices/)
- [Manage App Store assets and submission](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets)
- [Header Photoshop template](https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-product_page_header_template-static.psd)
- [Search Results Photoshop template](https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-search_results_template-static.psd)
