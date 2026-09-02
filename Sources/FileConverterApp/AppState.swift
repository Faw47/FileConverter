import SwiftUI
import FileConverterCore
import FileConverterNativeBackends
import Combine
#if FILE_CONVERTER_EXTENDED
import FileConverterExternalBackends
#endif

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
#if FILE_CONVERTER_EXTENDED
        case externalTools = "External Tools"
#endif
        case performance = "Performance"
        case finder = "Finder Integration"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .presets: return "slider.horizontal.3"
            case .video: return "film"
            case .audio: return "waveform"
#if FILE_CONVERTER_EXTENDED
            case .externalTools: return "terminal"
#endif
            case .performance: return "bolt"
            case .finder: return "macwindow"
            }
        }
    }

    public init() {
#if FILE_CONVERTER_EXTENDED
        BackendResolver.shared.configure(
            backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends()
        )
#else
        BackendResolver.shared.configure(backends: NativeBackendCatalog.makeBackends())
#endif
        PresetStore.shared.publishFinderMenuSnapshot()
        _ = ConversionCoordinator.shared
    }
}
