import SwiftUI
import AppKit
import FileConverterCore
import UniformTypeIdentifiers

public struct ConversionBatchSelection: Identifiable {
    public let id = UUID()
    public let urls: [URL]
    public let excludedCount: Int

    public init(urls: [URL], excludedCount: Int = 0) {
        self.urls = urls
        self.excludedCount = excludedCount
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.isReleasedWhenClosed = false
                window.identifier = NSUserInterfaceItemIdentifier("FileConverterMainWindow")
                MainWindowTracker.shared.mainWindow = window
                if AppDelegate.shared?.isHeadless == true {
                    window.orderOut(nil)
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("FileConverterMainWindow")
            MainWindowTracker.shared.mainWindow = window
        }
    }
}

public struct FileConverterMainView: View {
    @StateObject private var appState = AppState.shared
    @ObservedObject private var queue = ConversionQueue.shared
    @ObservedObject private var coordinator = WorkflowPresentationCoordinator.shared
    @Environment(\.openSettings) private var openSettings

    @State private var conversionErrorDescription: String?
    @State private var dropTargeted = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if !appState.uncompletedJournalEntries.isEmpty {
                interruptedRecoveryBanner
            }

            if queue.jobs.isEmpty {
                DropZoneView(onSelectFiles: openFilesDialog, isDropTargeted: $dropTargeted)
                    .padding(20)
            } else {
                ConversionQueueView()
                    .environmentObject(appState)
            }
        }
        .overlay {
            if dropTargeted && !queue.jobs.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop to convert", systemImage: "arrow.down.doc").font(.title3))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background(MainWindowAccessor())
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenFileConverterOpenPanel"))) { _ in
            openFilesDialog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenFileConverterPresetPicker"))) { note in
            if let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty {
                coordinator.enqueue(.batch(urls: urls, excludedCount: 0))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenFileConverterWorkflowDialog"))) { note in
            if let preset = note.userInfo?["preset"] as? ConversionPreset,
               let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty {
                let leases = note.userInfo?["leases"] as? [SecurityScopedLease]
                appState.presentWorkflowDialog(preset: preset, urls: urls, leases: leases)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDroppedProviders(providers)
            return !providers.isEmpty
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: openFilesDialog) {
                    Label("Add Files…", systemImage: "plus")
                }
                .help(coordinator.isPresenting ? "Finish the open dialog first; your files will be added next" : "Choose files to convert (⌘O)")
                .accessibilityLabel("Add Files to Convert")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
                .accessibilityLabel("Open Settings")
            }
        }
        .sheet(item: Binding(
            get: { coordinator.currentPresentation },
            set: { if $0 == nil { coordinator.dismissCurrent() } }
        ), onDismiss: {
            coordinator.advanceQueue()
        }) { item in
            switch item {
            case .batch(_, let urls, let excludedCount):
                PresetPickerView(
                    urls: urls,
                    excludedCount: excludedCount,
                    pendingBatches: coordinator.pendingCount,
                    onCancel: { coordinator.dismissCurrent() },
                    onConvert: { work in
                        coordinator.dismissCurrent()
                        convert(work)
                    },
                    onManagePresets: {
                        coordinator.dismissCurrent()
                        appState.openSettings(tab: .presets)
                    }
                )
            case .conflictResolution:
                CollisionResolutionView(queue: queue) {
                    coordinator.dismissCurrent()
                }
            case .pdfCompress(_, let urls, let preset, let leases):
                PDFCompressDialogView(
                    urls: urls,
                    initialPreset: preset,
                    onCancel: {
                        leases?.forEach { $0.release() }
                        coordinator.dismissCurrent()
                    },
                    onStart: { customizedPreset, finalURLs in
                        coordinator.dismissCurrent()
                        startConversion(urls: finalURLs, preset: customizedPreset, leases: leases)
                    }
                )
            case .pdfSplit(_, let urls, let preset, let leases):
                PDFSplitDialogView(
                    urls: urls,
                    initialPreset: preset,
                    onCancel: {
                        leases?.forEach { $0.release() }
                        coordinator.dismissCurrent()
                    },
                    onStart: { customizedPreset, finalURLs in
                        coordinator.dismissCurrent()
                        startConversion(urls: finalURLs, preset: customizedPreset, leases: leases)
                    }
                )
            }
        }
        .onChange(of: queue.pendingCollisions.isEmpty) { _, isEmpty in
            // The sheet reads conflicts live; it only needs opening when the
            // list goes from empty to non-empty.
            if !isEmpty {
                coordinator.enqueue(.conflictResolution())
            }
        }
        .alert(
            "Could Not Start Converting",
            isPresented: Binding(
                get: { conversionErrorDescription != nil },
                set: { if !$0 { conversionErrorDescription = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversionErrorDescription ?? "")
        }
        .onAppear {
            appState.openSettingsAction = {
                openSettings()
            }
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        let collector = DropURLCollector()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    if let url = url {
                        collector.store(url, at: index)
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        collector.store(url, at: index)
                    } else if let nsURL = item as? NSURL {
                        collector.store(nsURL as URL, at: index)
                    } else if let data = item as? Data {
                        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           let url = URL(string: str), url.isFileURL {
                            collector.store(url, at: index)
                        } else if let url = URL(dataRepresentation: data, relativeTo: nil) {
                            collector.store(url, at: index)
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            let candidates = collector.orderedURLs().filter { !$0.path.isEmpty }
            self.processCandidateURLs(candidates)
        }
    }

    private func processCandidateURLs(_ candidates: [URL]) {
        let candidates = candidates.filter { !$0.path.isEmpty }
        guard !candidates.isEmpty else { return }

        var directoryCount = 0
        var missingCount = 0
        var zeroByteCount = 0
        var valid: [URL] = []

        for url in candidates {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                missingCount += 1
                continue
            }
            if isDirectory.boolValue {
                let ext = url.pathExtension.lowercased()
                let utType = UTType(filenameExtension: ext)
                let isPackage = utType?.conforms(to: .package) == true || ["pages", "numbers", "key", "keynote"].contains(ext)
                if !isPackage {
                    directoryCount += 1
                    continue
                }
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0 else {
                zeroByteCount += 1
                continue
            }
            valid.append(url)
        }

        guard !valid.isEmpty else {
            if directoryCount == candidates.count {
                self.conversionErrorDescription = "Folders cannot be converted directly. Drop individual files instead."
            } else if missingCount == candidates.count {
                self.conversionErrorDescription = "Some files could not be found."
            } else if zeroByteCount == candidates.count {
                self.conversionErrorDescription = "Empty files cannot be converted."
            } else {
                self.conversionErrorDescription = "Folders, missing files, and zero-byte files cannot be converted."
            }
            return
        }

        self.conversionErrorDescription = nil
        let excludedCount = candidates.count - valid.count
        coordinator.enqueue(.batch(urls: valid, excludedCount: excludedCount))
    }

    private func openFilesDialog() {
        if coordinator.isPresenting {
            coordinator.queueAddFiles()
            return
        }
        coordinator.isOpenPanelPresented = true
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            self.coordinator.isOpenPanelPresented = false
            if response == .OK && !panel.urls.isEmpty {
                self.processCandidateURLs(panel.urls)
            } else {
                self.coordinator.advanceQueue()
            }
        }

        if let window = MainWindowTracker.shared.mainWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Starts each (files, preset) pair; PDF compress/split open their dialog.
    private func convert(_ work: [(urls: [URL], preset: ConversionPreset)]) {
        for item in work {
            if item.preset.isPDFSplitWorkflow {
                coordinator.enqueue(.pdfSplit(urls: item.urls, preset: item.preset, leases: nil))
            } else if item.preset.isPDFCompressWorkflow {
                coordinator.enqueue(.pdfCompress(urls: item.urls, preset: item.preset, leases: nil))
            } else {
                startConversion(urls: item.urls, preset: item.preset, leases: nil)
            }
        }
    }

    private func startConversion(urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?) {
        Task {
            do {
                try await appState.convertFilesWhenReady(urls: urls, preset: preset, leases: leases)
            } catch {
                await MainActor.run {
                    self.conversionErrorDescription = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Interrupted conversions

    private var interruptedRecoveryBanner: some View {
        let entries = appState.uncompletedJournalEntries
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    entries.count == 1 ? "A conversion was interrupted" : "\(entries.count) conversions were interrupted",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                Spacer()
                Button("Dismiss All") { appState.dismissAllJournalRecovery() }
                    .accessibilityLabel("Dismiss interrupted conversion alerts")
            }
            Text("File Converter quit while these were converting. No unfinished files were saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(entries.prefix(5)) { entry in
                let source = URL(fileURLWithPath: entry.sourceURLPath)
                HStack(spacing: 8) {
                    Text(source.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(entry.presetName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Show Original") {
                        NSWorkspace.shared.activateFileViewerSelecting([source])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: source.path))
                    Button("Convert Again") {
                        if let preset = PresetStore.shared.preset(forID: entry.presetID) {
                            startConversion(urls: [source], preset: preset, leases: nil)
                        }
                        appState.dismissJournalRecovery(entryID: entry.id)
                    }
                    .disabled(PresetStore.shared.preset(forID: entry.presetID) == nil
                        || !FileManager.default.fileExists(atPath: source.path))
                    Button("Dismiss") { appState.dismissJournalRecovery(entryID: entry.id) }
                }
                .font(.caption)
            }
            if entries.count > 5 {
                Text("and \(entries.count - 5) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
