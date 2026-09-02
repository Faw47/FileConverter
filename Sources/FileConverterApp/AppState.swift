import SwiftUI
import FileConverterCore
import FileConverterNativeBackends
import FileConverterExternalBackends
import Combine

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var selectedTab: SettingsTab = .general
    @Published public var showSettings: Bool = false
    @Published public var dropZoneActive: Bool = false

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case presets = "Presets"
        case video = "Video"
        case audio = "Audio"
        case externalTools = "External Tools"
        case performance = "Performance"
        case finder = "Finder Integration"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .presets: return "slider.horizontal.3"
            case .video: return "film"
            case .audio: return "waveform"
            case .externalTools: return "terminal"
            case .performance: return "bolt"
            case .finder: return "macwindow"
            }
        }
    }

    public init() {
        BackendResolver.shared.configure(
            backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends()
        )
        PresetStore.shared.publishFinderMenuSnapshot()
        _ = ConversionCoordinator.shared
    }
}
