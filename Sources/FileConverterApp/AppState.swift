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

    private var cancellables = Set<AnyCancellable>()

    public enum SettingsTab: String, CaseIterable, Identifiable {
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
        PresetStore.shared.publishFinderMenuSnapshot()
        _ = ConversionCoordinator.shared

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

    private func handleBatchCompleted(_ note: Notification) {
        guard AppSettings.shared.revealInFinder else { return }
        guard let urls = note.userInfo?["destinationURLs"] as? [URL], !urls.isEmpty else { return }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}
