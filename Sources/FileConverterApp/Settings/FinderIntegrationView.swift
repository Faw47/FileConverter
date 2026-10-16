import AppKit
import FinderSync
import FileConverterContracts
import FileConverterCore
import FileConverterFinderSupport
import Foundation
import SwiftUI

public struct FinderIntegrationView: View {
    @State private var channelReady = false
    @State private var snapshotReady = false
    @State private var statusDetail = "Checking integration files…"
    @State private var snapshotAge: String?
    @State private var isTesting = false
    @State private var testSuccessMessage: String?
    @State private var testErrorMessage: String?
    @State private var showingRelaunchConfirmation = false
    @State private var finderRelaunched = false
    @State private var extensionEnabled: Bool?

    public init() {}

    private var integrationFilesReady: Bool {
        channelReady && snapshotReady && extensionEnabled == true
    }

    private var statusTitle: String {
        if integrationFilesReady { return "The File Converter menu is ready in Finder" }
        if extensionEnabled == false { return "The Finder extension is turned off" }
        if extensionEnabled == nil { return "Finder extension status unknown" }
        return "Finder setup is not finished"
    }

    public var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: integrationFilesReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(integrationFilesReady ? .green : .orange)
                        .imageScale(.large)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle).font(.headline)
                        Text(statusDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if extensionEnabled != true {
                        Button("Open Login Items & Extensions…") { openSystemExtensions() }
                    } else {
                        Button("Check Again") { testIntegration() }
                            .disabled(isTesting)
                    }
                }
                if let testSuccessMessage {
                    Text(testSuccessMessage).font(.callout).foregroundStyle(.green)
                }
                if let testErrorMessage {
                    Text(testErrorMessage).font(.callout).foregroundStyle(.red)
                }
            }

            Section("How to Use") {
                Text("1. In System Settings, open General › Login Items & Extensions, then turn on File Converter under Finder Extensions.")
                Text("2. In Finder, right-click one or more files and choose File Converter.")
                Text("3. Pick a preset. The converted file appears next to the original, or wherever General settings say.")
            }

            Section("Troubleshooting") {
                LabeledContent("Menu data") {
                    Text(snapshotAge ?? "Never written")
                }
                LabeledContent {
                    Button("Rewrite Menu Data") { forceRefreshSnapshot() }
                } label: {
                    Text("New presets are missing from the menu")
                    Text("Writes the menu data Finder reads again.")
                }
                LabeledContent {
                    Button(finderRelaunched ? "Restarted" : "Restart Finder…") {
                        showingRelaunchConfirmation = true
                    }
                    .disabled(finderRelaunched)
                } label: {
                    Text("The menu does not appear at all")
                    Text("Open Finder windows close and reopen.")
                }
                LabeledContent {
                    Button("Show Folder") { revealIPCFolder() }
                } label: {
                    Text("Shared folder")
                    Text("The folder File Converter shares with Finder.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Restart Finder?",
            isPresented: $showingRelaunchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart Finder", role: .destructive) { relaunchFinder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finder windows close and reopen. File copies in progress in Finder may be interrupted.")
        }
    }

    private func refresh() {
        testSuccessMessage = nil
        testErrorMessage = nil
        let catalog = FinderMenuCatalog.shared
        catalog.reload()

        channelReady = FinderRequestClient.isReady()
        snapshotReady = catalog.hasUsableSnapshot
        if #available(macOS 10.15, *), Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
        } else {
            // The snapshot runner is intentionally a raw Swift executable.
            // Finder Sync cannot establish its XPC connection without an app
            // bundle, so report an unknown state rather than emit failures.
            extensionEnabled = nil
        }

        if integrationFilesReady {
            statusDetail = "Secure channel, menu snapshot, and the Finder extension are enabled."
        } else if extensionEnabled == false {
            statusDetail = "Enable File Converter under System Settings > General > Login Items & Extensions."
        } else if extensionEnabled == nil {
            statusDetail = "Finder extension status is available only from an installed app bundle."
        } else if let error = catalog.lastErrorDescription, !snapshotReady {
            statusDetail = error
        } else if !channelReady {
            statusDetail = "Launch File Converter once to initialize its secure IPC key."
        } else {
            statusDetail = "Preset menu data snapshot has not been exported yet."
        }

        snapshotAge = snapshotFileAge()
    }

    private func testIntegration() {
        isTesting = true
        testSuccessMessage = nil
        testErrorMessage = nil

        Task { @MainActor in
            _ = PresetStore.shared.publishFinderMenuSnapshot()
            refresh()
            isTesting = false
            if integrationFilesReady {
                testSuccessMessage = "Extension status, secure channel, and preset snapshot are ready."
            } else {
                testErrorMessage = statusDetail.isEmpty ? "Finder extension integration is not ready. Check system permissions and app group configuration." : statusDetail
            }
        }
    }

    private func snapshotFileAge() -> String? {
        guard let config = try? IPCConfiguration.current(),
              let container = config.sharedContainerURL() else {
            return "No container"
        }

        let snapshotURL = container
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent("finder-menu-snapshot.json")

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return "Never synced"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: modificationDate, relativeTo: Date()))"
    }

    private func forceRefreshSnapshot() {
        let didWrite = PresetStore.shared.publishFinderMenuSnapshot()
        if !didWrite {
            statusDetail = PresetStore.shared.lastErrorDescription ?? "Could not write the Finder menu snapshot."
        }
        refresh()
    }

    private func openSystemExtensions() {
        if #available(macOS 10.15, *) {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    }

    private func revealIPCFolder() {
        guard let config = try? IPCConfiguration.current(),
              let container = config.sharedContainerURL() else {
            testErrorMessage = "The shared Finder data directory is not available yet. Open File Converter once to initialize integration."
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
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                finderRelaunched = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    refresh()
                    finderRelaunched = false
                }
            } else {
                testErrorMessage = "Finder could not be relaunched (exit status \(process.terminationStatus))."
            }
        } catch {
            testErrorMessage = "Finder could not be relaunched: \(error.localizedDescription)"
        }
    }
}
