import SwiftUI
import FileConverterContracts
import FileConverterCore
import os

@main
struct FileConverterApp: App {
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
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenFileConverterPresetPicker"),
                object: nil,
                userInfo: ["urls": [url]]
            )
        }
    }
}
