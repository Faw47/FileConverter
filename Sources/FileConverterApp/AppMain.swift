import SwiftUI
import AppKit
import FileConverterContracts
import FileConverterCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateApp),
            name: NSNotification.Name("FileConverterActivateApp"),
            object: nil
        )
    }

    @objc private func handleActivateApp() {
        isHeadlessBackgroundLaunch = false
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.canBecomeMain || window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                if window.isMiniaturized {
                    window.deminiaturize(self)
                    window.makeKeyAndOrderFront(self)
                    return true
                }
                if window.canBecomeMain || window.isKeyWindow {
                    window.makeKeyAndOrderFront(self)
                    return true
                }
            }
        }
        return true
    }

    private var isHeadlessBackgroundLaunch = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fileURLs = urls.filter(\.isFileURL)
        let customURLs = urls.filter { !$0.isFileURL }

        let shouldActivate = !fileURLs.isEmpty || customURLs.contains { url in
            url.host == "settings"
        }
        if shouldActivate {
            isHeadlessBackgroundLaunch = false
            NSApp.activate(ignoringOtherApps: true)
        } else {
            isHeadlessBackgroundLaunch = true
            DispatchQueue.main.async {
                if self.isHeadlessBackgroundLaunch {
                    for window in NSApplication.shared.windows {
                        window.orderOut(nil)
                    }
                }
            }
        }

        for url in customURLs {
            NotificationCenter.default.post(
                name: NSNotification.Name("HandleIncomingURL"),
                object: nil,
                userInfo: ["url": url]
            )
        }

        if !fileURLs.isEmpty {
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenFileConverterPresetPicker"),
                object: nil,
                userInfo: ["urls": fileURLs]
            )
        }
    }

    @objc func openFilesFromService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let items = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !items.isEmpty else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(
            name: NSNotification.Name("OpenFileConverterPresetPicker"),
            object: nil,
            userInfo: ["urls": items]
        )
    }
}

@main
struct FileConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var conversionQueue = ConversionQueue.shared

    init() {
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), idx + 1 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[idx + 1]
            SnapshotRunner.run(outputDirectory: outDir)
        }
    }

    var body: some Scene {
        WindowGroup {
            FileConverterMainView()
                .environmentObject(appState)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HandleIncomingURL"))) { note in
                    if let url = note.userInfo?["url"] as? URL {
                        handleIncomingURL(url)
                    }
                }
        }
        .defaultSize(width: 600, height: 480)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Files to Convert...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenFileConverterOpenPanel"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Clear Completed") {
                    ConversionQueue.shared.clearCompleted()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(
                    conversionQueue.completedCount == 0
                        && conversionQueue.failedCount == 0
                        && conversionQueue.skippedCount == 0
                        && conversionQueue.cancelledCount == 0
                )

                Button("Cancel All Active") {
                    ConversionQueue.shared.cancelAll()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(conversionQueue.cancelableCount == 0)
            }

            CommandMenu("Conversion") {
                Button("Retry Failed Conversions") {
                    let failedJobs = ConversionQueue.shared.jobs.filter {
                        if case .failed = $0.state { return true }; return false
                    }
                    for job in failedJobs {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!conversionQueue.jobs.contains { if case .failed = $0.state { return true }; return false })

                Divider()

                Button("Manage Presets...") {
                    appState.openSettings(tab: .presets)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("External Tools Diagnostics...") {
                    appState.openSettings(tab: .externalTools)
                }
            }

            CommandGroup(replacing: .help) {
                Button("File Converter Documentation") {
                    let helpURL = Bundle.main.url(forResource: "Help", withExtension: "html")
                    if let helpURL { NSWorkspace.shared.open(helpURL) }
                }
                Button("Finder Integration Setup Guide") {
                    appState.openSettings(tab: .finder)
                }
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        let configuredScheme = try? IPCConfiguration.current().urlScheme
        if url.scheme == configuredScheme {
            if url.host == "settings" {
                NSApp.activate(ignoringOtherApps: true)
                let tab: AppState.SettingsTab? = {
                    guard let tabName = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "tab" })?.value else { return nil }
                    let query = tabName.lowercased()
                    if query.contains("preset") { return .presets }
                    if query.contains("tool") || query.contains("external") || query.contains("ffmpeg") { return .externalTools }
                    if query.contains("perform") || query.contains("thermal") || query.contains("cpu") { return .performance }
                    if query.contains("finder") || query.contains("menu") || query.contains("extension") { return .finder }
                    if query.contains("general") || query.contains("output") || query.contains("default") { return .general }
                    return AppState.SettingsTab.allCases.first {
                        $0.rawValue.caseInsensitiveCompare(tabName) == .orderedSame
                    }
                }()
                appState.openSettings(tab: tab)
            } else {
                Task {
                    await appState.drainFinderRequestsWhenReady()
                }
            }
        } else if url.isFileURL {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenFileConverterPresetPicker"),
                object: nil,
                userInfo: ["urls": [url]]
            )
        }
    }
}
