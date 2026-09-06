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
    @State private var statusDetail = "Checking integration files..."
    @State private var snapshotAge: String?
    @State private var isTesting = false
    @State private var testSuccessMessage: String?
    @State private var finderRelaunched = false
    @State private var extensionEnabled: Bool?

    public init() {}

    public var body: some View {
        ScrollView {
            LiquidGlassContainer(spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    // Header
                    headerView

                    // Health Dashboard
                    healthDashboardSection

                    // Setup Guide
                    setupGuideSection

                    // Troubleshooting & Maintenance
                    maintenanceSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refresh)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 14) {
            SettingsIconBadge(systemImage: "macwindow", color: .blue, size: .header)

            VStack(alignment: .leading, spacing: 2) {
                Text("Finder Integration")
                    .font(.title2.weight(.bold))

                Text("Configure the Finder Sync context menu for one-click file conversions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Health Dashboard Section

    private var healthDashboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Extension Status", accessory: snapshotAge)

            SettingsCard {
                VStack(spacing: 14) {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(integrationFilesReady ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                                .frame(width: 46, height: 46)

                            Image(systemName: integrationFilesReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(integrationFilesReady ? Color.green : Color.orange)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text(statusDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Button {
                            testIntegration()
                        } label: {
                            HStack(spacing: 6) {
                                if isTesting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "bolt.horizontal.fill")
                                        .font(.system(size: 11))
                                }
                                Text("Check Setup")
                            }
                        }
                        .glassActionProminent()
                        .controlSize(.regular)
                        .disabled(isTesting)
                    }

                    if let testSuccessMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(testSuccessMessage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.green.opacity(0.08))
                        )
                    }

                    Divider()

                    // Sub-components status indicators
                    HStack(spacing: 20) {
                        subStatusItem(
                            label: "Secure IPC Channel",
                            isReady: channelReady,
                            readyText: "Active",
                            unreadyText: "Missing Key"
                        )

                        Divider().frame(height: 20)

                        subStatusItem(
                            label: "Finder Extension",
                            isReady: extensionEnabled == true,
                            readyText: "Enabled",
                            unreadyText: extensionEnabled == false ? "Disabled" : "Unknown"
                        )

                        Divider().frame(height: 20)

                        subStatusItem(
                            label: "Finder Menu Data",
                            isReady: snapshotReady,
                            readyText: "Synchronized",
                            unreadyText: "Pending Sync"
                        )

                        Spacer()

                        Button("Refresh") {
                            refresh()
                        }
                        .glassAction()
                        .controlSize(.small)
                    }
                }
                .padding(14)
            }
        }
    }

    private func subStatusItem(label: String, isReady: Bool, readyText: String, unreadyText: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(isReady ? readyText : unreadyText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isReady ? Color.primary : Color.orange)
            }
        }
    }

    private var integrationFilesReady: Bool {
        channelReady && snapshotReady && extensionEnabled == true
    }

    private var statusTitle: String {
        if integrationFilesReady { return "Finder Extension Ready" }
        if extensionEnabled == false { return "Finder Extension Disabled" }
        if extensionEnabled == nil { return "Finder Extension Status Unknown" }
        if !channelReady && !snapshotReady { return "Integration Incomplete" }
        if !channelReady { return "Secure Channel Pending" }
        return "Menu Snapshot Pending"
    }

    // MARK: - Setup Guide Section

    private var setupGuideSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Setup Instructions", accessory: "macOS System Settings")

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    guideStepRow(
                        step: 1,
                        title: "Open System Settings Extensions",
                        description: "Open General > Login Items & Extensions in System Settings.",
                        actionTitle: "Open Extensions..."
                    ) {
                        openSystemExtensions()
                    }

                    Divider().padding(.leading, 36)

                    guideStepRow(
                        step: 2,
                        title: "Enable File Converter",
                        description: "Find Finder extensions and enable File Converter.",
                        actionTitle: nil,
                        action: nil
                    )

                    Divider().padding(.leading, 36)

                    guideStepRow(
                        step: 3,
                        title: "Right-Click to Convert",
                        description: "Select any supported audio, video, image, or document file in Finder to view your custom conversion presets.",
                        actionTitle: nil,
                        action: nil
                    )
                }
                .padding(14)
            }
        }
    }

    private func guideStepRow(
        step: Int,
        title: String,
        description: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 24, height: 24)

                Text("\(step)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .glassAction()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Maintenance Section

    private var maintenanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Troubleshooting & Diagnostics")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Relaunch Finder",
                        subtitle: "If newly added presets do not immediately show up in the Finder right-click menu, restart Finder.",
                        icon: "arrow.counterclockwise.circle",
                        iconColor: .blue
                    ) {
                        Button {
                            relaunchFinder()
                        } label: {
                            HStack(spacing: 4) {
                                if finderRelaunched {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Relaunched")
                                } else {
                                    Text("Relaunch Finder")
                                }
                            }
                        }
                        .glassAction()
                        .controlSize(.small)
                    }

                    Divider().padding(.leading, 42)

                    SettingsRow(
                        title: "Force Refresh Snapshot",
                        subtitle: "Re-exports your active preset list to the shared Finder extension database.",
                        icon: "arrow.triangle.2.circlepath",
                        iconColor: .purple
                    ) {
                        Button("Sync Snapshot") {
                            forceRefreshSnapshot()
                        }
                        .glassAction()
                        .controlSize(.small)
                    }

                    Divider().padding(.leading, 42)

                    SettingsRow(
                        title: "Reveal Shared Data Directory",
                        subtitle: "Opens the shared Finder data folder containing the request channel and preset snapshot.",
                        icon: "folder",
                        iconColor: .secondary
                    ) {
                        Button("Reveal in Finder") {
                            revealIPCFolder()
                        }
                        .glassAction()
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
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

        Task { @MainActor in
            _ = PresetStore.shared.publishFinderMenuSnapshot()
            refresh()
            isTesting = false
            if integrationFilesReady {
                testSuccessMessage = "Extension status, secure channel, and preset snapshot are ready."
            } else {
                testSuccessMessage = nil
            }
        }
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
            finderRelaunched = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                refresh()
                finderRelaunched = false
            }
        } catch {
            NSSound.beep()
        }
    }
}
