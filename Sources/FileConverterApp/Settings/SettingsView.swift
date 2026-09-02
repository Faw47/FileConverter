import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    public init() {}

    public var body: some View {
        TabView(selection: $appState.selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label(AppState.SettingsTab.general.rawValue, systemImage: AppState.SettingsTab.general.systemImage)
                }
                .tag(AppState.SettingsTab.general)

            PresetsSettingsView()
                .tabItem {
                    Label(AppState.SettingsTab.presets.rawValue, systemImage: AppState.SettingsTab.presets.systemImage)
                }
                .tag(AppState.SettingsTab.presets)

#if FILE_CONVERTER_EXTENDED
            ExternalToolsSettingsView()
                .tabItem {
                    Label(AppState.SettingsTab.externalTools.rawValue, systemImage: AppState.SettingsTab.externalTools.systemImage)
                }
                .tag(AppState.SettingsTab.externalTools)
#endif

            PerformanceSettingsView()
                .tabItem {
                    Label(AppState.SettingsTab.performance.rawValue, systemImage: AppState.SettingsTab.performance.systemImage)
                }
                .tag(AppState.SettingsTab.performance)

            FinderIntegrationView()
                .tabItem {
                    Label(AppState.SettingsTab.finder.rawValue, systemImage: AppState.SettingsTab.finder.systemImage)
                }
                .tag(AppState.SettingsTab.finder)
        }
        .frame(minWidth: 640, minHeight: 460)
    }
}
