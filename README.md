# File Converter for macOS

<p align="center">
  <img src="Sources/FileConverterApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="File Converter app icon" width="160">
</p>

> Convert a file from Finder, or queue a batch.

File Converter is a macOS app for converting photos, video, audio, PDFs, office documents, and eBooks. Select a file in Finder or drop it into the app, choose a recipe, and the result is written locally. There is no upload step or shell command to remember.

The app filters recipes by source type, destination encoder, and installed tools. If a conversion cannot run on this Mac, it is not shown in the Finder menu.

## What it does

From Finder:

- Select one file or a batch in Finder.
- Choose a plain-language recipe such as `HEIC → JPEG`, `PDF → PNG`, or `MOV → MP4`.
- The queue tracks progress, cancellation, naming, conflicts, and completion notifications.
- Outputs go beside the original by default, or to Downloads, a subfolder, or a bookmarked destination.

The SwiftUI app exposes the same queue for drag-and-drop input, preset editing, and backend diagnostics.

## Finder, Apple frameworks, and optional tools

- Finder integration: The `File Converter` submenu appears for supported selections. For a batch, the menu contains only recipes compatible with every selected file.
- Apple frameworks: AVFoundation/VideoToolbox, ImageIO, and PDFKit handle the native paths.
- Optional backends: FFmpeg, ImageMagick, LibreOffice, Ghostscript, and Calibre are discovered when installed. Their recipes remain unavailable until the required executable is present. FFmpeg recipes also require a reported encoder for the requested job.
- Preset editor: Start with a source and destination recipe, then set quality, codecs, output, and naming options.
- Defaults: Outputs use the source directory, preserve metadata and creation dates, and append a number instead of overwriting an existing file.
- Queue: Batch progress, cancellation, multi-output jobs, and conflicts are handled in one place.
- Local processing: The app has no telemetry, analytics, updater, or network conversion service. It does not request Full Disk Access.
- macOS support: macOS 26 UI behavior is used when available. The deployment target is macOS 14.

## Use it from Finder

1. Launch File Converter once after installing it.
2. Open **System Settings → General → Login Items & Extensions → Extensions** and enable **File Converter**.
3. Right-click a supported file or select several files in Finder.
4. Choose **File Converter**, then choose a recipe.
5. File Converter adds the job to the queue. Completed outputs can be revealed automatically.

## Use it from the app

Drop files onto the main window, or choose **Add Files...**. File Converter detects the input type, presents compatible presets, and adds the work to the same queue used by Finder.

## Built-in recipes

The library contains broad format presets and explicit source-to-destination recipes. The explicit recipes put common pairs in the Finder menu.

| Use case | Built-in recipes |
| --- | --- |
| iPhone photo sharing | `HEIC → JPEG`, `HEIC → PNG`, `HEIC → WebP` |
| Web images | `PNG → JPEG`, `WebP → JPEG`, JPEG web optimization, WebP, AVIF |
| Lossless or camera images | PNG, TIFF, WebP lossless, HEIC, RAW → JPEG |
| Artwork files | `SVG → PNG`, `PSD → PNG`, ICNS, ICO |
| PDF page extraction | `PDF → PNG`, `PDF → JPEG`, `PDF → TIFF`, or split a PDF into individual pages |
| PDF compression | **Compress PDF** with Ghostscript when installed |
| Video output | MP4 balanced, 720p MP4, 1080p MP4, smaller MP4, HEVC |
| Video containers | `MOV → MP4`, `MKV → MP4`, MOV, MKV, WebM, AV1 |
| Audio output | MP3 at 128/192/320 kbps, AAC/M4A, ALAC, WAV, AIFF, FLAC, Opus, OGG |
| Audio splitting and size limits | Split audio into five-minute MP3 files or target a file size of 5 MB |
| Office documents | `DOCX → PDF`, `XLSX → PDF`, `PPTX → PDF`, `DOCX → ODT`, `XLSX → CSV`, `CSV → XLSX` |
| eBooks | `EPUB → PDF` with Calibre when installed |

The app does not list every pair on every Mac. Before adding a recipe to the picker or Finder menu, it checks the source, destination, native encoder, external tool, and, for FFmpeg, the reported encoder set.

## Supported formats

The registry recognizes the following families. A format can be a valid input, output, or both. The app checks the direction at runtime.

| Family | Recognized formats |
| --- | --- |
| **Video** | MP4/M4V, MOV/QT, MKV, WebM, AVI, MPG/MPEG/M2V/TS/MTS/M2TS, FLV, WMV/ASF |
| **Audio** | MP3, AAC, M4A/M4B, FLAC, WAV/WAVE, AIFF/AIF, Opus, OGG/OGA, WMA, QTA |
| **Images** | PNG, JPEG/JPG/JPE, HEIC/HEIF, WebP, AVIF, TIFF/TIF, GIF, BMP/DIB, SVG, camera RAW (DNG/CR2/CR3/NEF/ARW/ORF/RW2/PEF), PSD, ICNS, ICO |
| **Documents** | PDF, DOCX/DOC, ODT, RTF/RTFD, TXT/TEXT, HTML/HTM, EPUB, XLSX/XLS, CSV, PPTX/PPT, ODS, ODP, Pages, Numbers, Keynote/KEY |

Native support comes from Apple frameworks. Optional backends extend the matrix:

| Backend | What it adds | Install |
| --- | --- | --- |
| **FFmpeg** | MKV/WebM/AV1/VP9 video, MP3/FLAC/Opus/OGG audio, splitting, file-size targets, and other codec/container combinations | `brew install ffmpeg` |
| **ImageMagick** | SVG, PSD, ICO, and additional image codecs | `brew install imagemagick` |
| **LibreOffice** | DOC/DOCX, XLS/XLSX, PPT/PPTX, ODF, CSV, and other office-document conversions | `brew install --cask libreoffice` |
| **Ghostscript** | PDF recompression profiles | `brew install ghostscript` |
| **Calibre** | EPUB → PDF using its eBook renderer | `brew install --cask calibre` |

File Converter checks common Homebrew paths, `PATH`, and standard application locations. Open **Settings → External Tools** to see what is installed, copy the exact install command, or run a fresh scan.

## Output rules

- Destination: same directory as the original by default. Downloads, a source subfolder, or a security-scoped custom folder are also supported.
- Naming: `{name}` by default, with per-preset filename patterns.
- Collisions: append a number, overwrite, replace only if newer, skip, or ask once for the whole batch.
- Metadata: EXIF, ICC profiles, and other supported metadata are preserved by default. Creation and modification dates can be preserved as well.
- Multi-output jobs: PDF pages use deterministic names such as `page-001`, `page-002`, and audio splitting uses numbered `part` outputs.
- Atomic completion: backends write to an isolated temporary output and commit only after validation. A failed conversion does not leave a half-written destination.

## Edit presets

Open **Settings → Presets** to:

- Start with a source family and destination format.
- Give it a readable name and a short Finder menu label.
- Choose quality, codecs, resolution, frame rate, audio settings, metadata behavior, output destination, filename pattern, and collision policy.
- See a live filename preview and backend availability before saving.
- Edit, disable, restore, export, import, or delete presets without losing the built-in catalog.

Built-in presets can be edited without changing their identity. New built-ins are merged into existing preset documents without erasing your choices.

## Install locally

This repository builds a local macOS app bundle. From the checkout root:

```bash
./Scripts/package_app.sh Release
open "dist/File Converter.app"
```

The package script archives the host app and embedded Finder extension, copies the app and matching dSYM into `dist/`, and applies a local Apple Development signature when one is available (otherwise it uses ad-hoc signing). It does not notarize, publish, register the copied bundle, or enable the Finder extension for you.

After moving `dist/File Converter.app` to `/Applications`, complete the Finder setup above. If the menu is still missing, open the app once, use **Settings → Finder → Check Setup**, confirm the extension is enabled, and relaunch Finder from that pane.

## Build and test

Requirements:

- macOS 14.0 or newer.
- A Swift 5.10-compatible toolchain for Swift Package Manager. The Xcode project is configured for Swift 6.0.
- Xcode for the app and Finder extension targets.
- XcodeGen only when regenerating `FileConverter.xcodeproj` from `project.yml`.
- Homebrew only for the optional external tools listed above.

Useful commands:

```bash
# Build the Swift package targets
swift build

# Run the package and Finder-support test targets
swift test

# Regenerate the Xcode project after changing project.yml
xcodegen generate

# Build the local app target
xcodebuild -project FileConverter.xcodeproj \
  -scheme FileConverter \
  -configuration Debug \
  build

# Produce the app bundle and dSYM in dist/
./Scripts/package_app.sh Release
```

## Architecture

```text
Finder Sync extension
        │  capability-filtered menu + authenticated request
        ▼
File Converter.app
        │  validation → backend resolution → queue
        ├── Apple: AVFoundation / VideoToolbox
        ├── Apple: ImageIO
        ├── Apple: PDFKit
        └── Optional: FFmpeg / ImageMagick / LibreOffice / Ghostscript / Calibre
        │
        ▼
isolated temporary output → validated atomic commit → destination file
```

The Finder extension reads a menu snapshot and sends an authenticated request. The host app stores presets, evaluates capabilities, manages security-scoped access, runs the queue and backends, and commits outputs. See [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries and [SECURITY.md](SECURITY.md) for the local file-access and IPC model.

## Privacy and file access

Files enter through Finder selections, the open panel, or drag and drop.

- The app does not request Full Disk Access.
- Finder passes security-scoped bookmarks rather than granting the host authority over arbitrary paths.
- External tools receive discrete arguments. Paths are not interpolated through a shell.
- No file contents, bookmarks, IPC keys, or HMAC material are sent to a network service.

For the implementation details, threat boundaries, and subprocess safeguards, read [SECURITY.md](SECURITY.md).

## Troubleshooting

**The Finder menu does not appear**

Launch the app once, enable the extension under **System Settings → General → Login Items & Extensions → Extensions**, then use **Settings → Finder → Check Setup**. The app can relaunch Finder after the extension is enabled.

**A recipe is missing**

The selected file cannot use that recipe right now. Check **Settings → External Tools**, refresh discovery, or choose a native recipe. Settings keeps unavailable presets visible and identifies the missing dependency.

**A batch stops at a conflict**

When the preset uses **Ask**, the queue pauses before changing any existing output. Choose Replace, Keep Both, Skip, or Apply to All from the batch conflict sheet.

**A conversion fails**

Open the failed queue row for the technical error, verify the source can be opened by its backend, and check that the destination folder is writable. For optional backends, refresh the tool scan and confirm the required encoder is installed.

## Project documents

- [Architecture](ARCHITECTURE.md)
- [Security and privacy model](SECURITY.md)
- [Swift package manifest](Package.swift)
- [XcodeGen project definition](project.yml)
- [Local packaging script](Scripts/package_app.sh)
