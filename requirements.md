# MixaFrame Product Requirements

## 1. Product Overview

MixaFrame is an iOS photo collage app that lets users combine multiple photos into a single collage image. The app should automatically choose an appropriate output size and layout, let the user change those choices, preserve the important subjects in each source photo when cropping, and save every collage as an editable task inside a project.

## 2. Product Goals

- Make creating a polished photo collage quick and simple.
- Reduce manual cropping by keeping the main subject or subjects visible in every frame.
- Allow users to return to, update, and recreate previous collages.
- Help users organize related collages into projects.

## 3. Core Concepts

### Project

A project is the top-level organizational container. It has a name and contains zero or more collage tasks.

### Collage Task

A collage task stores everything needed to recreate or edit a collage, including its selected photos, their ordering, layout and crop information, output settings, and generated result.

### Collage Output

The collage output is a single image generated from a collage task. Updating a task may produce a new output image without losing the task itself.

## 4. Functional Requirements

### 4.1 Project Management

- The user can create a project.
- The user can give a project a name.
- The user can view a list of projects.
- The user can open a project and view its collage tasks.
- A project can contain multiple collage tasks.
- The user can rename a project.
- The user can delete a project after confirming the action.
- Deleting a project deletes all collage tasks contained in it.

### 4.2 Photo Selection

- The user can create a collage task inside a project.
- The user can select multiple photos from the iOS photo library for a collage task.
- The app must request photo-library access using the appropriate iOS permission flow.
- The user can review selected photos before generating the collage.
- The user can add, remove, or reorder selected photos while editing a task.
- The app must require at least two photos before generating a collage.
- A collage task supports up to 12 photos in the MVP.
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
- Every layout containing two or more photos overlays draggable divider handles in the Layout tool, including grids, Hero, Editorial, Mondrian, masonry, brick, and slanted layouts. Dragging a divider resizes its neighboring photo regions while preserving the template's overall geometry. Cells enforce a minimum size, customized divider positions persist with the task and are used consistently in previews, thumbnails, and exports, and the user can reset all dividers to the template defaults.
- The app provides a curated, photo-count-specific layout catalog across photo counts 1 through 12.
- The layout browser is organized into Grid, Featured, Mosaic, and Slanted groups. Featured combines Hero and Editorial compositions into one group and omits duplicate two-band Editorial layouts that match Hero edge structures. Strip, creative card-stack, and circular-mask layouts are excluded.
- Grid templates use intentional row compositions for each supported photo count. Every row expands its frames across the full canvas width without empty placeholder cells. Examples include 3–2–3 and 2–3–3 for eight photos, and 4–4–3 and 4–3–4 for eleven photos. Generic one-column and incomplete-grid-fill templates are not offered. Grid row heights and individual cell widths adapt to the selected photos' aspect ratios to retain as much source-photo area as possible while still filling the canvas.
- Available templates include full-width row grids, featured-photo layouts on every edge, weighted editorial bands, recursive Mondrian mosaics, masonry columns, brick layouts, and multi-row, multi-column slanted mosaics.
- Every Featured template lets the user choose one, two, or three main photos plus the remaining photos in smaller secondary regions whenever the selected photo count leaves at least one secondary photo. Changing this value updates every Featured sample while preserving each template's edge, orientation, and visual style. Main-photo frames remain visibly larger on average than secondary frames, and automatic best-fit placement assigns suitable photos to both regions.
- The Slanted family provides nine gentle, bold, rising, falling, zigzag, rhythmic, and featured-row mosaic variants for every selection from 2 through 12 photos; a clean poster-matte option represents the family for one photo. Slanted layouts distribute photos across multiple rows and columns with angled horizontal and vertical boundaries instead of presenting all photos in one row or one column whenever the photo count allows both dimensions.
- Each photo count presents only compatible templates that contain exactly one frame for every selected photo.
- Rotations, mirrors, proportions, and other variants count as separate templates only when they produce a meaningfully different composition; photo-order permutations do not count as separate layouts.
- After the app selects an image size, the user can choose a different standard image dimension.
- Standard image dimensions must clearly show their pixel dimensions and aspect ratios.
- The generated collage contains all selected photos exactly once unless the user removes a photo.
- The app crops and scales each photo to fill its assigned frame without stretching or distorting it.
- The app must show the proposed collage as a preview before the user saves or exports it.
- The editor preview uses square outer canvas edges and no decorative canvas shadow so the collage boundary matches the exported image.
- The preview updates when the user changes the layout, image dimensions, or output resolution.
- The user can choose either a white or dark collage background, and the preview and exported image update to match.
- In Layout settings, the user can adjust the outer collage canvas corners from square (0%) through fully rounded (50%). This setting does not round individual photo frames.
- Rounded canvas corners are transparent in PNG and WebP exports. JPEG exports flatten the area outside the rounded canvas onto white because JPEG does not support transparency.
- The layout browser shows live miniature previews and compact family filters without displacing the primary collage preview.
- The layout browser scores templates for the current photos, ranks stronger crop-retention options first, and hides templates that crop materially more image area than the best options. A layout normally qualifies only when it retains at least 68% of source-photo area on average and at least 42% for every individual photo; when a canvas/photo combination makes those levels geometrically impossible, only layouts within 10 percentage points of the best achievable fit are offered.
- When photos are added or removed, the app preserves the corresponding layout variant for the new photo count when one exists and otherwise selects a compatible fallback.
- When a layout or image dimension changes, the app recalculates subject-aware crops while retaining manual crop adjustments where they remain valid.
- Regenerating an unchanged task should produce a visually equivalent collage.

### 4.4 Subject-Aware Cropping

- For every selected photo, the app attempts to identify the main subject or subjects.
- When fitting a photo into a collage frame, the crop should keep the detected main subject or subjects visible whenever the source image and frame geometry allow it.
- The app must not distort the photo to preserve a subject.
- If no subject can be detected confidently, the app uses a sensible fallback crop, such as a centered crop.
- The user can manually reposition or adjust a photo's crop when the automatic result is unsatisfactory.
- The user can drag a photo within its frame to reposition the crop.
- A coordinated photo gesture prevents crop and swap interactions from competing: hold briefly and drag to reposition the crop, or keep holding for roughly half a second before dragging to enter swap mode. Swap mode highlights the destination frame and confirms activation with stronger haptic feedback.
- The user can pinch a photo with two fingers to zoom in or out between the fitted crop and the supported maximum zoom.
- Manual crop adjustments are saved as part of the collage task.
- The selected zoom level is saved as part of the collage task.

### 4.5 Task Persistence and Editing

- Each collage task is saved within its parent project.
- A saved task includes, at minimum:
  - A unique identifier.
  - Its parent project identifier.
  - Creation and last-modified dates.
  - References to the selected source photos.
  - Photo ordering.
  - Layout and output dimensions.
  - A stable catalog layout identifier, with migration support for tasks saved using legacy layout values.
  - Selected output resolution.
  - Selected output image format and format-specific settings.
  - Selected output-quality preset.
  - Automatic and user-adjusted crop information.
  - A reference to the latest generated collage output, when available.
- The user can view a project's saved collage tasks.
- Saving a task generates or refreshes a lightweight thumbnail of the actual collage using its layout, photo crops, spacing, canvas corners, and background. The thumbnail is persisted with the task assets and loaded directly after relaunch; older tasks missing one are regenerated when their project list is opened.
- The user can reopen a task and recreate its collage.
- The user can edit a task by changing its photos, ordering, layout, or crops.
- When renaming an "Untitled Collage," the title field starts empty and focused so the user can type the replacement name immediately.
- Changes to a task persist after the app closes and relaunches.
- The user can delete a task after confirming the action.
- Deleting a task must not delete its original photos from the user's photo library.

### 4.6 Saving and Sharing

- The user can save the generated collage as a single image to the iOS photo library.
- The user can choose the output resolution before generating or exporting the collage.
- The default output resolution is 4K, and the user can increase the longest output dimension to 8K (8192 pixels).
- Available resolution choices are HD (1920 px), QHD (2560 px), 4K (4096 px), 8K (8192 px), and a custom value from 512 through 8192 pixels.
- Resolution choices must display the resulting pixel dimensions before export.
- Changing the output resolution must preserve the selected layout and composition.
- The user can choose the output image format before exporting the collage.
- Supported output formats include JPEG, PNG, and WebP. Additional formats may be added later.
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
- Choosing Save or Save and Go Back displays a blocking save-progress bar until the task data and persisted collage thumbnail have finished saving, preventing duplicate save actions.
- The user receives clear confirmation when a collage is saved successfully.
- If saving fails, the app shows an actionable error message.
- The user can share or export the generated collage using the standard iOS share sheet.
- Export first opens a full-screen review of the rendered image where the user can pinch or use controls to zoom, drag to inspect different areas, and reset the view before choosing Save to Photos or Share.
- Leaving the export review without saving or sharing discards its temporary file and does not replace the task's previous export.

## 5. User Experience Requirements

- The main navigation presents projects as the top-level view.
- Opening a project presents its collage tasks and an action to create a new task.
- Creating or editing a collage task uses a full-screen editor rather than a partial-height sheet.
- The full-screen editor provides a Back control that returns to the containing project.
- Opening an existing collage starts with the settings panel collapsed so no editor dialog obscures the collage; the user can expand a tool from the vertical tool rail.
- Using Back compares the current user-editable collage state with the last saved state. It returns immediately when they match and offers Save, Discard, or Keep Editing only when real changes exist. Saving is unavailable until the task meets the minimum photo requirement.
- Discarding a new or changed task removes newly imported photo copies that are not referenced by another saved task.
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
- The interface clearly distinguishes between saving changes to a task and exporting its generated image.

## 6. Data and Privacy Requirements

- The app requests only the photo access needed for selection and export.
- The app explains why photo access is needed before or as part of the system permission request.
- Original photos must never be altered or deleted by the app.
- Project and task data is stored locally for the MVP.
- Photo analysis and subject detection should run on-device for the MVP unless a future requirement explicitly introduces a cloud service and its privacy disclosures.
- The app must remain usable when the device is offline, except for features explicitly added later that require a network connection.

## 7. Performance and Reliability Requirements

- Common user actions should respond promptly and must not block the main interface.
- Image decoding, subject detection, cropping, and rendering must run without freezing the UI.
- Photo import generates a 256-pixel list thumbnail and a 1600-pixel editing preview off the main thread; the editor must not synchronously decode full-resolution originals.
- Every generated photo thumbnail and editing preview is persisted and loaded from disk on memory-cache misses, so reopening a collage reuses derived images without decoding the originals again.
- Editing previews and thumbnails are memory-cached with bounded memory use, while original images are loaded only for final export or explicit full-screen inspection.
- From the collage editor, the user can double-tap a collage frame or use an explicit View Original Photo action to open that source photo full-screen.
- The original-photo viewer loads the locally preserved original-resolution file off the main thread and supports pinch zoom, pan, double-tap zoom/reset, explicit zoom controls, and close.
- In the Photos panel, tapping the thumbnail, the central photo details area, or the expand button opens the original photo viewer.
- While dragging a photo to swap positions, a floating preview of the dragged photo follows the user's finger and displays a switch icon at its top-right. The destination frame is highlighted and also displays a switch icon. The drag-and-drop operation uses move semantics rather than showing the system copy “+” indicator.
- Existing tasks generate missing derived images lazily without changing their saved crops or requiring manual migration.
- Saving an existing task after removing or replacing a photo removes that photo's unreferenced local original copy, editing preview, list thumbnail, memory-cache entries, stored focus metadata, and stale rendered export. Assets still referenced by another saved task are retained, and startup maintenance prunes orphaned generated files left by interruptions.
- The app should manage memory carefully when processing multiple high-resolution photos.
- The app should preserve saved project and task data across normal app upgrades.
- If collage generation is interrupted or fails, the saved task should remain recoverable and editable.

## 8. MVP Acceptance Criteria

The MVP is complete when a user can:

1. Create and name a project.
2. Create a collage task within that project.
3. Select at least two photos from the iOS photo library.
4. Preview one automatically sized collage containing every selected photo.
5. See automatic crops that attempt to keep each photo's main subject visible.
6. Manually correct an unsatisfactory crop.
7. Replace the automatically selected layout with another available layout.
8. Change the collage to another standard image dimension.
9. Select an output resolution, with 4K used by default and 8K (8192 pixels) available as the maximum.
10. Choose JPEG, PNG, or WebP as the output format.
11. Choose Space Saver, Balanced, or Best Quality and understand the corresponding quality/file-size tradeoff.
12. Save the task, close the app, and later reopen the task with its photos, ordering, layout, dimensions, resolution, output format, output quality, and crop adjustments intact.
13. Update and regenerate the saved collage.
14. Save the generated collage to the photo library or share it.
15. Delete an individual task without affecting the original photos.
16. Store and manage multiple collage tasks within one project.
17. Hide and restore editor controls while keeping the collage visible.
18. Reposition and zoom an individual photo directly on the collage canvas.
19. Swap two photos using drag and drop on the collage canvas.
20. Browse compatible layouts by family for any selection from 1 through 12 photos.
21. Render and export rectangular and multi-row, multi-column slanted-mosaic layouts consistently with their on-screen previews.
22. Choose a white or dark collage background and preserve that choice when the task is saved and reopened.
23. Review the rendered export full-screen, zoom and pan to inspect it, and then choose Save to Photos, Share, or Back without saving.

## 9. Assumptions

- The first release targets iPhone running iOS 17 or later; iPad-specific layouts can be defined later.
- Each photo appears in one frame in the automatically generated collage.
- Automatic sizing selects from a defined set of common aspect ratios and image dimensions rather than creating an arbitrary standard canvas size.
- A collage task belongs to exactly one project.
- Local persistence is sufficient for the MVP; account login and cross-device synchronization are out of scope.

## 10. Open Questions

- Should additional canvas aspect ratios be supported beyond square (1:1), portrait (4:5), landscape (3:2), and story (9:16)?
- Which additional output formats, beyond JPEG, PNG, and WebP, should the MVP support?
- What format-specific encoding values should Space Saver, Balanced, and Best Quality use for JPEG and WebP?
- Should borders, rounded corners, text, stickers, or filters be included in the MVP?
- If an original photo is removed from the photo library, should the app retain its own copy or ask the user to replace it?
- Should deleting a project also delete collage images that were previously exported to the photo library? The recommended behavior is no.
- Is task version history required, or is saving only the latest state sufficient?
- Should projects or tasks support additional sorting or search options?
- Will iCloud synchronization or collaboration be required in a later release?

## 11. Out of Scope for the Initial MVP

- User accounts and authentication.
- Cloud backup or cross-device synchronization.
- Collaborative editing or project sharing.
- Video collages or animated output.
- Cloud-based photo analysis.
- Advanced graphic-design tools unless added through a later requirements update.
