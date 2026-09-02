import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $appState.selectedTab) {
                ForEach(AppState.SettingsTab.allCases) { tab in
                    NavigationLink(value: tab) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                Text(tab.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 15))
                                .frame(width: 22)
                        }
                    }
                    .tag(tab)
                    .accessibilityLabel("\(tab.rawValue) settings. \(tab.subtitle)")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
            .navigationTitle("Settings")
        } detail: {
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(appState.selectedTab.rawValue)
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .all ? .detailOnly : .all
                    }
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .help("Toggle sidebar (⌃⌘S)")
                .keyboardShortcut("S", modifiers: [.command, .control])
                .accessibilityLabel("Toggle settings sidebar")
            }
        }
    }
}
