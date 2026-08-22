# App Store screenshots

```text
AppStoreScreenshots/
├── Assets/                 Shared demo photos and promotional background
├── iPhone/
│   ├── Raw/                Native iPhone simulator captures
│   └── Promotional/        Upload-ready 1284 × 2778 screenshots
└── iPad/
    ├── Raw/                Native 13-inch iPad simulator captures
    └── Promotional/        Upload-ready 2064 × 2752 screenshots
```

Generate the upload-ready sets from the repository root:

```bash
python3 scripts/generate_iphone_app_store_screenshots.py
python3 scripts/generate_ipad_app_store_screenshots.py
```

Use `scripts/prepare_app_store_demo.py --container <path>` to seed the same Nature
Stories collection and wildlife projects into each simulator before capturing the raw
screenshots.
