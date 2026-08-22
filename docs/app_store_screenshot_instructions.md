# App Store screenshot instructions

The finished MixaFrame product-page screenshots are grouped by device family:

- `AppStoreScreenshots/iPhone/Promotional` contains upload-ready 6.5-inch artwork.
- `AppStoreScreenshots/iPad/Promotional` contains upload-ready 13-inch iPad artwork.

Both sets use authentic MixaFrame UI captured from the simulator and the same five-photo
Nature Stories demo library.

## Generate the promotional set

From the repository root:

```bash
python3 scripts/generate_iphone_app_store_screenshots.py
python3 scripts/generate_ipad_app_store_screenshots.py
```

The generator requires Pillow and uses:

- `AppStoreScreenshots/iPhone/Raw` and `AppStoreScreenshots/iPad/Raw` for native simulator captures;
- `AppStoreScreenshots/Assets/promo-background.png` for the shared background; and
- each device's `Promotional` folder for the final upload-ready images.

Seed an installed simulator app before capture:

```bash
python3 scripts/prepare_app_store_demo.py --container "$(xcrun simctl get_app_container booted com.infiz.MixaFrame data)"
```

## Capture requirements

- Use light appearance unless the feature is intentionally shown in the dark photo editor.
- Override the status bar time to `9:41`.
- Capture the device display only, without Simulator chrome or a device frame.
- Keep the demo collection as `Nature Stories` and the featured project as `Wild Encounters`.
- Use the supplied wildlife photo set so focus and crop behavior remains reproducible.

## Verify

Every finished iPhone screenshot must be `1284 × 2778`. Every finished iPad screenshot
must be `2064 × 2752`. All promotional screenshots must be RGB with no alpha channel.

```bash
sips -g pixelWidth -g pixelHeight AppStoreScreenshots/iPhone/Promotional/*.png
sips -g pixelWidth -g pixelHeight AppStoreScreenshots/iPad/Promotional/*.png
```
