# App icon

File: `AppIcon.png`.
Created with the built-in imagegen tool. `AppIcon.icns` was packaged with the native
macOS icon tool. The app loads the PNG for its Dock icon. The build includes both files.

To rebuild the ICNS asset after an icon edit:

```sh
source scripts/swift-env.sh
swift -sdk "$R2DESK_SDK_PATH" scripts/make-icon.swift dist/AppIcon.iconset
iconutil --convert icns dist/AppIcon.iconset --output Assets/AppIcon.icns
```

The prompt used:

> Use case: logo-brand. Create a finished macOS app icon for R2 Desk, a simple Cloudflare R2 file browser. Asset: one square 1024 x 1024 PNG icon. A warm orange rounded square tile contains one bold, clean ivory folder with a small orange cloud inset on the folder front. Refined soft 3D relief, subtle depth and restrained highlights, precise smooth curves, excellent readability at 32 pixels. Orange palette matches the app. The tile is centered, fills about 88% of the canvas, with standard macOS squircle corners and a subtle shadow. The canvas outside the tile must be genuinely transparent. Keep the folder large with a clear tab and the cloud simple. No letters, no numbers, no text, no watermark, no extra symbols. This is the actual icon asset, not a screenshot, device mockup, or presentation.

Output: 1254 × 1254 PNG with transparency.
