# File Converter for macOS

A production-quality, native macOS file conversion utility that integrates directly into your Finder right-click context menu. Converts video, audio, image, and document formats with native Apple Silicon hardware acceleration, intelligent batch concurrency, and zero external runtime requirements for base functionality.

Inspired by the workflow and usability of **Tichau/FileConverter** and **AlexDevFlow/Media-Converter**, architected clean-room from the ground up specifically for modern macOS.

---

## Key Features

- **Finder Context Menu**: Right-click one or multiple files in Finder to reveal the `File Converter >` submenu, dynamically filtered to show only presets compatible with all selected files.
- **Native-First Engine**: Immediate conversions out of the box using Apple's high-performance frameworks (`AVFoundation`, `VideoToolbox`, `ImageIO`, `Core Image`, `PDFKit`, `AudioToolbox`).
- **Apple Silicon Hardware Acceleration**: Leverages hardware encoders for H.264, HEVC (H.265), and Apple ProRes.
- **Zero Full Disk Access Required**: Fully sandboxed with App Group IPC and user-selected security-scoped file access.
- **Intelligent Concurrency Queue**: Automatically balances CPU/GPU concurrency according to core count and thermal throttling states (`ProcessInfo.thermalState`).
- **Collision Management**: Configurable filename collision handling (e.g. `video (1).mp4`, overwrite, replace if newer, skip).
- **Metadata & Timestamp Preservation**: Preserves EXIF, ICC color profiles, creation dates, and modification dates.
- **Optional CLI Enhancement**: Automatically detects and leverages `ffmpeg`, `imagemagick`, `ghostscript`, and `libreoffice` if installed via Homebrew.
- **SwiftUI Management Interface**: Compact queue progress window, drag-and-drop zone, and a comprehensive preset editor.
- **100% Offline & Private**: Zero telemetry, zero analytics, zero network requests.

---

## Supported Format Matrix

### Video
- **Input**: MP4, MOV, M4V, MKV, WebM, AVI, MPG, MPEG, TS, MTS, M2TS, FLV, WMV
- **Output**: MP4 (H.264 / HEVC / AV1), MOV (ProRes / H.264), MKV, WebM (VP9 / Opus), Animated GIF
- **Hardware Acceleration**: VideoToolbox hardware encoding on Apple Silicon and modern Intel Macs.

### Audio
- **Input**: MP3, M4A, AAC, WAV, AIFF, FLAC, OGG, Opus, WMA, M4B, QTA (QuickTime Audio)
- **Output**: MP3 (320 kbps), AAC (256 kbps), M4A, ALAC (Apple Lossless), FLAC, WAV, AIFF, Opus, OGG, QTA (QuickTime Audio)

### Images
- **Input**: PNG, JPEG, HEIC/HEIF, WebP, AVIF, TIFF, GIF, BMP, SVG, DNG/RAW, PSD, ICNS, ICO
- **Output**: JPEG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, ICNS, ICO

### Documents
- **Input/Output**: PDF, DOCX, TXT, RTF, HTML, EPUB, XLSX, CSV, PPTX
- **Native Operations**: Image-to-PDF, PDF-to-Image extraction, Plain Text & RTF to PDF rendering.

---

## Quick Start & Installation

### Requirements
- macOS 14.0 (Sonoma) or newer (macOS 15 Sequoia / macOS 27 compatible)
- Xcode 15.0+ or Swift 5.10+ toolchain

### Building from Source

```bash
# Clone repository
git clone https://github.com/your-org/FileConverter.git
cd FileConverter

# Build package via Swift Package Manager
swift build

# Run unit and integration test suite (25 tests)
swift test

# Build & package the native macOS Application bundle (.app):
./Scripts/package_app.sh
```

The packaged application bundle will be created at `dist/File Converter.app` containing the embedded `FileConverterFinderSync.appex` extension.

### Enabling Finder Integration
1. Open **System Settings** on your Mac.
2. Go to **Privacy & Security** > **Extensions**.
3. Under **Added Extensions**, enable **File Converter**.
4. Right-click any supported media or document file in Finder!

---

## Optional External Tools

To extend support for container formats like `.mkv`, `.webm`, or Microsoft Office files:

```bash
# For extended video/audio codecs (MKV, WebM, VP9, AV1, Opus):
brew install ffmpeg

# For legacy & exotic image formats:
brew install imagemagick

# For document formats (DOCX, XLSX, PPTX):
brew install --cask libreoffice

# For advanced PDF optimization:
brew install ghostscript
```

---

## License

Clean-room implementation licensed under the MIT License.
