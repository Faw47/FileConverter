---
goal: Fix every defect found in the October 2026 File Converter audit — wrong conversion output, silent failures, settings-model bugs, Finder entry-point confusion, and UI/UX/QoL problems — in risk order, with each phase shippable on its own.
version: 1.0
date_created: 2026-10-12
last_updated: 2026-10-12
owner: File Converter maintainers
status: 'Planned'
tags: [macos, swift, bug, conversion-correctness, presets, finder, ux, ui, accessibility, localization]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan fixes every issue raised in the three-part audit of File Converter (UI/UX/logic pass, Finder context-menu investigation, conversion-engine pass). Phases are ordered by user harm: first anything that produces wrong files, deletes data, or fails silently; then the settings model those fixes depend on; then conversion quality; then entry points, feedback, and finally presentation. Every phase must leave `swift test --parallel` and the `FileConverter` Xcode scheme green.

Baseline recorded 2026-10-12: `swift test --parallel` → 328 XCTest tests, 0 failures.

Evidence levels used below: **Verified** = reproduced on the maintainer's Mac; **Code** = confirmed by reading the source, not run end to end; **Likely** = strong inference, must be reproduced in TASK-002 fixtures before fixing.

### Issue coverage index

Every audit finding maps to at least one task. A phase is not complete until every issue mapped to it is closed.

| Issue | Finding | Evidence | Tasks |
|---|---|---|---|
| ISS-01 | Collision sheet resolves `pendingCollisions.first`, not the row shown; stale duplicate sheets stack | Code | TASK-010, TASK-011 |
| ISS-02 | Esc on one active job opens "Cancel All" confirmation | Code | TASK-013 |
| ISS-03 | General "Preserve dates" toggle never reaches built-in presets | Code | TASK-019, TASK-022, TASK-031 |
| ISS-04 | Sentinel inheritance (`.sameAsSource`, `{name}`, `.ask`) and global values frozen into new presets | Code | TASK-019 – TASK-023, TASK-027, TASK-028 |
| ISS-05 | Filename pattern trimmed on every keystroke; clearing the field snaps back to `{name}` | Code | TASK-029 |
| ISS-06 | Disk-space precheck demands 4× source size | Code | TASK-016 |
| ISS-07 | Tool-discovery progress is a fake 15 ms loop | Code | TASK-018 |
| ISS-08 | Filename preview reimplements naming and diverges (`{preset}`) | Code | TASK-024, TASK-030 |
| ISS-09 | Tooltips show ⌘R (real: ⇧⌘R); "Retry Failed (N)" retries only the selected job | Code | TASK-078 |
| ISS-10 | Built-in preset context menu shows "Disable" twice; second opens "Delete this preset?" | Code | TASK-086 |
| ISS-11 | Every collision activates the app and posts its own notification | Code | TASK-012 |
| ISS-12 | Mixed-format and no-compatible sheets count/list excluded files | Code | TASK-083 |
| ISS-13 | Preset picker: instant start, no destination preview, no keyboard, no recents, no per-run override | Code | TASK-080, TASK-081 |
| ISS-14 | Mixed batches require one sheet per category | Code | TASK-082 |
| ISS-15 | Queue counts lifetime jobs, never resets, not persisted; no pause/reorder/multi-select/Quick Look/double-click | Code | TASK-070 – TASK-075 |
| ISS-16 | Cancel (`xmark.circle.fill`) and Remove (`xmark.circle`) look identical | Code | TASK-076 |
| ISS-17 | Rows lack output size/elapsed time; failure text unbounded on one line | Code | TASK-077 |
| ISS-18 | Interrupted-conversion banner does not list files or offer actions | Code | TASK-079 |
| ISS-19 | PDF dialogs: wrong "Save to" label, unconditional warning, false "lossless" claim, no larger-output check, numbered-button page grid | Code | TASK-050 – TASK-053 |
| ISS-20 | Finder menu appears on folders/unsupported files, always 3 levels deep, one bad file hides presets for whole selection | Code | TASK-058 – TASK-060 |
| ISS-21 | App registered as Viewer for `public.item`; Services item "Convert with FileConverter" for every file | Code | TASK-054 |
| ISS-22 | Tool discovery limited to Homebrew paths; 5-minute cache; no manual path | Code | TASK-014, TASK-094 |
| ISS-23 | Settings autosave but presets need explicit Save — undocumented, inconsistent | Code | GUD-004, TASK-088 |
| ISS-24 | Every Settings pane repeats the tab name as a hero header | Verified (snapshot) | TASK-090 |
| ISS-25 | Hand-rolled cards/radios, "Live" badge, sparkles — web-dashboard look | Verified (snapshot) | TASK-089, TASK-091, TASK-092 |
| ISS-26 | Marketing copy ("Intelligent Thermal Protection", "Live System Telemetry", …) | Verified (snapshot) | TASK-091 |
| ISS-27 | Performance pane: slider + stepper for one value, telemetry cards, duplicate queue buttons, unconfirmed Cancel All | Verified (snapshot) | TASK-093 |
| ISS-28 | External Tools: one full card per tool; "6 of 6" counts ffprobe | Verified (snapshot) | TASK-094 |
| ISS-29 | Preset list: ~80 pt rows, no category headers, identical icons and subtitles | Verified (snapshot) | TASK-085, TASK-087 |
| ISS-30 | Built-in preset names inconsistent ("PDF to PNG" vs "MKV → MP4", "(192k)" vs "- Smaller File") | Code | TASK-084 |
| ISS-31 | Preset editor: wizard copy, verbose format names, unlabeled Enabled switch | Verified (snapshot) | TASK-088 |
| ISS-32 | Glass buttons render like disabled text; labels look like buttons | Verified (snapshot) | TASK-089, TASK-095, TASK-105 |
| ISS-33 | Drop zone always occupies ~110 pt; redundant empty state; sheet min width > window min width | Code | TASK-097, TASK-098 |
| ISS-34 | Settings window opens at 1040×700 with content capped at 720 pt | Code | TASK-096 |
| ISS-35 | No localization (4 catalog strings); plurals by string concatenation; RTL untested | Code | TASK-099, TASK-100 |
| ISS-36 | Help is a 19-line HTML page opened in a browser, with inaccurate conflict text | Code | TASK-102 |
| ISS-37 | Settings/main windows located by matching window titles | Code | TASK-101 |
| ISS-38 | Same-format presets produce `photo (1).jpg`; `{date}`/`{time}` computed per file | Code | TASK-025, TASK-026 |
| ISS-39 | `--snapshot` test harness ships in Release and can write anywhere | Code | TASK-105 |
| ISS-40 | `dist/` holds 12 old builds (738 MB); two app copies compete for the Finder extension registration | Verified | TASK-103, TASK-104 |
| ISS-41 | Right-click → "opens the app and waits": Services/Open With route to the picker; no log of which entry point was used | Verified (logs: zero extension requests in 3 days) | TASK-054 – TASK-057 |
| ISS-42 | Every native → WebP conversion fails ("destination unavailable"); ImageMagick never tried | Verified | TASK-005, TASK-006 |
| ISS-43 | "Apple Lossless (ALAC)" preset produces lossy AAC | Code | TASK-007 |
| ISS-44 | AVFoundation path ignores bitrate, CRF, fps, audio bitrate/rate/channels, metadata toggle; MP4 = MP4 High Quality; AAC = M4A | Code | TASK-039 – TASK-043 |
| ISS-45 | FFmpeg path: resolution-blind bitrates; CRF ignored on VideoToolbox; portrait 1080p → 608×1080; upscaling; no `hvc1`; HDR forced to 8-bit; extra tracks/subtitles dropped; GIF "Original" = 640 px | Code | TASK-032 – TASK-038, TASK-042 |
| ISS-46 | General collision policy "Ask"/"Skip" makes built-in preset collisions fail | Code | TASK-008 |
| ISS-47 | With "Replace", two sources mapping to one output name → second job fails | Code | TASK-009 |
| ISS-48 | Cold start: Finder requests for FFmpeg presets rejected before encoder probe finishes; silent when notifications off | Code | TASK-014, TASK-015 |
| ISS-49 | "JPEG – Web" does not resize; all presets keep GPS location by default | Code | TASK-046, TASK-047 |
| ISS-50 | Image presets ignore the resolution setting | Code | TASK-044 |
| ISS-51 | Images > 100 MP rejected as "malformed" | Code | TASK-048 |
| ISS-52 | Transparent PNG → JPEG likely gets a black background | Likely | TASK-045 |
| ISS-53 | PDF → image fixed at 144 DPI; renders media box instead of crop box | Code | TASK-049 |
| ISS-54 | Native "Compress PDF" rasterizes (no text, links, outline, forms); offers toggles it then ignores; always ends "with warnings" | Code | TASK-050 – TASK-052 |
| ISS-55 | Finder conversions give zero feedback: hidden app, notifications and reveal off by default, no Dock badge/progress | Code | TASK-064 – TASK-066 |
| ISS-56 | Preserved modification date sorts new output to the bottom of Finder's Date Modified view | Code | TASK-031 |
| ISS-57 | Two notifications per Finder conversion ("Started" + "Finished") | Code | TASK-067 |
| ISS-58 | "Replace" permanently deletes the old file | Code | TASK-017 |
| ISS-59 | Same-format presets (JPEG for a JPEG) offered and silently re-encode | Code | TASK-061, TASK-026 |
| ISS-60 | Video files list ~30 menu entries (all audio presets accept video); WAV shows "MP3" and "WAV → MP3" | Code | TASK-062 |
| ISS-61 | Finder menu hard-capped at 100 files | Code | TASK-063 |
| ISS-62 | Internal hacks: invisible "Preparing conversion…", 150 ms sleep before error alert, unobserved "Notifications blocked" | Code | TASK-068, TASK-069 |

## 1. Requirements & Constraints

- **REQ-001**: No conversion may produce an output whose format, codec, or losslessness differs from what the preset name and settings state. A preset named lossless must produce lossless output or fail with a typed error.
- **REQ-002**: No user-facing failure may be silent. Every rejected or failed request must appear as a queue row and update the Dock badge, regardless of notification settings.
- **REQ-003**: Every preset setting shown in the editor must either be honored by the backend that will run it, or be visibly marked as not used for that backend.
- **REQ-004**: A preset value inherits a General setting only when the preset explicitly says so (`PresetInheritance`), never because the value equals a sentinel.
- **REQ-005**: A collision decision must apply only to the destination(s) the user saw when choosing it.
- **REQ-006**: Replacing an existing file must move the old file to the Trash when the volume supports it.
- **REQ-007**: Finder conversions must show progress outside the main window (Dock tile and menu bar extra).
- **REQ-008**: Conversions must never upscale video or images unless the preset sets an explicit custom size larger than the source.
- **REQ-009**: Location metadata (GPS / ISO 6709) is removed by default; users can opt in to keep it globally or per preset.
- **SEC-001**: New persisted files (encoder cache, history, tool-path overrides, usage store) live under `~/Library/Application Support/FileConverter/` (or the app group container when the Finder extension must read them) with `0600` permissions and contain no file contents.
- **SEC-002**: Custom tool paths (TASK-094) must point to an executable regular file, are resolved with `URL.resolvingSymlinksInPath()`, and are invoked through the existing `ExternalProcessRunner` with its allowlisted arguments only.
- **SEC-003**: `ConversionRequest.groupID` (TASK-063) is optional, validated as a UUID, and never trusted to merge requests across editions or across a window longer than 5 seconds.
- **CON-001**: Minimum deployment target stays macOS 14.0. APIs newer than 14.0 require `#available` guards with a working fallback.
- **CON-002**: The Finder extension must not import `FileConverterCore` or any backend module (enforced by `ArchitectureBoundaryTests`).
- **CON-003**: Preset storage changes ship as schema version 3 with a one-way migration that writes a backup first; schema ≤ 2 files must still load.
- **CON-004**: External tools stay optional. Every feature that needs FFmpeg/ImageMagick/Ghostscript must degrade to a native path or hide the preset; it must never fail late.
- **CON-005**: Each phase is merged separately and must keep `swift test --parallel` and `xcodebuild -project FileConverter.xcodeproj -scheme FileConverter -configuration Debug CODE_SIGNING_ALLOWED=NO build` passing.
- **GUD-001**: Built-in preset names follow one convention: generic presets are `<Target>` or `<Target> – <Variant>` (en dash); source-specific presets are `<Source> → <Target>`; bitrates are written `320 kbps`. Never use "to", parentheses, or hyphen-minus as a separator.
- **GUD-002**: Settings panes use `Form { Section }` with `.formStyle(.grouped)` and standard button styles (`.bordered`, `.borderedProminent`, `.link`). No custom card, badge, or glass helper components.
- **GUD-003**: User-visible copy states what happens, in plain words, without adjectives such as "intelligent", "live", "high-performance", or "adaptive".
- **GUD-004**: General, Performance, External Tools, and Finder settings save immediately. The preset editor is document-like: explicit Save (⌘S, prominent) and Revert. The editor footer states "Changes are saved when you click Save".
- **GUD-005**: Every new code path that changes conversion output gets a fixture-based test that inspects the produced file (TASK-002 – TASK-004), not only a unit test of argument building.
- **PAT-001**: Settings resolution flows only through `EffectivePresetResolver.resolve` → `ResolvedConversionSettings` stored on the job. No other code reads global defaults for a conversion.
- **PAT-002**: Output geometry and bitrate decisions are computed once in Core (`VideoGeometry`, `ImageGeometry`, `VideoBitrateModel`) and consumed by every backend.
- **PAT-003**: Backends declare which preset settings they honor via `ConversionBackend.ignoredSettings(for:source:)`; the UI never hardcodes backend capabilities.

## 2. Implementation Steps

### Implementation Phase 0 — Baseline and fixtures

- GOAL-001: Establish a reproducible baseline and a media fixture corpus so every later fix is verified against real output files.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | Record baseline in this file's Introduction: `swift test --parallel` result (done: 328 tests, 0 failures) and `xcodebuild -project FileConverter.xcodeproj -scheme FileConverter -configuration Debug CODE_SIGNING_ALLOWED=NO build` result. | | |
| TASK-002 | Create `Scripts/make_test_fixtures.sh` that writes to `Tests/Fixtures/Generated/` (add to `.gitignore`) using `ffmpeg`, `sips`, and `/usr/bin/afconvert`: `landscape_1920x1080_h264.mp4` (2 s, AAC), `portrait_1080x1920_h264.mov` (2 s, rotation metadata 90°), `small_640x360_h264.mp4`, `hdr_hlg_hevc_10bit.mov` (`-pix_fmt yuv420p10le -color_trc arib-std-b67 -color_primaries bt2020 -colorspace bt2020nc`), `multitrack.mkv` (H.264 + 2 AAC tracks + SRT subtitle + chapter), `sine_44k_16bit.flac`, `sine_48k_24bit.wav`, `transparent_256.png` (alpha 0 corners), `gps.jpg` (EXIF GPS via `exiftool` if present, otherwise ImageIO helper in TASK-003), `huge_12000x10000.png` (120 MP), `text_links_outline.pdf` (generated with PDFKit helper: 3 pages, text, one link, one outline entry, cropBox ≠ mediaBox), `same_name/photo.heic` + `same_name/photo.png`. Script exits 0 and skips fixtures whose tool is missing with a printed notice. | | |
| TASK-003 | Add `Tests/FileConverterTests/Support/TestFixtures.swift`: `TestFixtures.url(_ name: String) throws -> URL` that throws `XCTSkip` when the fixture or required tool is absent; plus generators for fixtures that need Apple frameworks (GPS JPEG via `CGImageDestination` with `kCGImagePropertyGPSDictionary`; PDF with crop box, link, outline via PDFKit). | | |
| TASK-004 | Add `Tests/FileConverterTests/Support/MediaAssertions.swift`: `MediaAssertions.probe(_ url: URL) throws -> ProbeResult` (runs `ffprobe -v error -show_streams -show_format -of json`, `XCTSkip` if ffprobe missing) exposing width, height, rotation, codec_name, codec_tag_string, pix_fmt, color_transfer, bit_rate, audio stream count, subtitle stream count, chapter count, format tags; and `ImageAssertions` reading pixel size, alpha, GPS presence, and pixel color at (0,0) via ImageIO. | | |

### Implementation Phase 1 — Stop wrong output, data loss, and silent failure

- GOAL-002: Every conversion either produces the promised output, defers safely, or fails visibly. No decision applies to a file the user did not see. No replaced file is unrecoverable.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-005 | WebP/AVIF encoder truth: in `Sources/FileConverterCore/Formats/FormatRegistry.swift` set `nativeEncoderAvailable: false` for `webp` (line ~474). Add `Sources/FileConverterCore/Formats/NativeImageCodecs.swift` with `static let encodableTypeIdentifiers: Set<String>` from `CGImageDestinationCopyTypeIdentifiers()`; `FormatRegistry` computes an image format's effective native encoder flag as `declared && encodableTypeIdentifiers.contains(any of format.utTypeIdentifiers)`, and sets AVIF's flag from the same runtime check. | | |
| TASK-006 | `Sources/FileConverterNativeBackends/ImageIO/ImageIOBackend.swift`: `supports(...)` additionally requires `NativeImageCodecs.encodableTypeIdentifiers` to contain the destination UTI. When `CGImageDestinationCreateWithURL` returns nil, throw `ConversionError.encoderUnavailable(codec: destUTType.identifier, reason: "macOS cannot write this image format")` instead of `destinationUnavailable`. Result: `BackendResolver` falls through to ImageMagick for WebP, or hides WebP presets when ImageMagick is absent. | | |
| TASK-007 | Lossless/AAC audio: in `Sources/FileConverterNativeBackends/AVFoundation/AVFoundationBackend.swift` rename `convertToPCM` to `convertAudio(asset:destinationURL:target:preset:jobID:progressHandler:)` and add writer settings for AAC (`kAudioFormatMPEG4AAC`, `AVEncoderBitRateKey = (preset.audioBitrateKbps ?? 256) * 1000`) and ALAC (`kAudioFormatAppleLossless`, `AVEncoderBitDepthHintKey = preset.audioBitDepth?.bits ?? sourceBitDepth ?? 16`), honoring `audioSampleRate` and `audioChannels` for all three. Route every audio-only destination (`m4a`, `qta`, `wav`, `aiff`) through it. Delete the `AVAssetExportPresetAppleM4A` branch (line 185). | | |
| TASK-008 | Collision policy actually applied: add `public var resolvedOverwritePolicy: OverwritePolicy?` to `ConversionJob` (`Sources/FileConverterCore/Models/ConversionJob.swift`); set it in `ConversionQueue.executeJob` right after `EffectivePresetResolver.resolve` and persist it to `jobs[index]`; change `effectiveOverwritePolicy` (line 137) to `collisionOverride ?? resolvedOverwritePolicy ?? preset.overwritePolicy`. The catch block at `ConversionQueue.swift:601-606` then routes Ask → `markAwaitingCollision`, Skip/ReplaceIfNewer → `.skipped`. | | |
| TASK-009 | Same-destination jobs wait instead of failing: add `ConversionError.destinationReserved(path: String)`. In `OutputNamingEngine.resolveFinalDestinationURL` (`OutputNamingEngine.swift:237`) throw it for every non-`appendNumber` policy when the key is reserved by another job. In `ConversionQueue.executeJob` catch it: set the job back to `.queued`, store `waitingForDestinationKey`, release its reservations. `processNextJobs` skips queued jobs whose `waitingForDestinationKey` is still in `reservedOutputURLs`; `releaseReservations(for:)` calls `processNextJobs()`. When it later runs, the normal collision policy applies to the now-existing file. | | |
| TASK-010 | Live collision sheet: `CollisionResolutionView` (`Sources/FileConverterApp/UI/FileConverterMainView.swift:707`) observes `ConversionQueue.shared.pendingCollisions` directly instead of a captured array. Each row has its own `Replace`, `Keep Both`, `Skip` buttons calling `queue.resolveCollisions(decision, applyToAll: false, jobIDs: [conflict.jobID])`. Footer: `Skip All`, `Keep Both for All`, `Replace All…` (the last shows an alert "Replace N existing files? They will be moved to the Trash." before calling `resolveCollisions(.replace, applyToAll: true)`). Sheet dismisses itself when `pendingCollisions` becomes empty. In `ConversionQueue.resolveCollisions` (line 297) remove the `prefix(1)` default: a call with `applyToAll == false && jobIDs == nil` is a programmer error (`assertionFailure`, no-op). | | |
| TASK-011 | One collision sheet: change `WorkflowPresentationItem.conflictResolution` to carry only `id` (no conflict snapshot). `WorkflowPresentationCoordinator.enqueue` ignores a `.conflictResolution` item when the current or any pending item is already `.conflictResolution`. `FileConverterMainView.onChange(of: queue.pendingCollisions)` (line 168) enqueues only on the empty → non-empty transition. | | |
| TASK-012 | Throttle collision attention: in `ConversionQueue.markAwaitingCollision` post `FileConverterActivateApp` and the user notification at most once per `batchID` (new `private var collisionAlertedBatchIDs: Set<UUID>`), with body "N files in this batch already exist. Choose what to do." | | |
| TASK-013 | `ConversionQueueView.cancelSelectedActive` (`Sources/FileConverterApp/UI/Queue/ConversionQueueView.swift:313`): cancel only the selected job, with no confirmation. Confirmation remains only for the "Cancel All" button and menu item. | | |
| TASK-014 | Cold-start readiness: (a) `ExternalToolDiscovery` persists the probed encoder set and filter list to `Application Support/FileConverter/ffmpeg-capabilities.json` keyed by ffmpeg path + file size + modification date, and loads it in `init` so `cachedAvailableFFmpegEncoders()` is non-nil immediately on later launches. (b) Add `Sources/FileConverterCore/Conversion/BackendReadinessGate.swift` (`actor`, `markReady()`, `waitUntilReady(timeout: Duration) async -> Bool`). `AppState.startBackendDiscovery` calls `markReady()` after `refreshAllTools`. (c) `ConversionCoordinator.handleConversionRequest` awaits the gate (timeout 30 s) before `validateAdmission` whenever the preset is not guaranteed native (`backend` not in `[.imageIO, .pdfKit, .avFoundation]`). | | |
| TASK-015 | Rejected requests are visible: add `ConversionQueue.recordRejectedRequest(sources: [(displayName: String, path: String)], presetName: String, reason: String)` that appends terminal `.failed(.admissionRejected(reason))` rows in a new batch. Call it from `ConversionCoordinator.drainPendingRequests` on every rejection (replacing the notification-only path). | | |
| TASK-016 | Realistic disk precheck: replace `ConversionQueue.estimateRequiredDiskSpace` (line 1001) with `OutputSizeEstimator.estimate(job:outputCount:probe:)` in Core: PCM = duration × sampleRate × channels × bytesPerSample; known target bitrate = duration × (video + audio kbps) / 8; images = width × height × 4 per output; PDF raster = pages × (pageWidth × dpi/72) × (pageHeight × dpi/72) × 3; otherwise source size × 1.25. Fail only when available < estimate; add a warning when available < 2 × estimate. | | |
| TASK-017 | Replace → Trash: in `OutputNamingEngine.finalizeConversionOutputs` (replacement branch near line 658) call `FileManager.default.trashItem(at:resultingItemURL:)` on the existing destination inside the coordinated write before moving the new file in. If trashing throws (volume without Trash), keep the current atomic replace and append the warning "The previous file could not be moved to the Trash and was replaced." | | |
| TASK-018 | Real discovery progress: give `ExternalToolDiscovery.refreshAllTools` a `progress: (@Sendable (String) -> Void)?` parameter invoked before each real probe (`ffmpeg`, `ffprobe`, `magick`, `gs`, `soffice`, `ebook-convert`, encoder list). `AppState.startBackendDiscovery` forwards it to `discoveryStatus`; delete the sleep loop at `Sources/FileConverterApp/AppState.swift:114-120`. | | |

### Implementation Phase 2 — Explicit settings inheritance

- GOAL-003: Presets inherit General settings only by explicit choice; every conversion uses one resolved settings object; naming previews match real output.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-019 | Add `public struct PresetInheritance: Codable, Hashable, Sendable { var outputLocation, filenamePattern, collisionPolicy, creationDate, modificationDate, locationData: Bool }` (true = use General setting) to `Sources/FileConverterCore/Models/ConversionPreset.swift`; add `public var inheritance: PresetInheritance` to `ConversionPreset` (init default: all `true`). Decoding a preset without the key applies TASK-020 rules. | | |
| TASK-020 | Schema v3 migration in `Sources/FileConverterCore/Presets/PresetStore.swift`: bump `PresetStoreDocument` default `schemaVersion` to 3; on loading v≤2, write `presets.v2-backup-<timestamp>.json` then migrate. Built-ins: all flags `true`. Custom presets (preserves today's effective behavior): `outputLocation = (outputDirectoryPolicy == .sameAsSource)`, `filenamePattern = (pattern.isEmpty || pattern == "{name}")`, `collisionPolicy = (overwritePolicy == .ask)`, `creationDate = false`, `modificationDate = false`, `locationData = true`. Apply the same rules in `PresetExchange` import when the key is missing; export always writes it. | | |
| TASK-021 | Add `Sources/FileConverterCore/Settings/ConversionDefaults.swift`: `enum Keys` (moved from `AppSettings.Keys`: `outputDirectoryPolicy`, `overwritePolicy`, `fc.defaultFilenamePattern`, `fc.customOutputFolderBookmark`, `fc.customOutputFolderPath`, new `fc.preserveCreationDate`, `fc.preserveModificationDate`, `fc.removeLocationData`) and `struct ConversionDefaults { static func current(_ defaults: UserDefaults = .standard) -> ConversionDefaults }`. `AppSettings.Keys` aliases these. Delete raw-string reads at `OutputNamingEngine.swift:61-66` and `:113-128`, `ConversionQueue.swift:445`, `EffectivePresetResolver.swift:85`. | | |
| TASK-022 | Rewrite `EffectivePresetResolver.resolve(preset:defaults:collisionOverride:customFolderURL:)` to choose each value from `defaults` when the matching `inheritance` flag is true, else from the preset; add `preserveCreationDate`, `preserveModificationDate`, `removeLocationData` to `ResolvedConversionSettings`, each with `SettingProvenance`. Remove all sentinel comparisons (lines 69, 79, 87). | | |
| TASK-023 | `ConversionQueue.executeJob`: delete the duplicated `tempOutputPolicy` computation (lines 430-431); resolve once into `job.resolvedSettings: ResolvedConversionSettings?` (new field) before acquiring the custom-folder lease; use it for naming, timestamps (`FileAccessManager.preserveTimestamps(from:to:creation:modification:)`), location stripping, and TASK-008. | | |
| TASK-024 | `OutputNamingEngine.generateFormattedFilename` takes the resolved pattern and a `NamingContext(batchDate: Date, presetMenuName: String)`; add `public static func previewFilename(pattern:sourceName:sourceExtension:targetExtension:presetMenuName:date:) -> String` sharing the same code. `{preset}` sanitization: replace "→" with "to", collapse every run of characters outside `[A-Za-z0-9-]` to one `_`, trim leading/trailing `_` ("MKV → MP4" → "MKV_to_MP4"). | | |
| TASK-025 | Add `ConversionJob.batchCreatedAt: Date` set in `ConversionQueue.addJobs`; `{date}`/`{time}` use it so a batch shares one timestamp. | | |
| TASK-026 | Same-format suffix: add `ConversionPreset.sameFormatSuffix: String?`. When source and target extensions match and the resolved pattern is `{name}`, append it (`-web`, `-compressed`, `-small`, `-hq`, `-720p`, `-1080p`). Set it on every built-in whose destination can equal its source. | | |
| TASK-027 | `Sources/FileConverterApp/Settings/PresetEditorView.swift` `outputSection` (line 930) and `metadataSection` (line 1043): each inheritable control's first choice is "Use General setting (<current value>)", bound to the matching `inheritance` flag; a caption shows the resolver's provenance text. | | |
| TASK-028 | `PresetsSettingsView.addPreset` (`PresetsSettingsView.swift:433-440`): stop copying global values; new presets start with every `inheritance` flag `true`. | | |
| TASK-029 | `GeneralSettingsView` filename field: bind to a local `@State draftPattern`; validate on every change (show inline error for `/ : \ ? % * | " < >` and for a pattern without `{name}`); commit to `AppSettings.defaultFilenamePattern` on submit or focus loss. Remove trimming from `AppSettings.defaultFilenamePattern.didSet` (keep it only in the commit path). | | |
| TASK-030 | `GeneralSettingsView` preview: replace `computedPreviewName`/`computedPreviewFormatted` (lines 402-427) with `OutputNamingEngine.previewFilename` using the first enabled video built-in's `menuName` and a `.mov` → `.mp4` sample; remove the "Live" badge and sparkles icon. | | |
| TASK-031 | Split timestamps: replace General "Preserve creation and modification dates" with two toggles, "Keep original creation date" (default on) and "Keep original modification date" (default off). Migration: existing `preserveTimestamps == false` → both off; `true` → creation on, modification off. `FileAccessManager.preserveTimestamps(from:to:creation:modification:)` sets only the selected attributes. | | |

### Implementation Phase 3 — Video and audio pipeline correctness

- GOAL-004: Every video/audio preset honors its settings on both native and FFmpeg paths, keeps orientation, never upscales, plays in Apple apps, handles HDR deliberately, and keeps tracks the target container can hold.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-032 | Add `Sources/FileConverterCore/Conversion/VideoGeometry.swift`: `static func targetSize(sourceWidth:sourceHeight:rotationDegrees:resolution:) -> (width: Int, height: Int)`. Presets cap the long edge (`uhd4k` 3840, `hd1080p` 1920, `hd720p` 1280, `sd480p` 854); `custom(w,h)` fits inside the box after orienting it to the source; the result never exceeds the source; both dimensions are rounded down to even numbers. | | |
| TASK-033 | Add `Sources/FileConverterCore/Conversion/VideoBitrateModel.swift`: `static func targetKbps(width:height:fps:codec:quality:sourceKbps:) -> Int` = width × height × fps × bpp / 1000, with bpp: H.264 `low 0.05, medium 0.07, high 0.10, veryHigh 0.15`; HEVC/AV1 = H.264 × 0.6; VP9 = H.264 × 0.7. Clamp to [300, 100 000]; for `low`/`medium` also clamp to ≤ `sourceKbps` when known. | | |
| TASK-034 | Extend `Sources/FileConverterExternalBackends/FFmpeg/MediaProbeCache.swift` probe to return width, height, rotation (display matrix side data or `rotate` tag), fps, bit_rate, video codec, pix_fmt, color_transfer, color_primaries, audio codecs per stream, subtitle codecs per stream, chapter count, duration. Provide the same struct from AVFoundation (`AVAssetTrack.naturalSize`, `preferredTransform`, `nominalFrameRate`, `estimatedDataRate`, format descriptions) as `NativeMediaProbe` in NativeBackends. | | |
| TASK-035 | `FFmpegBackend` video args (`FFmpegBackend.swift:795-946`): scale with `-vf scale=W:H` from `VideoGeometry` (omit when unchanged); when `preset.videoBitrateKbps == nil` use `VideoBitrateModel`; VideoToolbox encoders get `-b:v X -maxrate 1.5X -bufsize 2X`; software encoders get `-crf` only (no `-b:v`); add `-tag:v hvc1` for HEVC in mp4/mov and `-movflags +faststart` for mp4/mov. | | |
| TASK-036 | `FFmpegBackend` stream mapping: `-map 0:v:0 -map 0:a? -map_chapters 0`. Subtitles: mkv → `-map 0:s? -c:s copy`; mp4/mov → map only text subtitle streams (`subrip`, `ass`, `webvtt`, `mov_text`) with `-c:s mov_text`; image-based streams are dropped with warning "N picture-based subtitle tracks were not kept (MP4 cannot store them)". | | |
| TASK-037 | HDR policy: when the probe's `color_transfer` is `smpte2084` or `arib-std-b67`: HEVC targets keep 10-bit (`-pix_fmt p010le` for `hevc_videotoolbox`, `yuv420p10le` for libx265) and copy `-color_primaries/-color_trc/-colorspace`; 8-bit targets (H.264, VP9 profile 0, GIF) tone-map with `zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p` when `ExternalToolDiscovery` reports the `zscale` filter (probe `ffmpeg -filters`, cached by TASK-014); otherwise convert without tone mapping and add the warning "HDR video was converted to SDR without tone mapping; colors may look washed out." Remove the unconditional `yuv420p` for HEVC at line 880. | | |
| TASK-038 | Stream-copy fast path: add `ConversionPreset.allowsStreamCopy: Bool` (true for `video.mkv-to-mp4`, `video.mov-to-mp4`). FFmpeg: when probe video codec ∈ {h264, hevc} and every mapped audio codec ∈ {aac, alac, mp3, ac3, eac3}, emit `-c:v copy -c:a copy` (+ `-tag:v hvc1` for HEVC). Native: use `AVAssetExportPresetPassthrough` when `AVAssetExportSession.compatibleFileTypes` contains `.mp4`. Otherwise re-encode with preset settings. GIF preset: `resolution: .custom(width: 480, height: 480)`; `.original` in the GIF branch (line 785) means source size. | | |
| TASK-039 | Add `Sources/FileConverterNativeBackends/AVFoundation/AVFoundationVideoTranscoder.swift`: `AVAssetReader` (video via `AVAssetReaderVideoCompositionOutput` with an `AVMutableVideoComposition` for scale + `preferredTransform` + frame duration) → `AVAssetWriter`. Video settings: `AVVideoCodecKey` (h264/hevc/proRes422), `AVVideoAverageBitRateKey` from preset or `VideoBitrateModel`, `AVVideoExpectedSourceFrameRateKey`, HEVC Main10 profile when keeping HDR; HDR → SDR for H.264 by setting the composition's `colorPrimaries/colorTransferFunction/colorYCbCrMatrix` to ITU-R 709. Audio via TASK-007 settings. Progress = last appended presentation time ÷ duration. Cancellation cancels reader and writer and removes the temp file. | | |
| TASK-040 | `AVFoundationBackend.convert`: use the transcoder for every video re-encode; use `AVAssetExportSession` only for passthrough (TASK-038). Delete `determineExportPreset` (lines 180-224). | | |
| TASK-041 | Settings honoring (PAT-003): add `func ignoredSettings(for preset: ConversionPreset, source: FormatDefinition) -> Set<PresetSettingKey>` to `ConversionBackend` (default empty). FFmpeg returns `.crf` when the hardware encoder will be used; AVFoundation returns `.crf` (bitrate is used instead) and `.extraBackendOptions`. `PresetEditorView` asks `BackendResolver.evaluate` for a representative source of each accepted format and shows "Not used when converting <formats> (Apple encoder)" under each ignored control. | | |
| TASK-042 | Built-in video presets (`Sources/FileConverterCore/Presets/BuiltInPresets.swift:18-240`): set `videoBitrateKbps: nil` on all (bitrate comes from the model); keep `crf` for software encoding; `video.hevc-hardware` → `hardwareAcceleration: .auto`; distinct `quality` per variant (`low`, `high`, `veryHigh`) so the variants differ on every backend. | | |
| TASK-043 | Audio built-ins: remove `audio.m4a` (same settings as `audio.aac-256`); rename `audio.aac-256` menu to "AAC (M4A)". `PresetStore` drops built-ins whose key no longer exists; if the stored copy was user-modified, convert it to a custom preset (`isBuiltIn = false`, new UUID) instead of deleting it. | | |

### Implementation Phase 4 — Images and PDF

- GOAL-005: Image presets resize, strip location, handle transparency and very large images; PDF exports use the visible page at a chosen DPI; native compression keeps text and never makes files bigger.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-044 | Image resize: add `ImageGeometry.maxPixelSize(resolution:sourceWidth:sourceHeight:) -> Int?` (same caps as TASK-032, nil for `.original`, never upscales). In `ImageIOBackend.convert`, when non-nil, create each frame with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize`, `kCGImageSourceCreateThumbnailWithTransform: true`, `kCGImageSourceCreateThumbnailFromImageAlways: true`) and write it with orientation 1. ImageMagick backend passes `-resize WxH>`. | | |
| TASK-045 | Transparency: when the destination `FormatDefinition.supportsAlpha == false` and the source frame reports `kCGImagePropertyHasAlpha == true`, draw the frame onto an opaque white sRGB `CGContext` and add that `CGImage` instead of `CGImageDestinationAddImageFromSource`. First reproduce ISS-52 with `transparent_256.png` (TEST-019); if ImageIO already flattens to white, keep only the test. | | |
| TASK-046 | Location privacy (REQ-009): General toggle "Remove location from converted files" (default on, key `fc.removeLocationData`, inheritable via `PresetInheritance.locationData`). ImageIO: remove `kCGImagePropertyGPSDictionary` from written properties. FFmpeg: append `-metadata location= -metadata location-eng= -metadata com.apple.quicktime.location.ISO6709=`. AVFoundation transcoder: drop metadata items whose identifier is `.quickTimeMetadataLocationISO6709` or `.quickTimeUserDataLocationISO6709`. | | |
| TASK-047 | `image.jpeg-web` built-in: `resolution: .custom(width: 2048, height: 2048)`, `quality: .medium`, `sameFormatSuffix: "-web"`. | | |
| TASK-048 | Large images: replace the 100 MP rejection at `ImageIOBackend.swift:98`. With a resize target, use the thumbnail path for sources up to 1 000 MP. Without one, allow up to 250 MP; above that throw new `ConversionError.imageTooLarge(width:height:limitMegapixels:)`, message "This image is W×H (N MP), too large to convert at full size. Choose a preset with a size limit." Replace the hardcoded `elapsedTime` values (0.1, 0.5, 1.0) with real elapsed time. | | |
| TASK-049 | PDF → image: renderer in `PDFKitBackend.swift` (line 457 and the multi-page path) uses `.cropBox` for bounds and drawing and DPI from `processingOptions.pdfDPI`, defaulting to 300 for PNG/TIFF and 200 for JPEG. `PresetEditorView` shows a DPI picker (72/150/200/300/600) for presets whose source is PDF and destination is an image. | | |
| TASK-050 | Native PDF compression that keeps text: default path writes `PDFDocument.write(to:withOptions:)` with `.saveImagesAsJPEGOption: true` and `.optimizeImagesForScreenOption: (profile != "prepress")` (macOS 13+ API, available on the macOS 14 target), preserving text, links, outline, and forms. The current rasterize path (`PDFKitBackend.swift:600-740`) runs only when the new option `processingOptions.pdfFlattenToImages == true`; that path also passes `.saveTextFromOCROption: true` so the result stays searchable. | | |
| TASK-051 | Never grow a PDF: after compression, if output size ≥ source size, delete the temp output and finish the job as `.skipped("Already optimized: the compressed file was not smaller")`. | | |
| TASK-052 | `PDFCompressDialogView`: show "Remove thumbnails", "Linearize", and "PDF version" only when Ghostscript will run; add "Flatten pages to images (smallest file, removes selectable text)" for the native path; show the info banner only when Ghostscript is absent, with copy "Install Ghostscript for stronger compression that keeps text sharp." Remove the "lossless vector output" claim (line 175) and the post-hoc warnings at `PDFKitBackend.swift:256-269` that the UI now prevents. | | |
| TASK-053 | Both PDF dialogs' "Save to" row shows the real destination computed by `EffectivePresetResolver` + `OutputNamingEngine` (e.g. "Downloads"), not a hardcoded "Same folder as original". `PDFSplitDialogView` page grid: lazy thumbnails (`PDFPage.thumbnail(of: CGSize(width: 96, height: 128), for: .cropBox)`), shift-click range selection, ⌘-click toggle, and two-way sync with the range text field. | | |

### Implementation Phase 5 — Entry points and Finder menu

- GOAL-006: Every right-click path is understandable, logged, and either converts directly or remembers the user's choice; the Finder menu shows only useful entries.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-054 | `Sources/FileConverterApp/Info.plist`: restrict `CFBundleDocumentTypes` `LSItemContentTypes` and `NSServices` `NSSendFileTypes` to supported input UTIs, generated from `FormatRegistry` by new `Scripts/generate_document_types.swift` (run by `Scripts/package_app.sh`, verified by TEST-027). Rename the service to "Convert with File Converter…" (ellipsis signals a chooser). | | |
| TASK-055 | Log entry points: `AppDelegate.application(_:open:)` and `openFilesFromService` (`AppMain.swift:190-244`) emit `AppLogger.finder.notice("Files received via <openWith|service|dock|url>: count=N")`. | | |
| TASK-056 | Add `Sources/FileConverterCore/Presets/PresetUsageStore.swift`: last preset ID per source format ID plus 8 most-recent preset IDs, stored in UserDefaults key `fc.presetUsage`; updated in `ConversionCoordinator.convertFiles` and `handleConversionRequest`. | | |
| TASK-057 | General → "Files opened without a preset (Open With, Services, Dock)": `Ask, with my last choice selected` (default) / `Convert right away with my last choice for that file type`. In the second mode, `AppDelegate` calls `AppState.convertFilesWhenReady` directly when `PresetUsageStore` has a preset compatible with every file; otherwise it falls back to the picker. | | |
| TASK-058 | `FileConverterFinderSync.menu(for:)` (`Sources/FileConverterFinderSync/FileConverterFinderSync.swift:29`): return `nil` when integration is ready and `sections` is empty (folders, unsupported files). Keep the setup item only when the channel or snapshot is not ready. | | |
| TASK-059 | Flatten: when `sections.count == 1`, add its entries directly to the "File Converter" submenu (two levels). | | |
| TASK-060 | Partial selections: `FinderMenuCatalog.sections(for:)` returns presets compatible with at least one file when no preset covers all; titles get " (3 of 5 files)"; `conversionPresetSelected` sends only the compatible files. | | |
| TASK-061 | Hide identity conversions: add `ConversionPreset.isIdentityTransform(for format: FormatDefinition) -> Bool` (destination == source format, `resolution == .original`, `processingOptions == nil`, `quality >= .high`, `sameFormatSuffix == nil`). Exclude such presets in `PresetValidator.compatiblePresets` and in `FinderMenuCatalog` (add the needed fields to `FinderMenuSnapshot`, `Sources/FileConverterContracts/FinderMenuSnapshot.swift`). | | |
| TASK-062 | Menu size: when every selected file is video, audio-category presets go into a section titled "Extract Audio" ordered after video. When a source-specific preset (its `sourceFormats` lists the exact format ID) and a generic preset share a destination format, show only the source-specific one for that source. | | |
| TASK-063 | Raise the Finder limit: add optional `groupID: UUID?` to `ConversionRequest` (`Sources/FileConverterContracts/ConversionRequest.swift`). The extension splits selections into requests of ≤ 100 sources sharing one `groupID`; `ConversionCoordinator` merges requests with the same `groupID` that arrive within 5 s into one queue batch via new `ConversionQueue.addJobs(_:batchID:)`. New ceiling: 1 000 files ("Maximum 1,000 files"). | | |

### Implementation Phase 6 — Progress, notifications, and feedback

- GOAL-007: Users always know a conversion is running, finished, or failed — even when the main window is hidden — with at most one notification per batch.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-064 | Dock tile: `Sources/FileConverterApp/UI/DockProgressController.swift` sets `NSApp.dockTile.badgeLabel` to active + queued count, draws a progress bar from `queue.overallProgress` via a custom `contentView`, shows "!" when failures happened since the app last became active, and clears on activation. | | |
| TASK-065 | Menu bar extra: `MenuBarExtra` scene with active jobs (name + %), "Show Last Converted File", "Open File Converter", "Pause Queue". General toggle "Show in menu bar" (default on). | | |
| TASK-066 | Notification onboarding: change `AppSettings` default `enableNotifications` to `true` for new installs. On the first admitted Finder request with `notificationAuthorizationState == .notDetermined`, call `requestNotificationAuthorization()` once. | | |
| TASK-067 | One notification per batch: remove the "Conversion Started" notification from `ConversionCoordinator.handleConversionRequest`; the batch completion notification states successes and failures ("3 converted, 1 failed"). | | |
| TASK-068 | `ConversionQueueView` observes `AppSettings.shared` with `@ObservedObject` so the "Notifications blocked" hint updates live. | | |
| TASK-069 | Remove hidden waits: `FileConverterMainView.enqueueSelected` adds jobs immediately as queue rows with status "Waiting for tool check…" while `BackendReadinessGate` is pending (new `JobState.waitingForTools`). Delete the in-sheet "Preparing conversion…" view (lines 405-413) and the 150 ms sleep in `startConversion` (line 666). | | |

### Implementation Phase 7 — Queue

- GOAL-008: The queue presents the current batch clearly, keeps history, and supports standard macOS list interactions.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-070 | Batch-scoped header: summarize the newest batch that has non-terminal jobs (else the newest batch); replace "Item X of Y" with "N converting, M waiting"; finished older batches collapse into an "Earlier" section with one summary row per batch (expandable). | | |
| TASK-071 | History: `QueueHistoryStore` persists terminal job summaries (filename, preset name, state, output paths as bookmarks, finishedAt; max 200) to `Application Support/FileConverter/history.json`; loaded at launch into "Earlier". "Clear Finished" also clears history. | | |
| TASK-072 | Pause/Resume: `ConversionQueue.isPaused` (`@Published`); `processNextJobs` returns early while paused; Conversion menu item "Pause Queue"/"Resume Queue" (⌥⌘P) and a toolbar button when jobs are waiting. | | |
| TASK-073 | Reorder: drag waiting rows; `ConversionQueue.moveQueuedJob(id:before:)`. | | |
| TASK-074 | Multi-select: `Set<UUID>` selection with ⌘/⇧-click and ⌘A; Delete removes selected finished rows; Return reveals all selected outputs; context-menu actions apply to the selection. | | |
| TASK-075 | Quick Look and open: Space toggles `QLPreviewPanel` for the selected outputs (responder via `NSViewRepresentable` implementing `QLPreviewPanelDataSource`); double-click opens the output. | | |
| TASK-076 | Row controls: keep the cancel button for active rows; the remove button for finished rows appears only on hover, uses SF Symbol `xmark`, and stays in the context menu. Keep `magnifyingglass.circle.fill` for "Show in Finder" (it matches Safari's Downloads list; the audit's objection to it is withdrawn). | | |
| TASK-077 | Row details: completed rows show "2.1 MB → 640 KB (−70%)" and elapsed time; failed rows use `.lineLimit(2)` plus a "Details" button opening the existing error popover. | | |
| TASK-078 | Retry semantics: the header button is "Retry All Failed (N)" and always retries every failed job; per-row and context-menu "Retry" retries one. Fix help strings to "⇧⌘R" (`ConversionQueueView.swift:203`). | | |
| TASK-079 | Interrupted banner: list up to 5 entries (file name, preset name) from `ConversionJournal` with "Show Original", "Convert Again" (re-admits via the stored bookmark), and "Dismiss"; "+N more" disclosure beyond 5. | | |

### Implementation Phase 8 — Preset picker and preset library

- GOAL-009: Picking a preset is fast, keyboard-driven, shows where output goes, and the library is consistently named and easy to scan.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-080 | Picker (`FileConverterMainView.presetSelectionSheet`): "Recent" section first (from `PresetUsageStore`); initial focus on the last-used compatible preset; arrow keys move focus across the grid; Return starts the focused preset; typing any letter moves focus to the search field; Esc cancels. | | |
| TASK-081 | Picker footer: "Saves to <folder> as <filename>" for the first file (resolver + `previewFilename`), plus an "Options…" disclosure for per-run overrides of output location and quality that do not modify the preset (`ConversionJob.runOverrides`). | | |
| TASK-082 | Mixed batches: one sheet with a row per category (icon, count, preset menu defaulting to the last used, include checkbox) and a single "Convert" button. Delete "Convert All Groups in Turn" and the per-category re-enqueue. | | |
| TASK-083 | Counts: use `recognizedURLs` for the mixed-format title and the no-compatible list (`FileConverterMainView.swift:296, 367, 383`) and show unsupported files in a separate "Not supported" list. | | |
| TASK-084 | Rename built-ins per GUD-001. Map: "PDF to PNG/JPEG/TIFF" → "PDF → PNG/JPEG/TIFF"; "EPUB to PDF" → "EPUB → PDF"; "MP3" → "MP3 – 320 kbps"; "MP3 (192k)" → "MP3 – 192 kbps"; "MP3 (128k)" → "MP3 – 128 kbps"; "MP4 - Smaller File" → "MP4 – Smaller"; "MP4 - High Quality" → "MP4 – High Quality"; "HEVC - Smaller File" → "HEVC – Smaller"; "JPEG - Web" → "JPEG – Web"; "GIF" (video) → "Animated GIF"; "GIF Image" → "GIF"; "Audio ≤ 5 MB" → "Audio – Fit in 5 MB"; "Split Audio (5 min)" → "Audio – Split into 5-min Parts". Migration renames a stored built-in only when its `menuName` still equals the old factory value. | | |
| TASK-085 | Preset sidebar (`PresetsSettingsView.presetSidebar`): `Section(category.displayName)` headers; single-line rows (menu name + destination badge; dimmed when disabled); per-category icons; "Custom" badge only on custom presets; remove the repeated "Built-in · Any video → .MP4" subtitle. | | |
| TASK-086 | Context menu (`PresetsSettingsView.swift:257-271`): one "Enable"/"Disable" item; "Delete…" only for custom presets; "Restore Factory Settings" for modified built-ins. | | |
| TASK-087 | Import: remove the "Replace matching presets on import" toggle (line 325); conflicts always go through `PresetConflictResolutionSheet`. | | |
| TASK-088 | Preset editor: rename "Quick setup / Start here / Describe the conversion in two choices" to a plain "Conversion" section; use `FormatDefinition.shortName` ("WAV") in pickers instead of full names; label the header switch "Show in menus"; make Save `.borderedProminent` with ⌘S; footer text per GUD-004. | | |

### Implementation Phase 9 — Settings UI

- GOAL-010: Settings look and behave like a native macOS settings window, with plain copy and no duplicated controls.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-089 | Rebuild General, Performance, External Tools, and Finder panes with `Form { Section }` `.formStyle(.grouped)`. Delete `SettingsIconBadge` headers, `LiquidGlassContainer`, `SettingsCard`, and the `glassAction*` helpers (`SettingsComponents.swift:99-133, 374-418`) once unused; use standard button styles (GUD-002). | | |
| TASK-090 | Remove the per-pane hero header (icon + title + subtitle) from every pane. | | |
| TASK-091 | Copy pass per GUD-003: delete "Intelligent Thermal Protection", "Live System Telemetry", "macOS Adaptive Sensors", "Optimize multi-core conversion throughput and intelligent thermal adaptation", "ready for high-performance conversions", "Running at full capacity", the "Live" badge, and decorative sparkles/tortoise/hare icons. | | |
| TASK-092 | General pane: output location as `Picker(.radioGroup)` plus a folder path control with "Choose…"; filename pattern field backed by an `NSTextField` representable exposing the selected range so token buttons insert at the caret; drop `{ext}` from the documented tokens (the extension is always appended; the engine keeps accepting `{ext}`). | | |
| TASK-093 | Performance pane: a single "Simultaneous conversions" picker (Automatic (N), 1…16); one status line only when the thermal state is serious or critical ("Converting one file at a time while your Mac cools down"); delete thermal bars, telemetry cards, and the Quick Queue Maintenance section. | | |
| TASK-094 | External Tools pane: compact rows (name, version, status, path) with a row menu: Copy Path, Choose Custom Location…, Use Automatic Location. Overrides stored in `fc.toolPathOverrides` and checked first by `ExternalToolDiscovery.searchPaths(for:)` (SEC-002); ffprobe shown under FFmpeg; count excludes ffprobe; install command shown only for missing tools; automatic rescan when the app becomes active and the last scan is older than 60 s. | | |
| TASK-095 | Finder pane: one status row (state text + "Open Login Items & Extensions…"), setup steps as plain numbered text (no button-styled labels), troubleshooting actions in a `DisclosureGroup`. | | |
| TASK-096 | Window sizing: remove `.defaultSize(width: 1040, height: 700)` (`AppMain.swift:253`) and the `idealWidth: 1040` frame in `SettingsView`; each tab sizes to content at 640 pt wide; the Presets tab uses min 860 × 600. | | |

### Implementation Phase 10 — Main window

- GOAL-011: The main window gives the queue the space and shows one clear drop target.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-097 | Hide `DropZoneView` while the queue has rows; keep window-wide drop with an accent overlay while dragging; empty state is one card with "Drop files here" and a "Choose Files…" button (merge `emptyQueueView` and `DropZoneView`). | | |
| TASK-098 | Sizes: main window `minWidth: 560, minHeight: 420`; picker sheet `minWidth: 560, idealWidth: 720` so a sheet is never wider than the window's minimum. | | |

### Implementation Phase 11 — Localization, accessibility, help, window plumbing

- GOAL-012: The app is localizable, works right-to-left, finds its windows reliably, and ships accurate help.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-099 | Enable string extraction (`SWIFT_EMIT_LOC_STRINGS = YES` in `project.yml` and the Xcode project); move all user-visible strings into `Resources/Localizable.xcstrings`; replace every plural built by concatenation (search `!= 1 ? "s"` and `== 1 ? ""`) with `String(localized:)` plural variations. | | |
| TASK-100 | RTL pass: run with `-AppleLanguages (ar) -NSForceRightToLeftWritingDirection YES`; replace directional SF Symbols (`arrow.right`) with `arrow.forward`; fix fixed-side paddings; record screenshots in the PR. | | |
| TASK-101 | Window lookup: delete title matching in `AppState.openSettings` and `AppDelegate.isSettingsWindow` (`AppMain.swift:86-89`); open Settings via the stored `openSettings` environment action and identify the main window only by `MainWindowTracker`/identifier. | | |
| TASK-102 | Help: replace `Resources/Help.html` with `Resources/Help.md` rendered in an in-app `Window("File Converter Help", id: "help")`; content covers the Finder menu vs Open With/Services, preset inheritance, collisions (per-file decisions, Trash), Dock/menu bar progress, and optional tools. | | |

### Implementation Phase 12 — Build and release hygiene

- GOAL-013: Development builds don't pile up, and only one app copy owns the Finder extension. Test tooling stays out of Release builds.

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-103 | `Scripts/package_app.sh` (lines 55-65): keep only the single most recent `*.previous.*` app and dSYM; delete older ones; add `--no-backup`. | | |
| TASK-104 | Add `Scripts/use_build.sh <path-to-.app>`: registers that copy (`lsregister -f`), re-elects its extension (`pluginkit -a <appex>` then `pluginkit -e use -i io.fileconverter.app.findersync`), and prints which copy now owns the extension. Document in CONTRIBUTING.md that `/Applications` and `dist/` copies compete. | | |
| TASK-105 | Wrap `SnapshotRunner` and the `--snapshot` check in `FileConverterApp.init` in `#if DEBUG`. After TASK-089 removes glass styles, re-run snapshots and confirm selected tabs and list rows render. | | |
| TASK-106 | CI (`.github/workflows/ci.yml`): add a step that runs `Scripts/make_test_fixtures.sh` after `brew install ffmpeg` so fixture-based tests run instead of skipping; keep the existing Xcode build step. | | |

## 3. Alternatives

- **ALT-001**: Make inheritable preset fields optional (`nil` = inherit) instead of adding `PresetInheritance`. Rejected: changes the type of five widely used properties and every call site; flags keep stored values intact so turning inheritance off restores the user's previous value.
- **ALT-002**: Route all video through FFmpeg and drop AVFoundation re-encoding. Rejected: FFmpeg is optional (CON-004); the native path must work on a stock Mac.
- **ALT-003**: Keep `AVAssetExportSession` and only warn that settings are ignored. Rejected: violates REQ-001/REQ-003 for the most common source formats (MP4/MOV).
- **ALT-004**: Remove the Services item and document types entirely. Rejected: Dock-icon drop and Open With are legitimate entry points; TASK-054 – TASK-057 make them predictable instead.
- **ALT-005**: Rasterize-only native PDF compression with better copy. Rejected: PDFKit's write options keep text and links; rasterizing stays available as an explicit choice.
- **ALT-006**: Keep the 100-file Finder limit and show a better message. Rejected: chunked requests (TASK-063) remove the limit without loosening IPC payload bounds.
- **ALT-007**: Persist the full live queue (including in-progress jobs) across launches. Rejected: ambiguous commit state is already handled by `ConversionJournal`; history of finished jobs (TASK-071) covers the user need.

## 4. Dependencies

- **DEP-001**: macOS 14 SDK APIs: `AVAssetReader`/`AVAssetWriter`, `AVMutableVideoComposition` color properties, `CGImageDestinationCopyTypeIdentifiers`, `CGImageSourceCreateThumbnailAtIndex`, `PDFDocumentWriteOption.saveImagesAsJPEGOption`/`.optimizeImagesForScreenOption`/`.saveTextFromOCROption` (macOS 13+), `MenuBarExtra`, `QLPreviewPanel`.
- **DEP-002**: Optional FFmpeg ≥ 6 with `libx264`, `libx265`, `libvpx-vp9`, `libsvtav1` or `libaom-av1`, VideoToolbox encoders, and the `zscale` filter (libzimg) for HDR tone mapping. Homebrew's `ffmpeg` formula includes zimg.
- **DEP-003**: Optional ImageMagick 7 with WebP delegate (for WebP output after TASK-005/TASK-006).
- **DEP-004**: Optional Ghostscript ≥ 10 for vector-preserving PDF compression.
- **DEP-005**: Test tooling: `ffmpeg`/`ffprobe` (fixtures and media assertions), optional `exiftool`.
- **DEP-006**: Phase ordering: Phase 2 depends on TASK-008 (Phase 1). TASK-041 depends on TASK-039/TASK-040. TASK-046 depends on TASK-019/TASK-022. TASK-057 and TASK-080 depend on TASK-056. TASK-069 depends on TASK-014. TASK-089 – TASK-096 depend on TASK-027 for the editor's inheritance controls.

## 5. Files

- **FILE-001**: `Sources/FileConverterCore/Formats/FormatRegistry.swift`, new `NativeImageCodecs.swift` — runtime encoder truth (TASK-005).
- **FILE-002**: `Sources/FileConverterNativeBackends/ImageIO/ImageIOBackend.swift` — encoder check, resize, alpha, location, size limits (TASK-006, TASK-044 – TASK-048).
- **FILE-003**: `Sources/FileConverterNativeBackends/AVFoundation/AVFoundationBackend.swift`, new `AVFoundationVideoTranscoder.swift` — audio writer, video transcoder, passthrough (TASK-007, TASK-038 – TASK-040).
- **FILE-004**: `Sources/FileConverterCore/Conversion/ConversionQueue.swift` — resolved settings, deferral, collisions, rejection rows, disk estimate, pause, reorder (TASK-008 – TASK-012, TASK-015, TASK-016, TASK-023, TASK-072, TASK-073).
- **FILE-005**: `Sources/FileConverterCore/Files/OutputNamingEngine.swift` — reservation error, Trash, naming context, preview, suffix (TASK-009, TASK-017, TASK-024 – TASK-026).
- **FILE-006**: `Sources/FileConverterCore/Presets/EffectivePresetResolver.swift`, `Models/ConversionPreset.swift`, `Models/ConversionJob.swift`, `Presets/PresetStore.swift`, `Presets/PresetExchange.swift`, new `Settings/ConversionDefaults.swift` — inheritance model and migration (TASK-019 – TASK-023).
- **FILE-007**: `Sources/FileConverterCore/Conversion/ConversionCoordinator.swift`, new `BackendReadinessGate.swift`, `Sources/FileConverterExternalBackends/ExternalToolDiscovery.swift` — cold start, real progress, custom tool paths (TASK-014, TASK-015, TASK-018, TASK-094).
- **FILE-008**: `Sources/FileConverterExternalBackends/FFmpeg/FFmpegBackend.swift`, `MediaProbeCache.swift`, new Core `VideoGeometry.swift`, `VideoBitrateModel.swift`, `OutputSizeEstimator.swift` — video correctness (TASK-016, TASK-032 – TASK-038).
- **FILE-009**: `Sources/FileConverterNativeBackends/PDFKit/PDFKitBackend.swift`, `Sources/FileConverterApp/UI/Dialogs/PDFCompressDialogView.swift`, `PDFSplitDialogView.swift` — PDF fixes (TASK-049 – TASK-053).
- **FILE-010**: `Sources/FileConverterCore/Presets/BuiltInPresets.swift` — preset revisions and renames (TASK-026, TASK-038, TASK-042, TASK-043, TASK-047, TASK-084).
- **FILE-011**: `Sources/FileConverterFinderSync/FileConverterFinderSync.swift`, `Sources/FileConverterFinderSupport/FinderMenuCatalog.swift`, `Sources/FileConverterContracts/FinderMenuSnapshot.swift`, `ConversionRequest.swift` — Finder menu and chunking (TASK-058 – TASK-063).
- **FILE-012**: `Sources/FileConverterApp/Info.plist`, `AppMain.swift`, new `Scripts/generate_document_types.swift` — entry points (TASK-054 – TASK-057, TASK-101).
- **FILE-013**: `Sources/FileConverterApp/UI/FileConverterMainView.swift`, `UI/Queue/ConversionQueueView.swift`, `UI/Queue/JobRowView.swift`, `UI/DropZone/DropZoneView.swift`, new `UI/DockProgressController.swift` — main window, queue, picker, Dock (TASK-010, TASK-011, TASK-013, TASK-064, TASK-069 – TASK-083, TASK-097, TASK-098).
- **FILE-014**: `Sources/FileConverterApp/Settings/*.swift` — settings panes and editor (TASK-027 – TASK-031, TASK-085 – TASK-096).
- **FILE-015**: `Sources/FileConverterApp/Resources/Localizable.xcstrings`, `Help.md`, `project.yml` — localization and help (TASK-099 – TASK-102).
- **FILE-016**: `Scripts/package_app.sh`, new `Scripts/use_build.sh`, `Scripts/make_test_fixtures.sh`, `.github/workflows/ci.yml`, `.gitignore`, `CONTRIBUTING.md` — tooling (TASK-002, TASK-103 – TASK-106).
- **FILE-017**: `Tests/FileConverterTests/Support/TestFixtures.swift`, `MediaAssertions.swift`, and new test files listed in Section 6.

## 6. Testing

- **TEST-001**: `WebPEncodingTests` — with ImageMagick present, PNG → WebP resolves to `.imageMagick` and produces a decodable WebP; with ImageMagick absent, WebP presets are not compatible and the Finder snapshot omits them (TASK-005, TASK-006).
- **TEST-002**: `ALACOutputTests` — `sine_48k_24bit.wav` with the ALAC preset produces a file whose audio format ID is `kAudioFormatAppleLossless` and bit depth 24; the AAC preset with 128 kbps yields an estimated data rate within ±15% of 128 kbps (TASK-007).
- **TEST-003**: `CollisionPolicyTests` — global Ask + built-in preset + existing output → job is `.awaitingCollision`, not `.failed`; global Skip → `.skipped` (TASK-008).
- **TEST-004**: `DestinationReservationTests` — `same_name/photo.heic` and `same_name/photo.png` with policy Replace both finish; the second waits for the first, and the first file ends up in the Trash (TASK-009, TASK-017).
- **TEST-005**: `CollisionSheetTests` — with 3 pending conflicts, resolving row 2 changes only job 2; `resolveCollisions(applyToAll: false, jobIDs: nil)` changes nothing; the coordinator holds at most one `.conflictResolution` item (TASK-010, TASK-011).
- **TEST-006**: `CollisionAttentionTests` — 5 conflicts in one batch post one activation and one notification (TASK-012).
- **TEST-007**: `QueueKeyboardTests` — Esc with 3 active jobs cancels only the selected one (TASK-013).
- **TEST-008**: `ColdStartAdmissionTests` — with an empty encoder cache and a delayed discovery stub, a Finder request for an FFmpeg preset is admitted after the gate opens; with a persisted cache it is admitted immediately; a rejected request creates a failed queue row (TASK-014, TASK-015).
- **TEST-009**: `OutputSizeEstimatorTests` — 10 s 48 kHz stereo 16-bit WAV estimate = 1 920 000 bytes ±1%; a 1 GB H.264 source → MP4 at model bitrate does not require 4 GB (TASK-016).
- **TEST-010**: `PresetMigrationV3Tests` — v2 documents migrate per TASK-020 rules; backup file written; round-trip export/import preserves `inheritance`; built-in key removal converts modified copies to custom presets (TASK-019, TASK-020, TASK-043).
- **TEST-011**: `EffectiveResolverTests` — every inheritance flag combination yields the expected value and provenance; a preset with `outputLocation = false` and `.sameAsSource` stays next to the source when global is Downloads (TASK-022).
- **TEST-012**: `NamingPreviewParityTests` — `previewFilename` equals `generateFormattedFilename` for 20 pattern/preset combinations; "MKV → MP4" sanitizes to `MKV_to_MP4`; one batch shares `{time}`; same-format suffix applied (TASK-024 – TASK-026, TASK-030).
- **TEST-013**: `TimestampPolicyTests` — creation date kept and modification date fresh by default; both toggles honored (TASK-031).
- **TEST-014**: `VideoGeometryTests` — 1080×1920 with hd1080p stays 1080×1920; 640×360 with hd720p stays 640×360; 3840×2160 with hd720p → 1280×720; odd sizes round down to even (TASK-032).
- **TEST-015**: `FFmpegOutputTests` (fixtures) — portrait clip keeps portrait dimensions; HEVC output `codec_tag_string == "hvc1"`; MP4 has `moov` before `mdat`; `multitrack.mkv` → MP4 keeps 2 audio tracks, 1 `mov_text` subtitle, chapters; HDR HLG → HEVC keeps `yuv420p10le`/`arib-std-b67`; HDR → H.264 with zscale has `color_transfer == bt709`; MKV→MP4 with H.264/AAC uses stream copy (identical video packet count and no re-encode time) (TASK-034 – TASK-038).
- **TEST-016**: `NativeTranscoderTests` (fixtures) — MP4 and "MP4 – High Quality" produce different average bitrates; 720p preset on landscape clip → 1280×720; portrait stays portrait; frame rate override honored; cancellation removes temp file (TASK-039, TASK-040, TASK-042).
- **TEST-017**: `IgnoredSettingsTests` — FFmpeg with VideoToolbox reports `.crf` ignored; editor model surfaces the note (TASK-041).
- **TEST-018**: `ImageResizeTests` — `huge_12000x10000.png` with JPEG – Web → long edge 2048 and succeeds; without resize, 120 MP converts and 300 MP throws `.imageTooLarge` (TASK-044, TASK-047, TASK-048).
- **TEST-019**: `ImageAlphaTests` — `transparent_256.png` → JPEG has pixel (0,0) ≈ white (TASK-045).
- **TEST-020**: `LocationPrivacyTests` — `gps.jpg` → JPEG has no GPS dictionary by default and keeps it when the setting is off; FFmpeg and native video outputs carry no ISO 6709 tag by default (TASK-046).
- **TEST-021**: `PDFRenderTests` — `text_links_outline.pdf` → PNG at 300 DPI has crop-box pixel size; native compress output has extractable text (`PDFDocument.string` non-empty), 1 link annotation, 1 outline item; a compress that does not shrink ends `.skipped` and leaves no output (TASK-049 – TASK-051).
- **TEST-022**: `FinderMenuTests` (FinderSupport) — folders and unsupported files yield no menu; single-section selections are flattened; 3-of-5 compatible selection yields "(3 of 5 files)" titles; identity presets hidden; video selection groups audio presets under "Extract Audio" (TASK-058 – TASK-062).
- **TEST-023**: `RequestChunkingTests` — 250 selected files produce 3 requests with one `groupID` and one queue batch; mismatched edition or >5 s gap is not merged (TASK-063, SEC-003).
- **TEST-024**: `PresetUsageStoreTests` and `OpenWithBehaviorTests` — last preset per format recorded; "Convert right away" mode enqueues without a sheet; falls back to the picker when no compatible last preset exists (TASK-056, TASK-057).
- **TEST-025**: `NotificationPolicyTests` — one notification per batch; no "Started" notification; Dock badge counts active + queued and shows "!" after a failure (TASK-064, TASK-067).
- **TEST-026**: `QueueInteractionTests` — pause blocks new starts; reorder changes start order; multi-delete removes only finished rows; history survives reload; "Retry All Failed" retries all (TASK-070 – TASK-074, TASK-078).
- **TEST-027**: `DocumentTypesTests` — `Info.plist` `LSItemContentTypes` equals the generated supported-input UTI list and contains neither `public.item` nor `public.data` (TASK-054).
- **TEST-028**: `AccessibilityAuditTests` and `ArchitectureBoundaryTests` updated for new views and files; `LocalizationTests` asserts no user-visible string literal is built with plural concatenation (grep-based) (TASK-089, TASK-099).
- **TEST-029**: Manual checklist per phase PR: right-click convert from a local folder and from an iCloud Drive folder (records whether Finder shows the extension menu there), Open With and Services paths, Dock progress with the window closed, RTL screenshots, Settings snapshots in light/dark.

## 7. Risks & Assumptions

- **RISK-001**: `AVAssetWriter` transcoding (TASK-039) is the largest change and can regress edge cases (variable frame rate, edit lists, odd pixel formats). Mitigation: keep passthrough via export session, fixture tests for each sample, and a hidden fallback default `fc.useLegacyExportSession` for one release.
- **RISK-002**: The v3 migration changes stored presets. Mitigation: backup before migrating, rules chosen to preserve current effective behavior, TEST-010.
- **RISK-003**: `PDFDocumentWriteOption` compression results vary by document; some PDFs may not shrink. Mitigation: TASK-051 never ships a larger file; Ghostscript remains the stronger option.
- **RISK-004**: Finder Sync menus may not appear inside iCloud Drive or third-party File Provider folders (unverified). Mitigation: TEST-029 records actual behavior; TASK-054 – TASK-057 make the Services/Open With fallback predictable either way.
- **RISK-005**: HDR tone mapping depends on FFmpeg's `zscale`; without it, colors shift. Mitigation: explicit warning (TASK-037) and native path tone mapping (TASK-039).
- **RISK-006**: Changing defaults (notifications on, modification date not preserved, location removed) changes behavior for existing users. Mitigation: migrations keep explicit user choices; only unset/default values change; release notes list each default change.
- **RISK-007**: Localization (TASK-099) touches most UI files and conflicts with concurrent UI work. Mitigation: schedule after Phases 7–10 merge.
- **ASSUMPTION-001**: Product decisions taken as defaults in this plan, to be confirmed by the owner before the matching phase starts: notifications on for new installs (TASK-066); menu bar extra on (TASK-065); modification date not preserved by default (TASK-031); location removed by default (TASK-046); Open With/Services default "Ask, with last choice selected" (TASK-057); new Finder ceiling 1 000 files (TASK-063).
- **ASSUMPTION-002**: ISS-52 (black background on PNG → JPEG) is unverified; TASK-045 starts with a reproduction test.
- **ASSUMPTION-003**: The audit criticism of the magnifying-glass reveal icon was wrong (it matches Safari's Downloads list); TASK-076 keeps it.

## 8. Related Specifications / Further Reading

- `plan/refactor-file-converter-reliability-1.md` — previous reliability/hardening plan (collision plans, journal, IPC) this plan builds on.
- `plan/release-decision-record.md` — release record for the previous plan.
- `ARCHITECTURE.md`, `CONTRIBUTING.md`, `SECURITY.md` — module boundaries and contribution rules.
- Apple: AVFoundation "Exporting HDR video" and `AVAssetWriter` documentation; PDFKit `PDFDocumentWriteOption`; ImageIO `CGImageSourceCreateThumbnailAtIndex`; FinderSync `FIFinderSyncController`.
- FFmpeg documentation: `zscale`/`tonemap` filters, `-movflags +faststart`, `-tag:v hvc1`, `-map` stream selection.
