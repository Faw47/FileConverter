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
                .frame(width: 640, height: 640)
                .tabItem { Label(AppState.SettingsTab.general.rawValue, systemImage: AppState.SettingsTab.general.systemImage) }
                .tag(AppState.SettingsTab.general)

            PresetsSettingsView()
                .frame(minWidth: 860, idealWidth: 940, minHeight: 600, idealHeight: 660)
                .tabItem { Label(AppState.SettingsTab.presets.rawValue, systemImage: AppState.SettingsTab.presets.systemImage) }
                .tag(AppState.SettingsTab.presets)

            ExternalToolsSettingsView()
                .frame(width: 640, height: 560)
                .tabItem { Label(AppState.SettingsTab.externalTools.rawValue, systemImage: AppState.SettingsTab.externalTools.systemImage) }
                .tag(AppState.SettingsTab.externalTools)

            PerformanceSettingsView()
                .frame(width: 640, height: 260)
                .tabItem { Label(AppState.SettingsTab.performance.rawValue, systemImage: AppState.SettingsTab.performance.systemImage) }
                .tag(AppState.SettingsTab.performance)

            FinderIntegrationView()
                .frame(width: 640, height: 520)
                .tabItem { Label(AppState.SettingsTab.finder.rawValue, systemImage: AppState.SettingsTab.finder.systemImage) }
                .tag(AppState.SettingsTab.finder)
        }
    }
}
