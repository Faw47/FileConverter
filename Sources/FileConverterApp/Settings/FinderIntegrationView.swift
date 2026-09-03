import AppKit
import FileConverterContracts
import FileConverterFinderSupport
import Foundation
import SwiftUI

public struct FinderIntegrationView: View {
    @State private var channelReady = false
    @State private var snapshotReady = false
    @State private var statusDetail = "Checking integration files..."
    @State private var snapshotAge: String?

    public init() {}

    public var body: some View {
        SettingsPage(
            title: "Finder",
            subtitle: "Set up and troubleshoot the Finder context-menu extension.",
            systemImage: "finder"
        ) {
            Form {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(statusColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle)
                                .font(.body.weight(.medium))
                            Text(statusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Refresh") {
                            refresh()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 3)

                    if let snapshotAge {
                        LabeledContent("Finder menu data") {
                            Text(snapshotAge)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Integration Files")
                } footer: {
                    Text("This status verifies File Converter's shared channel and menu snapshot. macOS does not expose a reliable in-app switch state for the Finder extension, so confirm that separately in System Settings.")
                }

                Section("Enable the Finder Extension") {
                    VStack(alignment: .leading, spacing: 10) {
                        FinderSetupStep(number: 1, text: "Open System Settings, then Privacy & Security, then Extensions.")
                        FinderSetupStep(number: 2, text: "Under Added Extensions, enable File Converter.")
                        FinderSetupStep(number: 3, text: "Right-click a supported file and choose a File Converter preset.")
                    }
                    .padding(.vertical, 3)

                    Button("Open System Settings Extensions...") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") else { return }
                        NSWorkspace.shared.open(url)
                    }

                    Button("Reveal Integration Folder...") {
                        revealIPCFolder()
                    }
                }

                Section("Troubleshooting") {
                    Text("If the extension is enabled but the menu is missing, relaunch Finder. Open File Converter again afterward if the menu snapshot needs to be republished.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Relaunch Finder") {
                        relaunchFinder()
                    }
                    .controlSize(.small)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .onAppear(perform: refresh)
    }

    private var integrationFilesReady: Bool {
        channelReady && snapshotReady
    }

    private var statusIcon: String {
        integrationFilesReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        integrationFilesReady ? .green : .orange
    }

    private var statusTitle: String {
        if integrationFilesReady { return "Integration files are ready" }
        if !channelReady && !snapshotReady { return "Setup is incomplete" }
        if !channelReady { return "Secure channel is not ready" }
        return "Finder menu data is not ready"
    }

    private func refresh() {
        let catalog = FinderMenuCatalog.shared
        catalog.reload()

        channelReady = FinderRequestClient.isReady()
        snapshotReady = catalog.hasUsableSnapshot

        if integrationFilesReady {
            statusDetail = "The secure channel and Finder menu snapshot are available."
        } else if let error = catalog.lastErrorDescription, !snapshotReady {
            statusDetail = error
        } else if !channelReady {
            statusDetail = "Open File Converter once so it can create its secure integration key."
        } else {
            statusDetail = "Preset menu data has not been published yet."
        }

        snapshotAge = snapshotFileAge()
    }

    private func snapshotFileAge() -> String? {
        guard let config = try? IPCConfiguration.current(),
              let container = config.sharedContainerURL() else {
            return nil
        }

        let snapshotURL = container
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent("finder-menu-snapshot.json")

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: modificationDate, relativeTo: Date()))"
    }

    private func revealIPCFolder() {
        guard let config = try? IPCConfiguration.current(),
              let container = config.sharedContainerURL() else {
            NSSound.beep()
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([container])
    }

    private func relaunchFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]

        do {
            try process.run()
        } catch {
            NSSound.beep()
        }
    }
}

private struct FinderSetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}
