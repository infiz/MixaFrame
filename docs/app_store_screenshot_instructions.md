# App Store screenshot instructions

The finished MixaFrame product-page screenshots are in `AppStoreScreenshots/Promotional`.
They use the same benefit-led presentation as Shutter Trail, with authentic MixaFrame UI
captured from the iPhone simulator and the five wildlife demo photos supplied for this set.

## Generate the promotional set

From the repository root:

```bash
python3 scripts/generate_app_store_screenshots.py
```

The generator requires Pillow and uses:

- `AppStoreScreenshots/Raw` for native simulator captures;
- `AppStoreScreenshots/Assets/promo-background.png` for the shared background; and
- `AppStoreScreenshots/Promotional` for the final upload-ready images.

## Capture requirements

- Use light appearance unless the feature is intentionally shown in the dark photo editor.
- Override the status bar time to `9:41`.
- Capture the device display only, without Simulator chrome or a device frame.
- Keep the demo project and collage title as `Wild Encounters`.
- Use the supplied wildlife photo set so focus and crop behavior remains reproducible.

## Verify

Every finished screenshot must be `1284 × 2778`, RGB, and contain no alpha channel.

```bash
sips -g pixelWidth -g pixelHeight AppStoreScreenshots/Promotional/*.png
```
