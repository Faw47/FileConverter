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
