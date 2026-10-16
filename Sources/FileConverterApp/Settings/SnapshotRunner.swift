#if DEBUG
import AppKit
import FileConverterCore
import FileConverterExternalBackends
import SwiftUI

@MainActor
public enum SnapshotRunner {
    public static func run(outputDirectory: String) {
        let fileManager = FileManager.default
        let outURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? fileManager.createDirectory(at: outURL, withIntermediateDirectories: true)

        ExternalToolDiscovery.shared.refreshAllTools(force: true)

        let tabs = AppState.SettingsTab.allCases
        let appearances: [(String, NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        print("==> Starting Settings Visual Test Snapshots into: \(outputDirectory)")

        for (modeName, appearanceName) in appearances {
            for tab in tabs {
                let tabName = tab.rawValue.replacingOccurrences(of: " ", with: "_").lowercased()
                let fileName = "settings_\(tabName)_\(modeName).png"
                let fileURL = outURL.appendingPathComponent(fileName)

                let appState = AppState.shared
                appState.selectedTab = tab

                let window = NSWindow(
                    contentRect: NSRect(x: 100, y: 100, width: 920, height: 620),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.appearance = NSAppearance(named: appearanceName)
                window.title = "File Converter Settings"
                window.titleVisibility = .hidden

                let hostingView = NSHostingView(
                    rootView: SettingsView()
                        .environmentObject(appState)
                )
                hostingView.frame = NSRect(x: 0, y: 0, width: 920, height: 620)
                window.contentView = hostingView
                window.makeKeyAndOrderFront(nil)

                // Allow runloop to perform layout
                RunLoop.current.run(until: Date().addingTimeInterval(0.35))

                // Render view to image (captures full window with titlebar)
                let targetView = window.contentView?.superview ?? hostingView
                if let bitmapRep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) {
                    targetView.cacheDisplay(in: targetView.bounds, to: bitmapRep)
                    if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                        do {
                            try pngData.write(to: fileURL)
                            print("  [✓] Saved: \(fileName) (\(pngData.count) bytes)")
                        } catch {
                            print("  [✗] Failed to write \(fileName): \(error)")
                        }
                    }
                }

                window.orderOut(nil)
            }
        }

        snap("help", size: CGSize(width: 620, height: 900), appearances: appearances, to: outURL) { HelpView() }
        snap("main_empty", size: CGSize(width: 640, height: 500), appearances: appearances, to: outURL) {
            FileConverterMainView().environmentObject(AppState.shared)
        }
        snap("menubar", size: CGSize(width: 300, height: 260), appearances: appearances, to: outURL) {
            MenuBarStatusView(queue: ConversionQueue.shared)
        }

        // Dialogs need real files: --snapshot-files a.pdf,b.jpg,...
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-files"), idx + 1 < CommandLine.arguments.count {
            let urls = CommandLine.arguments[idx + 1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            let presets = PresetStore.shared.presets
            snap("picker", size: CGSize(width: 720, height: 560), appearances: appearances, to: outURL) {
                PresetPickerView(urls: urls, excludedCount: 0, pendingBatches: 0, onCancel: {}, onConvert: { _ in }, onManagePresets: {})
            }
            if !pdfs.isEmpty {
                if let compress = presets.first(where: { $0.menuName == "Compress PDF" }) {
                    snap("pdf_compress", size: CGSize(width: 640, height: 720), appearances: appearances, to: outURL) {
                        PDFCompressDialogView(urls: pdfs, initialPreset: compress, onCancel: {}, onStart: { (_: ConversionPreset) in })
                    }
                }
                if let split = presets.first(where: { $0.menuName == "Split PDF" }) {
                    snap("pdf_split", size: CGSize(width: 820, height: 760), appearances: appearances, to: outURL) {
                        PDFSplitDialogView(urls: pdfs, initialPreset: split, onCancel: {}, onStart: { (_: ConversionPreset) in })
                    }
                }
            }
            if let photo = urls.first(where: { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }) {
                snap("picker_single", size: CGSize(width: 720, height: 560), appearances: appearances, to: outURL) {
                    PresetPickerView(urls: [photo], excludedCount: 0, pendingBatches: 0, onCancel: {}, onConvert: { _ in }, onManagePresets: {})
                }
            }
            if let video = presets.first(where: { $0.destinationFormat == "mp4" }), let source = urls.first {
                let started = Date().addingTimeInterval(-42)
                let jobs: [ConversionJob] = [
                    ConversionJob(sourceURL: source, preset: video, state: .converting,
                                  progress: ConversionProgress(fractionCompleted: 0.4), startedAt: started),
                    ConversionJob(sourceURL: source, preset: video, state: .queued),
                    ConversionJob(sourceURL: source, preset: video, state: .completed, startedAt: started, finishedAt: Date()),
                    ConversionJob(sourceURL: source, preset: video, state: .completedWithWarnings(["Colors may look different"])),
                    ConversionJob(sourceURL: source, preset: video, state: .failed(.dependencyMissing(dependencyName: "FFmpeg", installCommand: "brew install ffmpeg"))),
                    ConversionJob(sourceURL: source, preset: video, state: .skipped("A file with that name exists")),
                    ConversionJob(sourceURL: source, preset: video, state: .cancelled),
                    // From an earlier launch: with its preset, and an older record without one.
                    {
                        var job = ConversionJob(sourceURL: source, preset: video, state: .failed(.fileNotFound(path: source.path)))
                        job.isFromHistory = true
                        job.hasRestoredPreset = true
                        return job
                    }(),
                    {
                        var job = ConversionJob(sourceURL: source, preset: video, state: .cancelled)
                        job.isFromHistory = true
                        return job
                    }(),
                ]
                snap("queue_rows", size: CGSize(width: 640, height: 560), appearances: appearances, to: outURL) {
                    List(jobs) { JobRowView(job: $0) }.listStyle(.inset)
                }
                // The main window with rows (finished ones only, so nothing
                // runs and nothing is saved); the queue is put back after.
                let realJobs = ConversionQueue.shared.jobs
                ConversionQueue.shared.setJobsForTesting(jobs.filter(\.state.isTerminal))
                snap("main_queue", size: CGSize(width: 640, height: 500), appearances: appearances, to: outURL) {
                    FileConverterMainView().environmentObject(AppState.shared)
                }
                ConversionQueue.shared.setJobsForTesting(realJobs)
            }
            snap("new_preset", size: CGSize(width: 640, height: 620), appearances: appearances, to: outURL) {
                NewPresetWizardView { _ in }
            }
            if let fit = presets.first(where: { $0.builtInKey == "video.fit-10mb" }) {
                snap("preset_editor_fit", size: CGSize(width: 640, height: 1200), appearances: appearances, to: outURL) {
                    PresetEditorView(presetID: fit.id, onSaved: {}, onDeleted: {}, onDirtyChange: { _ in })
                }
            }
            if let preset = presets.first(where: { $0.destinationFormat == "mp4" }) ?? presets.first {
                snap("preset_editor", size: CGSize(width: 640, height: 1500), appearances: appearances, to: outURL) {
                    PresetEditorView(presetID: preset.id, onSaved: {}, onDeleted: {}, onDirtyChange: { _ in })
                }
            }
        }

        print("==> Visual Test Snapshots Complete!")
        exit(0)
    }
    private static func snap<V: View>(
        _ name: String,
        size: CGSize,
        appearances: [(String, NSAppearance.Name)],
        to outURL: URL,
        @ViewBuilder _ view: () -> V
    ) {
        for (modeName, appearanceName) in appearances {
            let fileName = "\(name)_\(modeName).png"
            let window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearanceName)
            window.title = name
            let hostingView = NSHostingView(rootView: view())
            hostingView.frame = NSRect(origin: .zero, size: size)
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let targetView = window.contentView?.superview ?? hostingView
            if let bitmapRep = targetView.bitmapImageRepForCachingDisplay(in: targetView.bounds) {
                targetView.cacheDisplay(in: targetView.bounds, to: bitmapRep)
                if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: outURL.appendingPathComponent(fileName))
                    print("  [✓] Saved: \(fileName)")
                }
            }
            window.orderOut(nil)
        }
    }
}
#endif

#if DEBUG
/// Captures the Settings window the app actually shows, which the hosted
/// snapshots above cannot reproduce (toolbar tabs, window chrome).
@MainActor
enum SettingsSceneCapture {
    /// CGWindowListCreateImage is unavailable to Swift in current SDKs but
    /// still works for an app's own windows; looked up at run time.
    private static func composited(windowNumber: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .null rect = the window's bounds; option 8 = including window;
        // image options: bestResolution (8) | boundsIgnoreFraming (1).
        return create(.null, 8, UInt32(windowNumber), 8 | 1)?.takeRetainedValue()
    }

    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // The app menu's "Settings…" item, as a user would choose it.
            if let appMenu = NSApp.mainMenu?.items.first?.submenu,
               let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                appMenu.performActionForItem(at: index)
            }
            try? await Task.sleep(for: .seconds(1.5))
            for window in NSApp.windows {
                print("[capture] window \(type(of: window)) id=\(window.identifier?.rawValue ?? "-") visible=\(window.isVisible) frame=\(window.frame)")
            }
            guard let window = NSApp.windows.first(where: AppDelegate.isSettingsWindow) else {
                print("[capture] no Settings window; windows: \(NSApp.windows.map { $0.identifier?.rawValue ?? "?" })")
                exit(1)
            }
            for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: name)
                for tab in AppState.SettingsTab.allCases {
                    AppState.shared.selectedTab = tab
                    try? await Task.sleep(for: .seconds(0.8))
                    let file = outputDirectory.appendingPathComponent("scene_\(tab.rawValue.replacingOccurrences(of: " ", with: "_").lowercased())_\(mode).png")
                    // What the window server shows, including translucent
                    // toolbar materials that cacheDisplay does not draw.
                    if let image = composited(windowNumber: window.windowNumber) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
                        print("[capture] \(file.lastPathComponent) \(image.width)x\(image.height) (window server)")
                    } else {
                        print("[capture] window server image unavailable")
                    }
                }
            }
            exit(0)
        }
    }
}
#endif
