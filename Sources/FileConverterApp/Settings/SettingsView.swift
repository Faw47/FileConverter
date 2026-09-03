import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                settingsRow(.general)
                settingsRow(.presets)
                settingsRow(.externalTools)
                settingsRow(.performance)
                settingsRow(.finder)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, idealWidth: 920, minHeight: 580, idealHeight: 640)
    }

    private var sidebarSelection: Binding<AppState.SettingsTab?> {
        Binding(
            get: { appState.selectedTab },
            set: { newValue in
                if let newValue {
                    appState.selectedTab = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func settingsRow(_ tab: AppState.SettingsTab) -> some View {
        Label(tab.rawValue, systemImage: tab.systemImage)
            .tag(tab)
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedTab {
        case .general:
            GeneralSettingsView()
        case .presets:
            PresetsSettingsView()
        case .externalTools:
            ExternalToolsSettingsView()
        case .performance:
            PerformanceSettingsView()
        case .finder:
            FinderIntegrationView()
        }
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: title, subtitle: subtitle, systemImage: systemImage)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}
