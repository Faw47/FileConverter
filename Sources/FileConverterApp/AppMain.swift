import SwiftUI
import FileConverterContracts
import FileConverterCore
import os

@main
struct FileConverterApp: App {
    @StateObject private var appState = AppState.shared

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

                Button("Cancel All Active") {
                    ConversionQueue.shared.cancelAll()
                }
                .keyboardShortcut(".", modifiers: .command)
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
                    if let url = URL(string: "https://github.com") {
                        NSWorkspace.shared.open(url)
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
                    await ConversionCoordinator.shared.checkAndDrainPendingRequests()
                }
            }
        } else if url.isFileURL {
            let compatible = PresetValidator.compatiblePresets(forURLs: [url])
            if let firstPreset = compatible.first {
                Task {
                    do {
                        try await ConversionCoordinator.shared.convertFiles(urls: [url], preset: firstPreset)
                    } catch {
                        AppLogger.conversion.error(
                            "Incoming file conversion rejected: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }
    }
}
