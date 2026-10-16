# File Converter Help

File Converter changes files from one format to another on your Mac. Nothing is uploaded.

## Converting files

- **From Finder:** select one or more files, right-click, and choose **File Converter**, then a preset. Conversion starts right away; progress shows on the Dock icon and in the menu bar.
- **From the window:** drop files on the File Converter window or click **Choose Files…**, pick a preset, and click **Convert** (or press Return).
- **Open With, Services, and the Dock icon:** these show the preset picker with your last choice for that file type selected. In **Settings › General › Opening Files** you can make them convert right away instead.

The Finder menu only lists presets that fit the selected files. When some of the selected files fit a preset and others don't, the preset shows “(3 of 5 files)” and converts only those.

## Where converted files go

By default, next to the original. Change this in **Settings › General › Saving**, or per preset. A preset either uses the General setting or its own value; the preset editor shows which.

When a file with the same name already exists, File Converter adds a number, asks, skips, or replaces — your choice in General settings. Replaced files are moved to the Trash, so you can get them back.

## The queue

- Select files and press **Space** for Quick Look, **⌘↓** to open them, **⌘R** to show them in Finder, **Delete** to remove finished rows, or **Esc** to cancel them (File Converter asks first).
- Drag a finished file from the list into another app or a Finder window.
- Double-click a finished file to open it.
- Drag waiting files to change their order. **Conversion › Pause Queue** (⌥⌘P) finishes the current files and waits.
- Earlier batches are kept under **Earlier**, even after you quit. A failed, skipped, or cancelled file there can be converted again with the same preset.
- Quitting while files are converting asks first; unfinished files show up under **Earlier** as cancelled.

## Presets

Built-in presets can be changed, hidden from menus, and restored to their factory settings. Create your own with **+** in **Settings › Presets**. Export presets to share them; importing asks what to do about presets with the same name.

Settings that a preset cannot use for some files (for example a CRF value when Apple's encoder converts MP4 files) are marked in the editor.

## Privacy

Location (GPS) is removed from converted photos and videos unless you turn this off in General settings or in a preset. Turning off **Preserve metadata and tags** in a preset removes all camera and author details.

## Optional tools

FFmpeg, ImageMagick, Ghostscript, LibreOffice, and Calibre add formats such as MKV, WebM, MP3, WebP, Office documents, and EPUB. Install them with Homebrew; **Settings › External Tools** shows what was found and lets you point to a tool installed elsewhere.

## Compressing PDFs

Without Ghostscript, File Converter shrinks the images inside the PDF and keeps text, links, and bookmarks. **Turn pages into images** gives the smallest file; text is recognized on your Mac so the PDF stays searchable. If the result would not be smaller, nothing is saved.

## If the Finder menu is missing

Open **Settings › Finder** and follow the steps there. The extension must be turned on in **System Settings › General › Login Items & Extensions**. If you have more than one copy of File Converter, only one of them provides the Finder menu.
