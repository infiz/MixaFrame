# MixaFrame

MixaFrame is a native SwiftUI iPhone app for creating subject-aware photo collages. Projects and editable collage tasks are stored locally, while photo analysis is performed on-device with Vision.

## Run on an iPhone

1. Open `MixaFrame.xcodeproj` in Xcode 16 or newer.
2. Select the **MixaFrame** project, then the **MixaFrame** app target.
3. In **Signing & Capabilities**, select your Apple Developer team. If Xcode reports that the bundle identifier is unavailable, replace `com.infiz.MixaFrame` with a unique identifier.
4. Connect and unlock your iPhone, trust the Mac if prompted, and select the iPhone as the run destination.
5. Press **Run** (`⌘R`). On first use, allow access when saving a collage to Photos.

The deployment target is iOS 17.6. Xcode resolves the MIT-licensed `SDWebImageWebPCoder` Swift package (and its libwebp dependency) for WebP encoding; the app uses no network services at runtime.

## Implemented MVP

- Project creation, renaming, deletion, and local persistence.
- Editable collage tasks with up to 12 locally copied source photos.
- Project task lists render recognizable collage thumbnails from the cached low-resolution photo assets and saved composition settings.
- On-device Vision face and saliency detection for automatic subject focus.
- A background image pipeline generates 256 px list thumbnails and 1600 px editing previews while preserving untouched originals for full-resolution export.
- Reference-aware cleanup removes unused source copies, previews, thumbnails, cache entries, and stale exports after saved photo removal or replacement while retaining assets shared by another task.
- A photo-count-specific catalog covering 1–12 photos, presented through Grid, Featured, Mosaic, and Slanted groups.
- A unified Featured group combines edge-based Hero compositions with distinct three-row and three-column Editorial compositions, all driven by one 1–3 main-photo control.
- Live layout thumbnails, compact family filters, legacy-layout migration, and compatible layout preservation when photos are added or removed.
- A content-aware Smart Grid scores every viable row and column arrangement using photo aspect ratios, crop cost, empty cells, last-row balance, and canvas orientation.
- Automatic creation evaluates canvas shape and layout together, recommends the combination that retains the most source-photo area, and hides lower-fit layout choices for the current photos.
- Photo-count-specific Grid templates use justified, aspect-aware row heights and cell widths so mixed portrait and landscape photos retain substantially more of their original image area.
- Smart Grid fills incomplete rows, and supported layouts assign photos using crop loss, source resolution, and subject position. Users can still lock a manual order or restore best-fit arrangement.
- Full-width row grids, weighted bands, featured-photo arrangements, Mondrian slicing, masonry, brick, and multi-row, multi-column slanted mosaics.
- Square, portrait, landscape, and story canvas sizes with HD, QHD, 4K, 8K, and custom resolutions.
- White and dark collage backgrounds, reflected in both the live preview and exported image.
- A pinned live preview with a full-canvas mode that hides and restores controls.
- Existing collages open without an expanded settings panel, leaving the saved composition immediately visible while keeping the tool rail available.
- A canvas-first editor with a vertical tool rail and Photos, Layouts, Canvas, and Export panels that slide up into the lower half while the complete collage remains visible above; cropping and zooming happen directly on the collage.
- Full-screen task creation and editing with semantic dirty-state tracking; Back returns immediately when unchanged and offers Save, Discard, or Keep Editing only after edits.
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
