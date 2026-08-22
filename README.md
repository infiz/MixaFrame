# MixaFrame

MixaFrame is a native SwiftUI photo collage editor for iPhone, iPad, and Mac. Collections contain editable Projects, and everything is stored locally while photo analysis is performed on-device with Vision.

## Run on iPhone or iPad

1. Open `MixaFrame.xcodeproj` in Xcode 16 or newer.
2. Select the **MixaFrame** project, then the **MixaFrame** app target.
3. In **Signing & Capabilities**, select your Apple Developer team. If Xcode reports that the bundle identifier is unavailable, replace `com.infiz.MixaFrame` with a unique identifier.
4. Select an iPhone or iPad simulator, or connect and unlock a device and select it as the run destination.
5. Press **Run** (`⌘R`). On first use, allow access when saving a project to Photos.

The deployment target is iOS 17.6. The iPad interface uses adaptive collection and project grids, a larger canvas, and full-height editing controls in portrait, landscape, Split View, and Stage Manager sizes. Xcode resolves the MIT-licensed `SDWebImageWebPCoder` Swift package (and its libwebp dependency) for WebP encoding; the app uses no network services at runtime.

## Run on Mac

1. Open `MixaFrame.xcodeproj`.
2. Select the **MixaFrame** scheme.
3. Choose **My Mac (Designed for iPad)** as the destination.
4. Press **Run** (`⌘R`).

This runs the adaptive iPad interface on Apple silicon while keeping the same Collection and Project experience as iPad. The separate **MixaFrameMac** scheme remains available for testing the native AppKit desktop implementation.

The native Mac app uses adaptive collection and project cards plus a desktop editor with a full-width live canvas and a responsive bottom photo-and-controls workspace. Import source images from Finder and export JPEG, PNG, HEIF, or WebP files with the standard macOS save panel. The Mac deployment target is macOS 14.

## Platform structure

MixaFrame follows the same shared-core arrangement as MementoReel. `ProjectModels`, `AppStore`, `StoragePaths`, `LibraryPersistence`, `PhotoImagePipeline`, `LayoutCatalog`, `LayoutEngine`, and `SubjectDetector` are compiled into both app targets. The `MixaFrame` target supplies the iPhone/iPad entry point and touch-oriented views; `MixaFrameMac` contains only the native Mac entry point, desktop views, Finder import adapter, and AppKit renderer. Both targets therefore use the same Collection/Project model, database format, storage paths, image preparation, and editing rules.

## Implemented MVP

- Collection creation, renaming, deletion, and local persistence.
- Editable projects with up to 12 locally copied source photos.
- Collection project lists render recognizable composition thumbnails from cached low-resolution photo assets and saved settings.
- On-device Vision face and saliency detection for automatic subject focus.
- A background image pipeline generates 256 px list thumbnails and 1600 px editing previews while preserving untouched originals for full-resolution export.
- Reference-aware cleanup removes unused source copies, previews, thumbnails, cache entries, and stale exports after saved photo removal or replacement while retaining assets shared by another project.
- A photo-count-specific catalog covering 1–12 photos, presented through Grid, Featured, Mosaic, and Slanted groups.
- A unified Featured group combines edge-based Hero compositions with distinct three-row and three-column Editorial compositions, all driven by one 1–3 main-photo control.
- Live layout thumbnails, compact family filters, legacy-layout migration, and compatible layout preservation when photos are added or removed.
- Horizontal Flow and Vertical Flow append uncropped photos at a shared output height or width, letting the other canvas dimension grow naturally with the photos.
- A content-aware Smart Grid scores every viable row and column arrangement using photo aspect ratios, crop cost, empty cells, last-row balance, and canvas orientation.
- Automatic creation evaluates canvas shape and layout together, recommends the combination that retains the most source-photo area, and hides lower-fit layout choices for the current photos.
- Photo-count-specific Grid templates use justified, aspect-aware row heights and cell widths so mixed portrait and landscape photos retain substantially more of their original image area.
- Smart Grid fills incomplete rows, and supported layouts assign photos using crop loss, source resolution, and subject position. Users can still lock a manual order or restore best-fit arrangement.
- Full-width row grids, weighted bands, featured-photo arrangements, Mondrian slicing, masonry, brick, and multi-row, multi-column slanted mosaics.
- Square, portrait, landscape, and story canvas sizes with HD, QHD, 4K, 8K, and custom resolutions.
- White and dark project backgrounds, reflected in both the live preview and exported image.
- A pinned live preview with a full-canvas mode that hides and restores controls.
- Existing projects open without an expanded settings panel, leaving the saved composition immediately visible while keeping the tool rail available.
- A canvas-first editor with a vertical tool rail and Photos, Layouts, Canvas, and Export panels that slide up into the lower half while the complete project remains visible above; cropping and zooming happen directly on the project.
- Full-screen project creation and editing with semantic dirty-state tracking; Back returns immediately when unchanged and offers Save and Export, Save and Leave, or Discard Changes only after edits.
- Direct manipulation: briefly hold and drag to reposition crops, pinch to zoom, or keep holding before dragging to swap photos with an animated destination highlight and switch indicator.
- Draggable dividers for every multi-photo layout, with persistent custom geometry and one-tap reset to template sizing.
- Add Photos thumbnails show the on-device detected face or salient-object region with a translucent red focus box.
- Manual focal-point adjustment, photo reordering, and spacing controls.
- JPEG, PNG, WebP, and Apple HEIF export with Space Saver, Balanced, and Best Quality presets.
- Save to Photos and standard iOS sharing/Save to Files.
- A full-screen export review with pinch zoom, pan, explicit zoom controls, and reset before Save to Photos or sharing.
- Full-screen inspection of any original-resolution source photo from the editor via double-tap or an explicit action, with pinch zoom, pan, zoom controls, and reset.

## Verification

Run the test suite from Xcode with `⌘U`, or from Terminal:

```sh
xcodebuild \
  -project MixaFrame.xcodeproj \
  -scheme MixaFrame \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Build the native Mac app from Terminal:

```sh
scripts/build_mac_app.sh
```
