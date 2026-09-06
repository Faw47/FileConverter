import SwiftUI

/// The macOS Settings scene uses a native tab toolbar. This keeps the window
/// discoverable with the standard Settings affordances and avoids a second,
/// app-specific sidebar navigation model.
public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        TabView(selection: $appState.selectedTab) {
            GeneralSettingsView()
                .tabItem { Label(AppState.SettingsTab.general.rawValue, systemImage: AppState.SettingsTab.general.systemImage) }
                .tag(AppState.SettingsTab.general)

            PresetsSettingsView()
                .tabItem { Label(AppState.SettingsTab.presets.rawValue, systemImage: AppState.SettingsTab.presets.systemImage) }
                .tag(AppState.SettingsTab.presets)

            ExternalToolsSettingsView()
                .tabItem { Label(AppState.SettingsTab.externalTools.rawValue, systemImage: AppState.SettingsTab.externalTools.systemImage) }
                .tag(AppState.SettingsTab.externalTools)

            PerformanceSettingsView()
                .tabItem { Label(AppState.SettingsTab.performance.rawValue, systemImage: AppState.SettingsTab.performance.systemImage) }
                .tag(AppState.SettingsTab.performance)

            FinderIntegrationView()
                .tabItem { Label(AppState.SettingsTab.finder.rawValue, systemImage: AppState.SettingsTab.finder.systemImage) }
                .tag(AppState.SettingsTab.finder)
        }
        .frame(minWidth: 940, idealWidth: 1040, minHeight: 640, idealHeight: 700)
    }
}
