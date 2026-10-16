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
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: ConversionQueue.batchFinishedCategory,
                actions: [
                    UNNotificationAction(identifier: ConversionQueue.revealOutputsAction, title: "Show in Finder"),
                    UNNotificationAction(identifier: ConversionQueue.openOutputsAction, title: "Open", options: [.foreground]),
                ],
                intentIdentifiers: []
            ),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateApp),
            name: .fileConverterActivateApp,
            object: nil
        )

        // Conservative startup cleanup of prior session staging artifacts (TASK-028 / SEC-004)
        StagingArtifactManifest.shared.sweepOrphanedArtifacts()
        DockProgressController.shared.start()
        FolderWatcher.shared.start()

        #if DEBUG
        // Visual check of the real Settings scene (not a hosted copy):
        // --capture-settings <dir> saves every tab in light and dark, then quits.
        if let index = CommandLine.arguments.firstIndex(of: "--capture-settings"),
           CommandLine.arguments.indices.contains(index + 1) {
            SettingsSceneCapture.run(outputDirectory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = ConversionQueue.shared
        let unfinished = queue.activeCount + queue.queuedCount
        guard unfinished > 0 else {
            return .terminateNow
        }
        // Logging out or shutting down: don't hold the Mac up with a question.
        if !Self.isSystemShutdownQuit && !confirmQuit(unfinished: unfinished) {
            return .terminateCancel
        }
        // Coordinated shutdown (TASK-029 / REQ-006): cancel, and allow up to
        // 3 seconds for bounded external tool termination before exiting.
        Task { @MainActor in
            await queue.cancelAllAndWait(timeout: 3.0)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmQuit(unfinished: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit File Converter?"
        alert.informativeText = Inflect.string(
            "If you quit now, ^[\(unfinished) unfinished conversion](inflect: true) will stop. Files already converted are kept."
        )
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// True when the Mac is logging out, restarting, or shutting down.
    private static var isSystemShutdownQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else {
            return false
        }
        let systemReasons = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
        return systemReasons.map { OSType($0) }.contains(reason)
    }

    /// SwiftUI gives the Settings window an identifier containing
    /// "Settings"; window titles are localized and not used.
    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue ?? "").localizedCaseInsensitiveContains("settings")
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        Self.isSettingsWindow(window)
    }

    private func findMainWindow() -> NSWindow? {
        if let window = MainWindowTracker.shared.mainWindow, window.windowNumber > 0 {
            return window
        }
        return NSApp.windows.first { window in
            window.identifier?.rawValue == "FileConverterMainWindow" || window.identifier?.rawValue == "main"
        }
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
        // Someone looking at the queue already sees the batch finish; keep it
        // in Notification Center without a banner or sound.
        let watching = Thread.isMainThread && MainActor.assumeIsolated { Self.isWatchingQueue }
        completionHandler(watching ? [.list] : [.banner, .sound])
    }

    /// File Converter is the active app and its main window is on screen.
    static var isWatchingQueue: Bool {
        guard NSApp.isActive, let window = MainWindowTracker.shared.mainWindow else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let batchID = NotificationURLResolver.batchID(
            from: response.notification.request.content.userInfo
        )
        let opens = response.actionIdentifier == ConversionQueue.openOutputsAction
        completionHandler()

        guard let batchID else { return }
        Task { @MainActor [weak self, batchID] in
            guard let self else { return }
            ConversionQueue.shared.withNotificationRevealURLs(for: batchID) { urls in
                guard !urls.isEmpty else { return }
                if opens {
                    // "Open": the converted files, in their default apps.
                    urls.forEach { NSWorkspace.shared.open($0) }
                    return
                }
                // Clicking the notification or "Show in Finder".
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
                    name: .fileConverterHandleIncomingURL,
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
            name: .fileConverterPresetPicker,
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
    @StateObject private var settings = AppSettings.shared

    /// MenuBarExtra writes `isInserted` back on every update; binding it
    /// straight to @AppStorage made each write trigger another update and
    /// kept a CPU core at 100%. Only real changes are stored.
    private var menuBarExtraInserted: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarExtra },
            set: { newValue in
                if settings.showMenuBarExtra != newValue { settings.showMenuBarExtra = newValue }
            }
        )
    }

    init() {
        #if DEBUG
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), idx + 1 < CommandLine.arguments.count {
            let outDir = CommandLine.arguments[idx + 1]
            SnapshotRunner.run(outputDirectory: outDir)
        }
        #endif
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
                .onReceive(NotificationCenter.default.publisher(for: .fileConverterHandleIncomingURL)) { note in
                    if let url = note.userInfo?["url"] as? URL {
                        handleIncomingURL(url)
                    }
                }
        }
        .handlesExternalEvents(matching: Set(["*"]))
        .defaultSize(width: 640, height: 500)
        MenuBarExtra(isInserted: menuBarExtraInserted) {
            MenuBarStatusView(queue: conversionQueue)
        } label: {
            // Two-way arrows (one format to another), filled while converting;
            // the old circular arrows read as "sync".
            Image(systemName: conversionQueue.activeCount + conversionQueue.queuedCount > 0
                ? "arrow.left.arrow.right.circle.fill"
                : "arrow.left.arrow.right.circle")
                .accessibilityLabel("File Converter")
        }
        Window("File Converter Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 620, height: 640)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .fileConverterOpenPanel, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Clear Finished") {
                    ConversionQueue.shared.clearCompleted()
                }
                .help("Remove finished conversions from the list")
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!conversionQueue.hasClearableJobs)

                Button("Cancel All Active") {
                    ConversionQueue.shared.cancelAll()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(conversionQueue.cancelableCount == 0)
            }

            CommandMenu("Conversion") {
                Button(conversionQueue.isPaused ? "Resume Queue" : "Pause Queue") {
                    if ConversionQueue.shared.isPaused {
                        ConversionQueue.shared.resume()
                    } else {
                        ConversionQueue.shared.pause()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("Retry All Failed Conversions") {
                    for job in ConversionQueue.shared.jobs where !job.isFromHistory {
                        if case .failed = job.state { ConversionQueue.shared.retryJob(id: job.id) }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!conversionQueue.jobs.contains { job in
                    if case .failed = job.state { return !job.isFromHistory }
                    return false
                })

                Divider()

                Button("Manage Presets…") {
                    appState.openSettings(tab: .presets)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("External Tools…") {
                    appState.openSettings(tab: .externalTools)
                }
            }

            CommandGroup(replacing: .help) {
                HelpMenuButton()
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
                    if query.contains("perform") || query.contains("thermal") || query.contains("cpu") { return .general }
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
