import SwiftUI
import FileConverterContracts
import FileConverterFinderSupport

public struct FinderIntegrationView: View {
    @State private var channelReady = false
    @State private var snapshotReady = false
    @State private var statusDetail = "Checking…"
    @State private var snapshotAge: String?

    public init() {}

    public var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: statusIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.system(size: 14, weight: .semibold))
                        Text(statusDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { refresh() }
                        .controlSize(.small)
                        .accessibilityLabel("Refresh Finder integration status")
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Finder integration status: \(statusTitle). \(statusDetail)")

                if let snapshotAge {
                    HStack {
                        Text("Menu data")
                        Spacer()
                        Text(snapshotAge)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Status").font(.headline)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Right-click any file in Finder to convert it without opening the app. The menu only lists presets that work for every selected file.")
                        .font(.system(size: 13))
                    StepRow(number: "1", text: "Open System Settings → Privacy & Security → Extensions.")
                    StepRow(number: "2", text: "Under Added Extensions, switch on File Converter.")
                    StepRow(number: "3", text: "Right-click a video, audio track, image, or document to convert it.")
                }
                .padding(.vertical, 4)

                Button("Open System Settings → Extensions...") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityLabel("Open System Settings Extensions")

                Button("Reveal Integration Folder...") {
                    revealIPCFolder()
                }
                .accessibilityLabel("Reveal Finder integration folder in Finder")
            } header: {
                Text("Finder Context Menu").font(.headline)
            }

            Section {
                Text("Still missing? After enabling, relaunch Finder once. If files were moved, open File Converter once so it republishes the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Relaunch Finder") {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                    task.arguments = ["Finder"]
                    try? task.run()
                }
                .controlSize(.small)
                .accessibilityLabel("Relaunch Finder")
            } header: {
                Text("Troubleshooting").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Finder")
        .onAppear { refresh() }
    }

    private var isReady: Bool { channelReady && snapshotReady }

    private var statusIcon: String {
        isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        isReady ? .green : .orange
    }

    private var statusTitle: String {
        if isReady { return "Ready — right-click works" }
        if !channelReady && !snapshotReady { return "Finish setup — open the app once" }
        if !channelReady { return "Waiting for secure channel" }
        return "Waiting for menu data"
    }

    private func refresh() {
        let catalog = FinderMenuCatalog.shared
        catalog.reload()
        channelReady = FinderRequestClient.isReady()
        snapshotReady = catalog.hasUsableSnapshot

        if isReady {
            statusDetail = "Secure channel plus menu data are live."
        } else if let error = catalog.lastErrorDescription, !snapshotReady {
            statusDetail = error
        } else if !channelReady {
            statusDetail = "Open File Converter once to create the secure key."
        } else {
            statusDetail = "Menu data will appear after your presets load."
        }

        snapshotAge = snapshotFileAge()
    }

    private func snapshotFileAge() -> String? {
        guard let config = try? IPCConfiguration.current(),
              let container = config.sharedContainerURL() else { return nil }
        let url = container
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent("finder-menu-snapshot.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func revealIPCFolder() {
        guard let config = try? IPCConfiguration.current(),
              let container = config.sharedContainerURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([container])
    }
}

private struct StepRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}
