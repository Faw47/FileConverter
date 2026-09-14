import SwiftUI
import AppKit
import FileConverterCore
import UniformTypeIdentifiers

public struct ConversionBatchSelection: Identifiable {
    public let id = UUID()
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }
}

public struct FileConverterMainView: View {
    @StateObject private var appState = AppState.shared
    @ObservedObject private var queue = ConversionQueue.shared
    private enum PresentedSheet: Identifiable {
        case presetSelection(ConversionBatchSelection)
        case conflictResolution([ConversionQueue.CollisionConflict])
        case pdfCompress(urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?)
        case pdfSplit(urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?)

        var id: String {
            switch self {
            case .presetSelection(let selection):
                return "preset-\(selection.id.uuidString)"
            case .conflictResolution:
                return "conflicts"
            case .pdfCompress(let urls, let preset, _):
                return "compress-\(preset.id)-\(urls.first?.path ?? "")"
            case .pdfSplit(let urls, let preset, _):
                return "split-\(preset.id)-\(urls.first?.path ?? "")"
            }
        }
    }

    @State private var batchSelection: ConversionBatchSelection? = nil
    @State private var presentedSheet: PresentedSheet? = nil
    @State private var conversionErrorDescription: String?
    @State private var dropTargeted = false
    @State private var presetSearchText = ""
    @State private var isEnqueuingSelection = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            ConversionQueueView()
                .environmentObject(appState)

            Divider()

            DropZoneView(onSelectFiles: openFilesDialog, isDropTargeted: $dropTargeted)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenFileConverterOpenPanel"))) { _ in
            openFilesDialog()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenFileConverterPresetPicker"))) { note in
            if let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty {
                let selection = ConversionBatchSelection(urls: urls)
                batchSelection = selection
                presentedSheet = .presetSelection(selection)
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
            ToolbarItemGroup(placement: .automatic) {
                Button(action: openFilesDialog) {
                    Label("Add Files...", systemImage: "plus.circle")
                }
                .help("Select files to convert (⌘O)")
                .accessibilityLabel("Add Files to Convert")

                if queue.completedCount > 0 || queue.failedCount > 0 || queue.cancelledCount > 0 {
                    Button(action: { queue.clearCompleted() }) {
                        Label("Clear", systemImage: "trash")
                    }
                    .help("Clear completed jobs (⌘K)")
                    .accessibilityLabel("Clear Completed Conversions")
                }

            }
        }
        .sheet(item: $presentedSheet, onDismiss: {
            presetSearchText = ""
            batchSelection = nil
        }) { sheet in
            switch sheet {
            case .presetSelection(let batch):
                presetSelectionSheet(for: batch.urls)
            case .conflictResolution(let conflicts):
                CollisionResolutionView(conflicts: conflicts) { decision, applyToAll in
                    queue.resolveCollisions(decision, applyToAll: applyToAll)
                    presentedSheet = nil
                }
                .frame(minWidth: 520, idealWidth: 620, minHeight: 360)
            case .pdfCompress(let urls, let preset, let leases):
                PDFCompressDialogView(
                    urls: urls,
                    initialPreset: preset,
                    onCancel: {
                        presentedSheet = nil
                    },
                    onStart: { customizedPreset in
                        presentedSheet = nil
                        startConversion(urls: urls, preset: customizedPreset, leases: leases)
                    }
                )
            case .pdfSplit(let urls, let preset, let leases):
                PDFSplitDialogView(
                    urls: urls,
                    initialPreset: preset,
                    onCancel: {
                        presentedSheet = nil
                    },
                    onStart: { customizedPreset in
                        presentedSheet = nil
                        startConversion(urls: urls, preset: customizedPreset, leases: leases)
                    }
                )
            }
        }
        .onChange(of: appState.activeWorkflowDialog) { _, dialog in
            guard let dialog else { return }
            switch dialog {
            case .compressPDF(let urls, let preset, let leases):
                presentedSheet = .pdfCompress(urls: urls, preset: preset, leases: leases)
            case .splitPDF(let urls, let preset, let leases):
                presentedSheet = .pdfSplit(urls: urls, preset: preset, leases: leases)
            }
            appState.activeWorkflowDialog = nil
        }
        .onChange(of: queue.pendingCollisions) { _, conflicts in
            if !conflicts.isEmpty {
                presentedSheet = .conflictResolution(conflicts)
            } else if case .conflictResolution = presentedSheet {
                presentedSheet = nil
            }
        }
        .onChange(of: appState.showSettings) { _, shouldShow in
            guard shouldShow else { return }
            openSettingsWindow()
            appState.showSettings = false
        }
        .alert(
            "Unable to Start Conversion",
            isPresented: Binding(
                get: { conversionErrorDescription != nil },
                set: { if !$0 { conversionErrorDescription = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversionErrorDescription ?? "The selected conversion is unavailable.")
        }
    }

    private func openSettingsWindow() {
        // Use the AppKit action so the package target also compiles with the
        // macOS 14 SDK, where SwiftUI's OpenSettingsAction is not exposed by
        // every installed toolchain. The Settings scene handles the action.
        NSApp?.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func presetSelectionSheet(for urls: [URL]) -> some View {
        let count = urls.count
        let compatible = PresetValidator.compatiblePresets(forURLs: urls)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert \(count) File\(count != 1 ? "s" : "")")
                        .font(.headline)
                    Text("Choose an output format preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    batchSelection = nil
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isEnqueuingSelection)
            }

            if !appState.backendDiscoveryComplete {
                Label("Checking optional conversion tools…", systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if count == 0 {
                Text("No files selected.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical)
            } else if compatible.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)

                    VStack(spacing: 4) {
                        Text("No Compatible Presets Found")
                            .font(.headline)
                        Text("None of your enabled presets accept these files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(urls.prefix(5), id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text(url.pathExtension.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if urls.count > 5 {
                            Text("+ \(urls.count - 5) more files")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                    .frame(maxWidth: 360)

                    Button("Manage Presets in Settings…") {
                        batchSelection = nil
                        appState.openSettings(tab: .presets)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                if isEnqueuingSelection {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Preparing conversion…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let grouped = PresetValidator.groupPresetsByCategory(compatible)
                TextField("Search compatible presets", text: $presetSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search compatible presets")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(grouped.keys.sorted(), id: \.self) { cat in
                            let presets = (grouped[cat] ?? []).filter { preset in
                                let query = presetSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                return query.isEmpty || preset.menuName.lowercased().contains(query) || preset.name.lowercased().contains(query)
                            }
                            if !presets.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(cat.displayName, systemImage: cat.systemImage)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)

                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                                        ForEach(presets) { preset in
                                            Button(action: {
                                                enqueueSelected(urls: urls, preset: preset)
                                            }) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    HStack {
                                                        Text(preset.menuName)
                                                            .font(.system(size: 13, weight: .semibold))
                                                        Spacer()
                                                        Text(preset.destinationFormat.uppercased())
                                                            .font(.system(size: 9, weight: .bold))
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 1)
                                                            .background(Color.accentColor.opacity(0.12))
                                                            .foregroundStyle(Color.accentColor)
                                                            .clipShape(.rect(cornerRadius: 3))
                                                    }

                                                    Text(preset.name)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color(nsColor: .controlBackgroundColor))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(isEnqueuingSelection)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 720, maxWidth: 960, minHeight: 420, idealHeight: 540)
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
            let valid = candidates.filter { url in
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? NSNumber else { return false }
                return size.int64Value > 0
            }
            guard !valid.isEmpty else {
                self.batchSelection = nil
                self.presentedSheet = nil
                self.conversionErrorDescription = "Folders, missing files, and zero-byte files cannot be converted."
                return
            }
            self.conversionErrorDescription = nil
            let selection = ConversionBatchSelection(urls: valid)
            self.batchSelection = selection
            self.presentedSheet = .presetSelection(selection)
        }
    }

    private func openFilesDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK && !panel.urls.isEmpty {
                let selection = ConversionBatchSelection(urls: panel.urls)
                self.batchSelection = selection
                self.presentedSheet = .presetSelection(selection)
            }
        }
    }

    private func enqueueSelected(urls: [URL], preset: ConversionPreset) {
        if preset.isPDFSplitWorkflow {
            presentedSheet = .pdfSplit(urls: urls, preset: preset, leases: nil)
            return
        }
        if preset.isPDFCompressWorkflow {
            presentedSheet = .pdfCompress(urls: urls, preset: preset, leases: nil)
            return
        }
        guard !isEnqueuingSelection else { return }
        isEnqueuingSelection = true
        Task {
            do {
                try await appState.convertFilesWhenReady(urls: urls, preset: preset)
                presentedSheet = nil
                batchSelection = nil
            } catch {
                presentedSheet = nil
                batchSelection = nil
                try? await Task.sleep(for: .milliseconds(150))
                conversionErrorDescription = error.localizedDescription
            }
            isEnqueuingSelection = false
        }
    }

    private func startConversion(urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?) {
        Task {
            do {
                try await appState.convertFilesWhenReady(urls: urls, preset: preset, leases: leases)
            } catch {
                try? await Task.sleep(for: .milliseconds(150))
                conversionErrorDescription = error.localizedDescription
            }
        }
    }
}

private struct CollisionResolutionView: View {
    let conflicts: [ConversionQueue.CollisionConflict]
    let onDecision: (ConversionQueue.CollisionDecision, Bool) -> Void
    @State private var applyToAll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Files already exist", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)

            Text("Choose what to do for each existing output. No file is changed until you choose.")
                .foregroundStyle(.secondary)

            List(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conflict.sourceFilename)
                        .font(.body.weight(.medium))
                    Text(conflict.destinationURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            Toggle("Apply this choice to all \(conflicts.count) conflicts", isOn: $applyToAll)
                .toggleStyle(.checkbox)

            HStack {
                Button(applyToAll ? "Skip All" : "Skip") { onDecision(.skip, applyToAll) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(applyToAll ? "Keep Both for All" : "Keep Both") { onDecision(.keepBoth, applyToAll) }
                    .keyboardShortcut(.defaultAction)
                Button(applyToAll ? "Replace All" : "Replace", role: .destructive) { onDecision(.replace, applyToAll) }
            }
        }
        .padding(22)
    }
}
