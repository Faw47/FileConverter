import AppKit
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

        print("==> Visual Test Snapshots Complete!")
        exit(0)
    }
}
