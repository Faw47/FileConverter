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
    @State private var presetSearchText = ""
    @State private var isEnqueuingSelection = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            if !appState.uncompletedJournalEntries.isEmpty {
                interruptedRecoveryBanner
            }

            ConversionQueueView()
                .environmentObject(appState)

            Divider()

            DropZoneView(onSelectFiles: openFilesDialog, isDropTargeted: $dropTargeted)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .background(MainWindowAccessor())
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 460)
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
            ToolbarItemGroup(placement: .automatic) {
                Button(action: openFilesDialog) {
                    Label("Add Files...", systemImage: "plus.circle")
                }
                .disabled(isAddFilesDisabled)
                .help(addFilesTooltip)
                .accessibilityLabel("Add Files to Convert")
                .accessibilityHint(isAddFilesDisabled ? "A dialog or workflow is open; requests are queued." : "Opens a file chooser.")

                if queue.hasClearableJobs {
                    Button(action: { queue.clearCompleted() }) {
                        Label("Clear Finished", systemImage: "trash")
                    }
                    .help("Clear finished jobs (⌘K)")
                    .accessibilityLabel("Clear Finished Conversions")
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Preferences and Settings (⌘,)")
                .accessibilityLabel("Open Settings")
            }
        }
        .sheet(item: Binding(
            get: { coordinator.currentPresentation },
            set: { if $0 == nil { coordinator.dismissCurrent() } }
        ), onDismiss: {
            presetSearchText = ""
            coordinator.advanceQueue()
        }) { item in
            switch item {
            case .batch(_, let urls, let excludedCount):
                presetSelectionSheet(for: urls, excludedCount: excludedCount)
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
        .onAppear {
            appState.openSettingsAction = {
                openSettings()
            }
        }
    }

    private func presetSelectionSheet(for urls: [URL], excludedCount: Int = 0) -> some View {
        var recognizedURLs: [URL] = []
        var excludedURLs: [URL] = []
        for url in urls {
            if FormatDetector.detect(url: url).format?.category != nil {
                recognizedURLs.append(url)
            } else {
                excludedURLs.append(url)
            }
        }
        let totalExcludedCount = excludedCount + excludedURLs.count
        let count = recognizedURLs.count
        let compatible = PresetValidator.compatiblePresets(forURLs: recognizedURLs)
        let categoryGroups = Dictionary(grouping: recognizedURLs) { url -> FormatCategory in
            FormatDetector.detect(url: url).format!.category
        }

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert \(count) File\(count != 1 ? "s" : "")")
                        .font(.headline)
                    if coordinator.pendingCount > 0 {
                        Text("\(coordinator.pendingCount) additional batch\(coordinator.pendingCount == 1 ? "" : "es") queued")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if totalExcludedCount > 0 {
                        Text("\(totalExcludedCount) item\(totalExcludedCount == 1 ? "" : "s") excluded (unsupported format, folders or empty files)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Choose an output format preset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") {
                    coordinator.dismissCurrent()
                    presetSearchText = ""
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isEnqueuingSelection)
            }

            if appState.isDiscoveringBackends, let status = appState.discoveryStatus {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Check") {
                        appState.cancelBackendDiscovery()
                    }
                    .controlSize(.mini)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if count == 0 {
                Text("No files selected.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical)
            } else if PresetStore.shared.state.isRecoveryRequired {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)

                    VStack(spacing: 4) {
                        Text("Preset Recovery Required")
                            .font(.headline)
                        Text("File Converter could not read your preset library. Please recover your presets in Settings before converting.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button("Open Preset Settings…") {
                        coordinator.dismissCurrent()
                        presetSearchText = ""
                        appState.openSettings(tab: .presets)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if compatible.isEmpty && categoryGroups.count > 1 {
                // TASK-058: Mixed-format batch admission
                VStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)

                    VStack(spacing: 4) {
                        Text("Mixed File Formats (\(urls.count) Files)")
                            .font(.headline)
                        Text("The selected files belong to different categories. Choose a subset to convert or process each category in turn:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 8) {
                        ForEach(Array(categoryGroups.keys.sorted()), id: \.self) { category in
                            let groupURLs = categoryGroups[category] ?? []
                            let groupCount = groupURLs.count
                            let categoryPresets = PresetValidator.compatiblePresets(forURLs: groupURLs)
                            HStack {
                                Image(systemName: category.systemImage)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(category.displayName) (\(groupCount) file\(groupCount == 1 ? "" : "s"))")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("\(categoryPresets.count) compatible preset\(categoryPresets.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Convert \(category.displayName)") {
                                    coordinator.dismissCurrent()
                                    coordinator.enqueue(.batch(urls: groupURLs, excludedCount: 0))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(categoryPresets.isEmpty)
                            }
                            .padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(maxWidth: 420)

                    HStack(spacing: 12) {
                        Button("Convert All Groups in Turn") {
                            coordinator.dismissCurrent()
                            for category in categoryGroups.keys.sorted() {
                                if let group = categoryGroups[category], !group.isEmpty {
                                    coordinator.enqueue(.batch(urls: group, excludedCount: 0))
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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
                        coordinator.dismissCurrent()
                        presetSearchText = ""
                        appState.openSettings(tab: .presets)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                let grouped = PresetValidator.groupPresetsByCategory(compatible)
                let query = presetSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let filteredGrouped = grouped.compactMapValues { presets in
                    presets.filter { preset in
                        query.isEmpty || preset.menuName.lowercased().contains(query) || preset.name.lowercased().contains(query)
                    }
                }
                TextField("Search compatible presets", text: $presetSearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search compatible presets")
                ScrollView {
                    if filteredGrouped.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Presets", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try a different search term.")
                        } actions: {
                            Button("Clear Search") {
                                presetSearchText = ""
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(FormatCategory.allCases) { category in
                                if let presets = filteredGrouped[category], !presets.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label(category.displayName, systemImage: category.systemImage)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                                            ForEach(presets) { preset in
                                                Button(action: {
                                                    enqueueSelected(urls: urls, preset: preset)
                                                }) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        HStack {
                                                            Text(preset.menuName)
                                                                .font(.system(size: 12, weight: .medium))
                                                                .lineLimit(1)
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
                    }
                }
                .padding(.trailing, 4)
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

    private var isAddFilesDisabled: Bool {
        coordinator.isPresenting
    }

    private var addFilesTooltip: String {
        if coordinator.isPresenting {
            return "Close the current dialog to add files"
        }
        return "Add files to convert"
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

    private func enqueueSelected(urls: [URL], preset: ConversionPreset) {
        if preset.isPDFSplitWorkflow {
            coordinator.enqueue(.pdfSplit(urls: urls, preset: preset, leases: nil))
            return
        }
        if preset.isPDFCompressWorkflow {
            coordinator.enqueue(.pdfCompress(urls: urls, preset: preset, leases: nil))
            return
        }
        guard !isEnqueuingSelection else { return }
        isEnqueuingSelection = true
        coordinator.dismissCurrent()
        Task {
            do {
                try await appState.convertFilesWhenReady(urls: urls, preset: preset)
            } catch {
                await MainActor.run {
                    self.conversionErrorDescription = error.localizedDescription
                }
            }
            await MainActor.run {
                self.isEnqueuingSelection = false
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

    private var interruptedRecoveryBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Interrupted Conversions Detected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Dismiss All") {
                    appState.dismissAllJournalRecovery()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Dismiss interrupted conversion alerts")
            }
            Text("\(appState.uncompletedJournalEntries.count) conversion(s) were in progress when the app was previously terminated. Check your destination folders for partial outputs before re-converting.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}
