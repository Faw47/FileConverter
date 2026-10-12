import SwiftUI
import AppKit
import FileConverterContracts
import FileConverterCore
import UserNotifications
import os

@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()
    weak var mainWindow: NSWindow?
}

@MainActor
final class URLDeduplicator {
    static let shared = URLDeduplicator()
    private var recentlyHandled: [URL: Date] = [:]

    func shouldProcess(_ url: URL) -> Bool {
        cleanup()
        if let timestamp = recentlyHandled[url], Date().timeIntervalSince(timestamp) < 0.3 {
            return false
        }
        recentlyHandled[url] = Date()
        return true
    }

    func shouldProcessBatch(_ urls: [URL]) -> [URL] {
        cleanup()
        var fresh: [URL] = []
        for url in urls {
            if shouldProcess(url) {
                fresh.append(url)
            }
        }
        return fresh
    }

    private func cleanup() {
        let cutoff = Date().addingTimeInterval(-2.0)
        recentlyHandled = recentlyHandled.filter { $0.value > cutoff }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AppDelegate?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    var isHeadless: Bool {
        isHeadlessBackgroundLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = self
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateApp),
            name: NSNotification.Name("FileConverterActivateApp"),
            object: nil
        )

        // Conservative startup cleanup of prior session staging artifacts (TASK-028 / SEC-004)
        StagingArtifactManifest.shared.sweepOrphanedArtifacts()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Coordinated shutdown (TASK-029 / REQ-006): If conversions are active, request cancellation
        // and allow up to 3 seconds for bounded external tool termination before exiting.
        guard ConversionQueue.shared.activeCount > 0 else {
            return .terminateNow
        }
        Task { @MainActor in
            await ConversionQueue.shared.cancelAllAndWait(timeout: 3.0)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        return id.contains("Settings") || id.contains("settings") || window.title.contains("Settings") || window.title.contains("Preferences")
    }

    private func findMainWindow() -> NSWindow? {
        if let window = MainWindowTracker.shared.mainWindow, window.windowNumber > 0 {
            return window
        }
        for window in NSApp.windows where !isSettingsWindow(window) {
            if window.identifier?.rawValue == "FileConverterMainWindow" || window.identifier?.rawValue == "main" {
                return window
            }
        }
        for window in NSApp.windows where !isSettingsWindow(window) {
            if window.canBecomeMain {
                return window
            }
        }
        return nil
    }

    func activateMainWindow() {
        if let window = findMainWindow() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func handleActivateApp() {
        isHeadlessBackgroundLaunch = false
        NSApp.activate(ignoringOtherApps: true)
        activateMainWindow()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let batchID = NotificationURLResolver.batchID(
            from: response.notification.request.content.userInfo
        )
        completionHandler()

        guard let batchID else { return }
        Task { @MainActor [weak self, batchID] in
            guard let self else { return }
            ConversionQueue.shared.withNotificationRevealURLs(for: batchID) { urls in
                guard !urls.isEmpty else { return }
                self.isHeadlessBackgroundLaunch = false
                NSApp.activate(ignoringOtherApps: true)
                self.activateMainWindow()
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = findMainWindow() {
            if window.isMiniaturized {
                window.deminiaturize(self)
                window.makeKeyAndOrderFront(self)
                return true
            } else if !flag || !window.isVisible {
                window.makeKeyAndOrderFront(self)
                return true
            }
        }
        if !flag {
            for window in sender.windows where !isSettingsWindow(window) {
                if window.isMiniaturized {
                    window.deminiaturize(self)
                    window.makeKeyAndOrderFront(self)
                    return true
                }
            }
            for window in sender.windows where !isSettingsWindow(window) {
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
            activateMainWindow()
        } else {
            let hasVisibleMain = NSApp.windows.contains { $0.isVisible && !isSettingsWindow($0) }
            if !hasVisibleMain {
                isHeadlessBackgroundLaunch = true
                for window in NSApplication.shared.windows {
                    window.orderOut(nil)
                }
            }
        }

        for url in customURLs {
            if URLDeduplicator.shared.shouldProcess(url) {
                NotificationCenter.default.post(
                    name: NSNotification.Name("HandleIncomingURL"),
                    object: nil,
                    userInfo: ["url": url]
                )
            }
        }

        if !fileURLs.isEmpty {
            let fresh = URLDeduplicator.shared.shouldProcessBatch(fileURLs)
            if !fresh.isEmpty {
                AppLogger.finder.notice("Files received via Open With or the Dock: count=\(fresh.count, privacy: .public)")
                receiveFilesWithoutPreset(fresh)
            }
        }
    }

    /// Open With, Services, and Dock drops carry no preset. Either convert
    /// with the last preset used for these file types, or show the picker
    /// with that preset selected.
    func receiveFilesWithoutPreset(_ urls: [URL]) {
        if AppSettings.shared.openWithBehavior == .convertWithLastChoice {
            let compatible = PresetValidator.compatiblePresets(forURLs: urls)
            if let preset = PresetUsageStore.lastCompatiblePreset(for: urls, among: compatible) {
                if preset.isInteractiveWorkflow {
                    AppState.shared.presentWorkflowDialog(preset: preset, urls: urls)
                } else {
                    Task { @MainActor in
                        do {
                            try await AppState.shared.convertFilesWhenReady(urls: urls, preset: preset)
                        } catch {
                            ConversionQueue.shared.recordRejectedRequest(
                                sources: urls.map { (displayName: $0.lastPathComponent, path: $0.path) },
                                preset: preset,
                                reason: error.localizedDescription
                            )
                        }
                    }
                }
                return
            }
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("OpenFileConverterPresetPicker"),
            object: nil,
            userInfo: ["urls": urls]
        )
    }

    @objc func openFilesFromService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let items = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !items.isEmpty else {
            return
        }
        let fresh = URLDeduplicator.shared.shouldProcessBatch(items)
        guard !fresh.isEmpty else { return }
        AppLogger.finder.notice("Files received via Services: count=\(fresh.count, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        activateMainWindow()
        receiveFilesWithoutPreset(fresh)
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
        Window("File Converter", id: "main") {
            FileConverterMainView()
                .environmentObject(appState)
                .onOpenURL { url in
                    if URLDeduplicator.shared.shouldProcess(url) {
                        handleIncomingURL(url)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("HandleIncomingURL"))) { note in
                    if let url = note.userInfo?["url"] as? URL {
                        handleIncomingURL(url)
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["*"]))
        .defaultSize(width: 600, height: 480)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Files to Convert...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenFileConverterOpenPanel"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Clear Finished") {
                    ConversionQueue.shared.clearCompleted()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!conversionQueue.hasClearableJobs)

                Button("Cancel All Active") {
                    ConversionQueue.shared.cancelAll()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(conversionQueue.cancelableCount == 0)
            }

            CommandMenu("Conversion") {
                Button("Retry All Failed Conversions") {
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
                    if let helpURL {
                        NSWorkspace.shared.open(helpURL)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Documentation is unavailable"
                        alert.informativeText = "The help document was not included in this build."
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
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
            AppDelegate.shared?.activateMainWindow()
            AppDelegate.shared?.receiveFilesWithoutPreset([url])
        }
    }
}
