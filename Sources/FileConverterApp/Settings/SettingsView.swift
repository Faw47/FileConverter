import SwiftUI

/// The Settings window. Every tab shares one window size, so switching tabs
/// never resizes the window; the user can make it larger.
public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        TabView(selection: $appState.selectedTab) {
            ForEach(AppState.SettingsTab.allCases, id: \.self) { tab in
                content(for: tab)
                    .tabItem { Label(tab.rawValue, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 860, idealWidth: 900, maxWidth: .infinity, minHeight: 600, idealHeight: 660, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .presets: PresetsSettingsView()
        case .externalTools: ExternalToolsSettingsView()
        case .finder: FinderIntegrationView()
        }
    }
}
