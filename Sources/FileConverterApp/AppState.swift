import SwiftUI
import AppKit
import FileConverterCore
import FileConverterNativeBackends
import FileConverterExternalBackends
import Combine

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var selectedTab: SettingsTab
    @Published public var showSettings: Bool = false
    @Published public var dropZoneActive: Bool = false
    @Published public private(set) var backendDiscoveryComplete = false

    private var cancellables = Set<AnyCancellable>()
    private var backendDiscoveryTask: Task<Void, Never>?

    public enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case presets = "Presets"
        case externalTools = "External Tools"
        case performance = "Performance"
        case finder = "Finder Integration"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .presets: return "slider.horizontal.3"
            case .externalTools: return "terminal"
            case .performance: return "bolt"
            case .finder: return "macwindow"
            }
        }

        public var subtitle: String {
            switch self {
            case .general: return "Outputs, conflicts, notifications"
            case .presets: return "Formats, backends, quality"
            case .externalTools: return "FFmpeg, documents, diagnostics"
            case .performance: return "Concurrency, thermals"
            case .finder: return "Context menu, status"
            }
        }
    }

    public init() {
        let stored = UserDefaults.standard.string(forKey: AppSettings.Keys.selectedSettingsTab)
        self.selectedTab = SettingsTab(rawValue: stored ?? "") ?? .general

        _ = AppSettings.shared

        BackendResolver.shared.configure(
            backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends()
        )
        // Publish native capabilities immediately, then discover optional
        // command-line tools away from the main actor and republish once the
        // scan (including FFmpeg encoder probing) completes.
        PresetStore.shared.publishFinderMenuSnapshot()
        // Install the IPC observer before optional tool discovery starts. A
        // Finder command can arrive while discovery is still probing tools,
        // and native PDF/image conversions must not wait for that scan.
        _ = ConversionCoordinator.shared
        backendDiscoveryTask = Task.detached(priority: .utility) {
            ExternalToolDiscovery.shared.refreshAllTools()
            PresetStore.shared.publishFinderMenuSnapshot()
            await MainActor.run {
                AppState.shared.backendDiscoveryComplete = true
            }
        }

        $selectedTab
            .sink { tab in
                UserDefaults.standard.set(tab.rawValue, forKey: AppSettings.Keys.selectedSettingsTab)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .fileConverterBatchCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleBatchCompleted(note)
            }
            .store(in: &cancellables)
    }

    public func openSettings(tab: SettingsTab? = nil) {
        if let tab { selectedTab = tab }
        showSettings = true
    }

    public func drainFinderRequestsWhenReady() async {
        // Drain once immediately so native requests are admitted while
        // optional backend discovery is still running, then drain again after
        // discovery for requests that depend on an external tool.
        await ConversionCoordinator.shared.checkAndDrainPendingRequests()
        await backendDiscoveryTask?.value
        await ConversionCoordinator.shared.checkAndDrainPendingRequests()
    }

    public func convertFilesWhenReady(urls: [URL], preset: ConversionPreset) async throws {
        await backendDiscoveryTask?.value
        try await ConversionCoordinator.shared.convertFiles(urls: urls, preset: preset)
    }

    private func handleBatchCompleted(_ note: Notification) {
        guard AppSettings.shared.revealInFinder else { return }
        guard let urls = note.userInfo?["destinationURLs"] as? [URL], !urls.isEmpty else { return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}
