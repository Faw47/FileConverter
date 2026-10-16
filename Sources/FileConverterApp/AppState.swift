import SwiftUI
import AppKit
import FileConverterCore
import FileConverterNativeBackends
import FileConverterExternalBackends
import Combine

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var selectedTab: SettingsTab
    @Published public var dropZoneActive: Bool = false
    @Published public private(set) var backendDiscoveryComplete = false
    @Published public private(set) var discoveryStatus: String?
    @Published public private(set) var isDiscoveringBackends: Bool = false
    @Published public var activeWorkflowDialog: ActiveWorkflowDialog?
    @Published public var uncompletedJournalEntries: [JournalEntry] = []

    private var cancellables = Set<AnyCancellable>()
    private var backendDiscoveryTask: Task<Void, Never>?

    public enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
        case general = "General"
        case presets = "Presets"
        case externalTools = "External Tools"
        case finder = "Finder Integration"

        public var id: String { rawValue }

        public var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .presets: return "slider.horizontal.3"
            case .externalTools: return "terminal"
            case .finder: return "macwindow"
            }
        }

        public var subtitle: String {
            switch self {
            case .general: return "Outputs, conflicts, notifications"
            case .presets: return "Formats, backends, quality"
            case .externalTools: return "FFmpeg, documents, diagnostics"
            case .finder: return "Context menu, status"
            }
        }
    }

    public init() {
        let stored = ConversionDefaults.store.string(forKey: AppSettings.Keys.selectedSettingsTab)
        self.selectedTab = SettingsTab(rawValue: stored ?? "") ?? .general

        _ = AppSettings.shared

        BackendResolver.shared.configure(
            backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends()
        )
        // Publish native capabilities immediately, then discover optional
        // command-line tools away from the main actor and republish once the
        // scan (including FFmpeg encoder probing) completes.
        PresetStore.shared.publishFinderMenuSnapshot()
        // Install the IPC observer before optional tool discovery starts. A
        // Finder command can arrive while discovery is still probing tools,
        // and native PDF/image conversions must not wait for that scan.
        _ = ConversionCoordinator.shared
        startBackendDiscovery()
        ConversionQueue.shared.restoreHistory()

        $selectedTab
            .sink { tab in
                ConversionDefaults.store.set(tab.rawValue, forKey: AppSettings.Keys.selectedSettingsTab)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .fileConverterBatchCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                self?.handleBatchCompleted(note)
            }
            .store(in: &cancellables)

        checkForUncompletedJournalEntries()
    }

    public func checkForUncompletedJournalEntries() {
        let journal = ConversionJournal.shared
        journal.prune(olderThan: 30 * 24 * 3600)
        let interrupted = journal.uncompletedEntries().filter {
            $0.state == .running || $0.state == .committing
        }
        let (actionable, stale) = ConversionJournal.partitionInterrupted(interrupted)
        // Nothing can be done about these, so they are not shown.
        for entry in stale {
            journal.transitionState(jobID: entry.id, to: .cancelled)
        }
        self.uncompletedJournalEntries = actionable
    }

    /// Converts every interrupted file again with its preset, if both still exist.
    public func retryInterruptedConversions() {
        let entries = uncompletedJournalEntries
        dismissAllJournalRecovery()
        let byPreset = Dictionary(grouping: entries) { $0.presetID }
        for (presetID, group) in byPreset {
            guard let preset = PresetStore.shared.preset(forID: presetID) else { continue }
            let urls = group.map { URL(fileURLWithPath: $0.sourceURLPath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { continue }
            Task { try? await convertFilesWhenReady(urls: urls, preset: preset, leases: nil) }
        }
    }

    public func dismissJournalRecovery(entryID: UUID) {
        ConversionJournal.shared.transitionState(jobID: entryID, to: .cancelled)
        uncompletedJournalEntries.removeAll { $0.id == entryID }
    }

    public func dismissAllJournalRecovery() {
        for entry in uncompletedJournalEntries {
            ConversionJournal.shared.transitionState(jobID: entry.id, to: .cancelled)
        }
        uncompletedJournalEntries.removeAll()
    }

    public func startBackendDiscovery(force: Bool = false) {
        backendDiscoveryTask?.cancel()
        backendDiscoveryComplete = false
        isDiscoveringBackends = true
        discoveryStatus = "Checking optional conversion tools…"
        // Close the gate before any Finder request can be admitted.
        BackendReadinessGate.shared.markNotReady()
        backendDiscoveryTask = Task.detached(priority: .utility) { [weak self] in
            ExternalToolDiscovery.shared.refreshAllTools(force: force) { status in
                Task { @MainActor in
                    self?.discoveryStatus = status
                }
            }
            PresetStore.shared.publishFinderMenuSnapshot()
            BackendReadinessGate.shared.markReady()
            await MainActor.run {
                self?.isDiscoveringBackends = false
                self?.discoveryStatus = nil
                self?.backendDiscoveryComplete = true
            }
        }
    }

    /// Stops waiting on discovery in the UI. Discovery itself keeps running
    /// in the background (process probes cannot be interrupted safely), and
    /// conversions proceed with the tools known so far.
    public func cancelBackendDiscovery() {
        isDiscoveringBackends = false
        discoveryStatus = nil
        backendDiscoveryComplete = true
        BackendReadinessGate.shared.markReady()
    }

    public var openSettingsAction: (@MainActor () -> Void)?

    public func openSettings(tab: SettingsTab? = nil) {
        if let tab { selectedTab = tab }

        if let settingsWindow = NSApplication.shared.windows.first(where: AppDelegate.isSettingsWindow) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if settingsWindow.isMiniaturized {
                settingsWindow.deminiaturize(nil)
            }
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        if let openSettingsAction {
            openSettingsAction()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        NSApp?.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    public func drainFinderRequestsWhenReady() async {
        await backendDiscoveryTask?.value
        await ConversionCoordinator.shared.checkAndDrainPendingRequests()
        // Finder conversions run without a window; the first one is the
        // moment to ask for permission to report when they finish.
        let settings = AppSettings.shared
        if settings.enableNotifications, settings.notificationAuthorizationState == .notDetermined {
            settings.requestNotificationAuthorization()
        }
    }

    /// Adds the jobs right away; the queue itself waits for tool discovery
    /// when a job needs an optional tool, so the rows are visible meanwhile.
    public func convertFilesWhenReady(urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]? = nil) async throws {
        try await ConversionCoordinator.shared.convertFiles(urls: urls, preset: preset, leases: leases)
    }

    public func presentWorkflowDialog(preset: ConversionPreset, urls: [URL], leases: [SecurityScopedLease]? = nil) {
        if preset.isPDFSplitWorkflow {
            WorkflowPresentationCoordinator.shared.enqueue(.pdfSplit(urls: urls, preset: preset, leases: leases))
        } else if preset.isPDFCompressWorkflow {
            WorkflowPresentationCoordinator.shared.enqueue(.pdfCompress(urls: urls, preset: preset, leases: leases))
        }
    }

    private func handleBatchCompleted(_ note: Notification) {
        guard AppSettings.shared.revealInFinder else { return }
        guard let batchID = note.userInfo.flatMap(NotificationURLResolver.batchID(from:)) else { return }
        ConversionQueue.shared.withNotificationRevealURLs(for: batchID) { urls in
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

public enum ActiveWorkflowDialog: Identifiable, Equatable {
    case compressPDF(id: UUID = UUID(), urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?)
    case splitPDF(id: UUID = UUID(), urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?)

    public var id: UUID {
        switch self {
        case .compressPDF(let id, _, _, _):
            return id
        case .splitPDF(let id, _, _, _):
            return id
        }
    }

    public static func == (lhs: ActiveWorkflowDialog, rhs: ActiveWorkflowDialog) -> Bool {
        lhs.id == rhs.id
    }
}
