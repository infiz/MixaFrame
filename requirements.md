# MixaFrame Product Requirements

## 1. Product Overview

MixaFrame is an iOS photo collage app that lets users combine multiple photos into a single collage image. The app should automatically choose an appropriate output size and layout, let the user change those choices, preserve the important subjects in each source photo when cropping, and save every collage as an editable project inside a collection.

## 2. Product Goals

- Make creating a polished photo collage quick and simple.
- Reduce manual cropping by keeping the main subject or subjects visible in every frame.
- Allow users to return to, update, and recreate previous collages.
- Help users organize related collages into collections.
- Keep collage creation available without payment while offering watermark-free exports through an optional subscription.

## 3. Core Concepts

### Collection

A collection is the top-level organizational container. It has a name and contains zero or more projects.

### Project

A project stores everything needed to recreate or edit a collage, including its selected photos, their ordering, layout and crop information, output settings, and generated result.

### Collage Output

The collage output is a single image generated from a project. Updating a project may produce a new output image without losing the project itself.

## 4. Functional Requirements

### 4.1 Collection Management

- The user can create a collection.
- The user can give a collection a name.
- The user can view a list of collections.
- The user can open a collection and view its projects.
- A collection can contain multiple projects.
- The user can rename a collection.
- The user can delete a collection after confirming the action.
- Deleting a collection deletes all projects contained in it.

### 4.2 Photo Selection

- The user can create a project inside a collection.
- The user can select multiple photos from the iOS photo library for a project.
- The app must request photo-library access using the appropriate iOS permission flow.
- The user can review selected photos before generating the collage.
- The user can add, remove, or reorder selected photos while editing a project.
- The app must require at least two photos before generating a collage.
- A project supports up to 12 photos in the MVP.
- The app must handle unavailable, deleted, or inaccessible source photos gracefully and explain which photos need to be replaced.

### 4.3 Automatic Collage Generation

- The app automatically selects a suitable standard output image size and orientation based on the selected photos and their aspect ratios.
- The app automatically selects a layout that provides one frame for each selected photo.
- Automatic creation evaluates every supported canvas shape together with compatible layouts and recommends the combination with the strongest crop-retention score. The score prioritizes both the average visible source-photo area and the worst-fitting individual photo so one heavily cropped photo cannot be hidden by a good average.
- Smart Grid evaluates all viable row and column arrangements using the canvas orientation, source-photo aspect ratios, crop cost, unused grid capacity, and incomplete-last-row balance.
- Smart Grid favors complete, balanced rows when their crop cost is comparable; for example, twelve landscape 3:2 photos use three rows of four rather than rows of five, five, and two.
- When a Smart Grid has an incomplete final row, its frames expand to use the available row width rather than leaving unused canvas space.
- Supported layouts assign photos to frames using crop loss, source resolution, and detected-subject position instead of retaining selection order; for example, the best landscape photo is placed in a full-width final-row frame. Equal-fit placement uses stable photo identity rather than picker order.
- Dragging to swap photos or manually reordering the photo list locks that explicit order. The user can restore automatic placement with Arrange Photos by Best Fit.
- After the app selects a layout, the user can choose a different compatible layout.
- Every fixed-canvas layout containing two or more photos overlays draggable divider handles in the Layout tool, including grids, Hero, Editorial, Mondrian, masonry, brick, and slanted layouts. Dragging a divider resizes its neighboring photo regions while preserving the template's overall geometry. Cells enforce a minimum size, customized divider positions persist with the project and are used consistently in previews, thumbnails, and exports, and the user can reset all dividers to the template defaults. Natural-size Flow layouts omit divider adjustment so every photo remains uncropped.
- The app provides a curated, photo-count-specific layout catalog across photo counts 1 through 12.
- The layout browser is organized into Grid, Featured, Mosaic, Slanted, and Flow groups. Featured combines Hero and Editorial compositions into one group and omits duplicate two-band Editorial layouts that match Hero edge structures. Fixed-canvas strips, creative card-stack, and circular-mask layouts are excluded.
- Grid templates use intentional row compositions for each supported photo count. Every row expands its frames across the full canvas width without empty placeholder cells. Examples include 3–2–3 and 2–3–3 for eight photos, and 4–4–3 and 4–3–4 for eleven photos. Generic one-column and incomplete-grid-fill templates are not offered. Grid row heights and individual cell widths adapt to the selected photos' aspect ratios to retain as much source-photo area as possible while still filling the canvas.
- Available templates include full-width row grids; featured-photo layouts on every edge; Corner Anchor, Dual Anchor, and Center Window Featured compositions; weighted editorial bands; recursive Mondrian mosaics; masonry columns; brick layouts; Aspect-Aware Slice, Pinwheel, Golden Spiral, and T-Junction Quilt mosaics; and multi-row, multi-column slanted mosaics.
- Flow provides Horizontal Flow and Vertical Flow. Horizontal Flow gives every photo the selected resolution as its full height and derives the total width from the photos' natural aspect ratios; Vertical Flow gives every photo the selected resolution as its full width and derives the total height. Both preserve photo order and avoid cropping, and the editor previews them in a scrollable canvas. The Horizontal Flow viewport uses 50 percent of the editor's available screen height in both edit and non-edit modes. A normal one-finger swipe scrolls the Flow canvas in edit and non-edit modes, including when the first or last visible photo is selected. Tapping a photo once selects it for pinch zoom and two-finger repositioning; touching and holding before dragging starts a swap and automatically scrolls toward photos beyond the currently visible area. Starting a swap selects the dragged photo, clears the prior selection, and keeps the dragged photo selected after it moves.
- Featured directly presents every distinct composition with one, two, or three main photos plus the remaining photos in smaller secondary regions whenever the selected photo count leaves at least one secondary photo. There is no separate main-photo-count control; each layout thumbnail and title communicates its emphasis count. Visually identical frame geometry is shown only once even when multiple internal templates could produce it. Main-photo frames remain visibly larger on average than secondary frames, and automatic best-fit placement assigns suitable photos to both regions.
- The Layout tool provides Custom Cuts outside the built-in family filters. The user builds an exact-fill rectangular layout by repeatedly selecting a region and splitting it side-by-side or top-to-bottom until there is exactly one region for every selected photo. Custom Cuts must never overlap or leave unused canvas space.
- The user can apply a Custom Cuts layout once or save it to My Layouts for later reuse. A saved custom layout has a user-editable name and fixed compatible photo count, and the user can apply, rename, update, duplicate, or delete it without changing collages that already use its geometry.
- Custom layout geometry, including later divider adjustments, is persisted with the project. The reusable My Layouts library is also persisted locally and remains available after the app relaunches.
- The Slanted family provides nine gentle, bold, rising, falling, zigzag, rhythmic, and featured-row mosaic variants for every selection from 2 through 12 photos; a clean poster-matte option represents the family for one photo. Slanted layouts distribute photos across multiple rows and columns with angled horizontal and vertical boundaries instead of presenting all photos in one row or one column whenever the photo count allows both dimensions.
- Each photo count presents only compatible templates that contain exactly one frame for every selected photo.
- Rotations, mirrors, proportions, and other variants count as separate templates only when they produce a meaningfully different composition; photo-order permutations do not count as separate layouts.
- After the app selects an image size, the user can choose a different standard image dimension.
- Standard image dimensions must clearly show their pixel dimensions and aspect ratios.
- The generated collage contains all selected photos exactly once unless the user removes a photo.
- Fixed-canvas layouts crop and scale each photo to fill its assigned frame without stretching or distorting it. Flow layouts scale each photo proportionally to its shared height or width without cropping.
- The app must show the proposed collage as a preview before the user saves or exports it.
- The editor preview uses square outer canvas edges and no decorative canvas shadow so the collage boundary matches the exported image.
- The preview updates when the user changes the layout, image dimensions, or output resolution.
- The user can choose either a white or dark collage background, and the preview and exported image update to match.
- In Layout settings, the user can adjust the outer collage canvas corners from square (0%) through fully rounded (50%). This setting does not round individual photo frames.
- Rounded canvas corners are transparent in PNG and WebP exports. JPEG and HEIF exports flatten the area outside the rounded canvas onto white for broad compatibility.
- The layout browser shows live miniature previews and compact family filters without displacing the primary collage preview.
- The layout browser scores templates for the current photos and ranks stronger crop-retention options first. Featured always shows every distinct one-, two-, and three-main composition so the user can choose emphasis directly; other families hide templates that crop materially more image area than the best options. A filtered layout normally qualifies only when it retains at least 68% of source-photo area on average and at least 42% for every individual photo; when a canvas/photo combination makes those levels geometrically impossible, only layouts within 10 percentage points of the best achievable fit are offered.
- When photos are added or removed, the app preserves the corresponding layout variant for the new photo count when one exists and otherwise selects a compatible fallback.
- When a layout or image dimension changes, the app recalculates subject-aware crops while retaining manual crop adjustments where they remain valid.
- Regenerating an unchanged project should produce a visually equivalent collage.

### 4.4 Subject-Aware Cropping

- For every selected photo, the app attempts to identify the main subject or subjects.
- When fitting a photo into a collage frame, the crop should keep the detected main subject or subjects visible whenever the source image and frame geometry allow it.
- The app must not distort the photo to preserve a subject.
- If no subject can be detected confidently, the app uses a sensible fallback crop, such as a centered crop.
- The user can manually reposition or adjust a photo's crop when the automatic result is unsatisfactory.
- The user can drag a photo within its frame to reposition the crop.
- A coordinated photo gesture prevents crop and swap interactions from competing: hold briefly and drag to reposition the crop, or keep holding for roughly half a second before dragging to enter swap mode. Swap mode highlights the destination frame and confirms activation with stronger haptic feedback.
- The user can pinch a photo with two fingers to zoom in or out between the fitted crop and the supported maximum zoom.
- Manual crop adjustments are saved as part of the project.
- The selected zoom level is saved as part of the project.

### 4.5 Project Persistence and Editing

- Each project is saved within its parent collection.
- A saved project includes, at minimum:
  - A unique identifier.
  - Its parent collection identifier.
  - Creation and last-modified dates.
  - References to the selected source photos.
  - Photo ordering.
  - Layout and output dimensions.
  - A stable catalog layout identifier, with migration support for projects saved using legacy layout values.
  - A self-contained snapshot of the resolved layout geometry, including normalized frame rectangles, clip polygons, rotation, corner treatment, aspect-fit behavior, photo-to-frame assignment, and output aspect ratio. Reopening, rendering, or exporting a saved collage must use this snapshot and must not change if its original catalog template is later modified, renamed, or removed.
  - Selected output resolution.
  - Selected output image format and format-specific settings.
  - Selected output-quality preset.
  - Automatic and user-adjusted crop information.
  - A reference to the latest generated collage output, when available.
- The user can view a collection's saved projects.
- Saving a project generates or refreshes a lightweight thumbnail of the actual collage using its layout, photo crops, spacing, canvas corners, and background. The thumbnail is persisted with the project assets and loaded directly after relaunch; older projects missing one are regenerated when their collection list is opened.
- The user can reopen a project and recreate its collage.
- The user can edit a project by changing its photos, ordering, layout, or crops.
- When renaming an "Untitled Project," the title field starts empty and focused so the user can type the replacement name immediately.
- Changes to a project persist after the app closes and relaunches.
- The user can delete a project after confirming the action.
- Deleting a project must not delete its original photos from the user's photo library.

### 4.6 Saving and Sharing

- The user can save the generated collage as a single image to the iOS photo library.
- The user can choose the output resolution before generating or exporting the collage.
- The default output resolution is 4K, and the user can increase the longest output dimension to 8K (8192 pixels).
- Available resolution choices are HD (1920 px), QHD (2560 px), 4K (4096 px), 8K (8192 px), and a custom value from 512 through 8192 pixels.
- Resolution choices must display the resulting pixel dimensions before export.
- Changing the output resolution must preserve the selected layout and composition.
- The user can choose the output image format before exporting the collage.
- Supported output formats include JPEG, PNG, WebP, and Apple HEIF (HEIC files). Additional formats may be added later.
- JPEG is the default output format.
- The format selector must describe important differences that affect the output, such as file size, image quality, and transparency support.
- The user can select one of three output-quality presets:
  - **Space Saver:** Lower visual quality and the smallest expected file size. Intended for quick sharing or storage-sensitive use.
  - **Balanced:** Medium-to-high visual quality and a moderate expected file size. This is the default preset.
  - **Best Quality:** Highest available visual quality and the largest expected file size. Intended for archiving, printing, or further editing.
- The quality selector must show the quality/file-size relationship for every preset before export.
- The app maps each preset to appropriate format-specific encoding settings so that users do not need to understand compression values.
- For lossless formats such as PNG, the app must explain that image fidelity remains unchanged and that the preset affects only available lossless compression behavior; unavailable quality choices must not imply a reduction in visual quality.
- When practical, the export preview shows an estimated file size for the selected format, resolution, and quality preset.
- If the collage contains transparency and the user selects a format that does not support it, the app must warn the user and apply a user-visible background color before export.
- Changing the output format or quality preset must not alter the saved layout, crops, dimensions, or resolution.
- If an export destination does not support the selected format, the app must explain the limitation and offer a compatible destination or format.
- Saving a collage must not overwrite or modify the original photos.
- Choosing Save or Save and Go Back displays a blocking save-progress bar until the project data and persisted collage thumbnail have finished saving, preventing duplicate save actions.
- The user receives clear confirmation when a collage is saved successfully.
- If saving fails, the app shows an actionable error message.
- The user can share or export the generated collage using the standard iOS share sheet.
- Export first opens a full-screen review of the rendered image where the user can pinch or use controls to zoom, drag to inspect different areas, and reset the view before choosing Save to Photos or Share.
- Leaving the export review without saving or sharing discards its temporary file and does not replace the project's previous export.

### 4.7 Subscription and Free Use

- The app remains fully usable for creating, editing, saving, and reopening projects without starting a trial or purchasing a subscription.
- Free users can preview, save, and share exported collages, but every exported image includes a compact bottom-right MixaFrame brand badge using a polished display font that remains readable at every supported resolution and creates a clear incentive to upgrade for a clean export.
- The app offers one auto-renewable annual MixaFrame Premium subscription that removes the watermark from saved and shared collage exports.
- Eligible new subscribers receive a seven-day free trial before the annual subscription charge begins.
- Trial and paid-subscription entitlements both produce watermark-free exports.
- The paywall displays localized App Store pricing, trial eligibility, annual renewal terms, a Restore Purchases action, a Continue Free action, privacy information, and terms of use.
- The app listens for StoreKit transaction updates and refreshes subscription status after purchases, restorations, renewals, expirations, revocations, and upgrades.
- Purchases must be verified by StoreKit before watermark-free access is granted.
- Project thumbnails and the interactive editor preview do not include the subscription watermark; the watermark is applied only to generated export files and their export review previews.

## 5. User Experience Requirements

- The main navigation presents collections as the top-level view.
- Opening a collection presents its projects and an action to create a new project.
- Creating or editing a project uses a full-screen editor rather than a partial-height sheet.
- The full-screen editor provides a Back control that returns to the containing collection.
- Opening an existing collage starts with the settings panel collapsed so no editor dialog obscures the collage; the user can expand a tool from the vertical tool rail.
- Using Back compares the current user-editable collage state with the last saved state. It returns immediately when they match. When real changes exist, an icon-labeled dialog offers Save and Export, Save and Leave, or Discard Changes; free users also receive a fully clickable Subscribe to remove the watermark row that opens the subscription screen. Saving is unavailable until the project meets the minimum photo requirement.
- Discarding a new or changed project removes newly imported photo copies that are not referenced by another saved project.
- The collage creation flow guides the user through photo selection, preview, adjustment, and saving.
- The collage editor is canvas-first: the preview uses the full available workspace when settings are collapsed, and editing tools appear as a compact vertical icon rail over the canvas edge.
- Selecting a tool icon slides that tool's scrollable settings panel up from the bottom. The panel uses approximately the lower half of the editor while the complete collage preview resizes into the upper half and remains visible.
- Selecting the active tool again or using the panel close button slides the panel down and returns the preview to the larger canvas.
- The vertical rail provides Photos, Layouts, Canvas, and Export tools. Crop positioning and zoom are direct gestures on photos in the collage canvas rather than a separate toolbox panel.
- In the Photos panel, each newly analyzed thumbnail overlays the detected face or salient-object focus region with a translucent red rectangle so the user can verify what automatic cropping will preserve.
- The user can hide both the expanded panel and icon rail to view and directly adjust the collage using the full available canvas, then restore the tools with a floating control.
- The user can touch and hold a photo, then drag it onto another collage frame to swap their positions.
- Long-running image analysis or rendering displays progress and remains cancellable where practical.
- Destructive actions require confirmation.
- The app supports standard iOS accessibility features, including VoiceOver labels, Dynamic Type where applicable, and sufficient color contrast.
- The interface clearly distinguishes between saving changes to a project and exporting its generated image.

## 6. Data and Privacy Requirements

- The app requests only the photo access needed for selection and export.
- The app explains why photo access is needed before or as part of the system permission request.
- Original photos must never be altered or deleted by the app.
- Collection and project data is stored locally for the MVP.
- Photo analysis and subject detection should run on-device for the MVP unless a future requirement explicitly introduces a cloud service and its privacy disclosures.
- The app must remain usable when the device is offline, except for features explicitly added later that require a network connection.

## 7. Performance and Reliability Requirements

- Common user actions should respond promptly and must not block the main interface.
- Image decoding, subject detection, cropping, and rendering must run without freezing the UI.
- Photo import generates a 256-pixel list thumbnail and a 1600-pixel editing preview off the main thread; the editor must not synchronously decode full-resolution originals.
- Every generated photo thumbnail and editing preview is persisted and loaded from disk on memory-cache misses, so reopening a collage reuses derived images without decoding the originals again.
- Editing previews and thumbnails are memory-cached with bounded memory use, while original images are loaded only for final export or explicit full-screen inspection.
- When the app returns to the foreground, the current collection and collage views reload any previews or collage thumbnails evicted from memory directly from their persisted files without requiring the user to leave and reopen the screen.
- When a Flow collage's requested dimensions exceed the renderer's safe side or total-pixel limits, export preserves the complete strip and automatically scales it uniformly to the largest safe bitmap. The export preview identifies the requested and actual dimensions instead of failing or requiring photos to be removed.
- From the collage editor, the user can double-tap a collage frame or use an explicit View Original Photo action to open that source photo full-screen.
- The original-photo viewer loads the locally preserved original-resolution file off the main thread and supports pinch zoom, pan, double-tap zoom/reset, explicit zoom controls, and close.
- In the Photos panel, tapping the thumbnail, the central photo details area, or the expand button opens the original photo viewer.
- While dragging a photo to swap positions, a floating preview of the dragged photo follows the user's finger and displays a switch icon at its top-right. The destination frame is highlighted and also displays a switch icon. The drag-and-drop operation uses move semantics rather than showing the system copy “+” indicator.
- Existing projects generate missing derived images lazily without changing their saved crops or requiring manual migration.
- Saving an existing project after removing or replacing a photo removes that photo's unreferenced local original copy, editing preview, list thumbnail, memory-cache entries, stored focus metadata, and stale rendered export. Assets still referenced by another saved project are retained, and startup maintenance prunes orphaned generated files left by interruptions.
- The app should manage memory carefully when processing multiple high-resolution photos.
- The app should preserve saved collection and project data across normal app upgrades.
- If collage generation is interrupted or fails, the saved project should remain recoverable and editable.

## 8. MVP Acceptance Criteria

The MVP is complete when a user can:

1. Create and name a collection.
2. Create a project within that collection.
3. Select at least two photos from the iOS photo library.
4. Preview one automatically sized collage containing every selected photo.
5. See automatic crops that attempt to keep each photo's main subject visible.
6. Manually correct an unsatisfactory crop.
7. Replace the automatically selected layout with another available layout.
8. Change the collage to another standard image dimension.
9. Select an output resolution, with 4K used by default and 8K (8192 pixels) available as the maximum.
10. Choose JPEG, PNG, WebP, or Apple HEIF as the output format.
11. Choose Space Saver, Balanced, or Best Quality and understand the corresponding quality/file-size tradeoff.
12. Save the project, close the app, and later reopen the project with its photos, ordering, layout, dimensions, resolution, output format, output quality, and crop adjustments intact.
13. Update and regenerate the saved collage.
14. Save the generated collage to the photo library or share it.
15. Delete an individual project without affecting the original photos.
16. Store and manage multiple projects within one collection.
17. Hide and restore editor controls while keeping the collage visible.
18. Reposition and zoom an individual photo directly on the collage canvas.
19. Swap two photos using drag and drop on the collage canvas.
20. Browse compatible layouts by family for any selection from 1 through 12 photos.
21. Render and export rectangular and multi-row, multi-column slanted-mosaic layouts consistently with their on-screen previews.
22. Choose a white or dark collage background and preserve that choice when the project is saved and reopened.
23. Review the rendered export full-screen, zoom and pan to inspect it, and then choose Save to Photos, Share, or Back without saving.
24. Continue using every collage-editing feature without starting a trial or subscription and receive a clearly watermarked export.
25. Start an eligible seven-day trial or annual subscription, restore an existing purchase, and export without a watermark while the entitlement is active.
26. Create an exact-fill Custom Cuts layout for the selected photo count and resize all of its dividers in the collage editor.
27. Save a Custom Cuts layout to My Layouts, reopen the app, reuse it in another compatible collage, and rename, update, duplicate, or delete the saved layout.

## 9. Assumptions

- The first release targets iPhone running iOS 17 or later; iPad-specific layouts can be defined later.
- Each photo appears in one frame in the automatically generated collage.
- Automatic sizing selects from a defined set of common aspect ratios and image dimensions rather than creating an arbitrary standard canvas size.
- A project belongs to exactly one collection.
- Local persistence is sufficient for the MVP; account login and cross-device synchronization are out of scope.

## 10. Open Questions

- Should additional canvas aspect ratios be supported beyond square (1:1), portrait (4:5), landscape (3:2), and story (9:16)?
- Which additional output formats, beyond JPEG, PNG, WebP, and Apple HEIF, should the MVP support?
- What format-specific encoding values should Space Saver, Balanced, and Best Quality use for JPEG and WebP?
- Should borders, rounded corners, text, stickers, or filters be included in the MVP?
- If an original photo is removed from the photo library, should the app retain its own copy or ask the user to replace it?
- Should deleting a collection also delete collage images that were previously exported to the photo library? The recommended behavior is no.
- Is project version history required, or is saving only the latest state sufficient?
- Should collections or projects support additional sorting or search options?
- Will iCloud synchronization or collaboration be required in a later release?

## 11. Out of Scope for the Initial MVP

- User accounts and authentication.
- Cloud backup or cross-device synchronization.
- Collaborative editing or collection sharing.
- Video collages or animated output.
- Cloud-based photo analysis.
- Advanced graphic-design tools unless added through a later requirements update.
