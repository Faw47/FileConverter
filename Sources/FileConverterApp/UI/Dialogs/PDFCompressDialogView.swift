import SwiftUI
import PDFKit
import FileConverterCore
import UniformTypeIdentifiers

/// Options for "Compress PDF". Shows only what the engine that will run
/// (Ghostscript when installed, otherwise macOS) actually honors.
public struct PDFCompressDialogView: View {
    let initialPreset: ConversionPreset
    let onCancel: () -> Void
    let onStart: (ConversionPreset, [URL]) -> Void

    @State private var currentURLs: [URL]
    @State private var isDropTargeted = false

    public enum CompressionProfile: String, CaseIterable, Identifiable {
        case smaller = "Smallest file"
        case balanced = "Balanced"
        case quality = "Higher quality"

        public var id: String { rawValue }

        var ghostscriptName: String {
            switch self {
            case .smaller: return "screen"
            case .balanced: return "ebook"
            case .quality: return "printer"
            }
        }

        var defaultDPI: Int {
            switch self {
            case .smaller: return 96
            case .balanced: return 150
            case .quality: return 300
            }
        }

        var defaultQuality: Double {
            switch self {
            case .smaller: return 0.5
            case .balanced: return 0.7
            case .quality: return 0.85
            }
        }

        static func from(_ raw: String?) -> CompressionProfile {
            switch raw?.lowercased() {
            case "screen": return .smaller
            case "printer", "prepress": return .quality
            default: return .balanced
            }
        }
    }

    @State private var profile: CompressionProfile
    @State private var flattenPages: Bool
    @State private var grayscale: Bool
    @State private var pageDPI: Int
    @State private var imageQuality: Double
    @State private var removeMetadata: Bool
    @State private var removeAnnotations: Bool
    @State private var linearize: Bool
    @State private var nameEnding: String
    @State private var customOutputDirectory: URL?

    public init(
        urls: [URL],
        initialPreset: ConversionPreset,
        onCancel: @escaping () -> Void,
        onStart: @escaping (ConversionPreset, [URL]) -> Void
    ) {
        self._currentURLs = State(initialValue: urls)
        self.initialPreset = initialPreset
        self.onCancel = onCancel
        self.onStart = onStart

        let opts = initialPreset.processingOptions
        let profile = CompressionProfile.from(opts?.pdfCompressionProfile)
        self._profile = State(initialValue: profile)
        self._flattenPages = State(initialValue: opts?.pdfFlattenToImages ?? false)
        self._grayscale = State(initialValue: opts?.pdfColorMode == "grayscale" || opts?.pdfColorMode == "monochrome")
        self._pageDPI = State(initialValue: opts?.pdfDPI ?? profile.defaultDPI)
        self._imageQuality = State(initialValue: opts?.pdfImageQuality ?? profile.defaultQuality)
        self._removeMetadata = State(initialValue: opts?.pdfRemoveMetadata ?? false)
        self._removeAnnotations = State(initialValue: opts?.pdfRemoveAnnotations ?? false)
        self._linearize = State(initialValue: opts?.pdfLinearize ?? true)

        let pattern = initialPreset.filenamePattern
        let ending: String
        if !initialPreset.resolvedInheritance.filenamePattern, pattern.hasPrefix("{name}"), pattern.count > "{name}".count {
            ending = String(pattern.dropFirst("{name}".count))
        } else {
            ending = "-" + (initialPreset.sameFormatSuffix ?? "compressed")
        }
        self._nameEnding = State(initialValue: ending)

        var customDir: URL?
        if !initialPreset.resolvedInheritance.outputLocation,
           case .customFolder(let bookmark, let displayPath) = initialPreset.outputDirectoryPolicy {
            var isStale = false
            if !bookmark.isEmpty, let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                customDir = resolved
            } else if !displayPath.isEmpty {
                customDir = URL(fileURLWithPath: displayPath)
            }
        }
        self._customOutputDirectory = State(initialValue: customDir)
    }

    public init(
        urls: [URL],
        initialPreset: ConversionPreset,
        onCancel: @escaping () -> Void,
        onStart: @escaping (ConversionPreset) -> Void
    ) {
        self.init(urls: urls, initialPreset: initialPreset, onCancel: onCancel, onStart: { preset, _ in onStart(preset) })
    }

    private var firstURL: URL? { currentURLs.first }

    @State private var cachedTotalSize: Int64 = 0
    @State private var cachedPageCount: Int?
    @State private var isDocumentLocked = false
    @State private var isLoadingStats = true
    @State private var dropErrorMessage: String?

    /// Ghostscript runs when it is installed and the preset allows it.
    private var usesGhostscript: Bool {
        guard let pdf = FormatRegistry.shared.format(forID: "pdf") else { return false }
        return BackendResolver.shared.evaluate(preset: initialPreset, sourceFormat: pdf) == .usable(.ghostscript)
    }

    private var showsImageControls: Bool {
        usesGhostscript || flattenPages
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            Form {
                Section {
                    Picker("Compression", selection: $profile) {
                        ForEach(CompressionProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Compression level")
                    .onChange(of: profile) { _, newValue in
                        pageDPI = newValue.defaultDPI
                        imageQuality = newValue.defaultQuality
                    }

                    if !usesGhostscript {
                        Toggle("Turn pages into images", isOn: $flattenPages)
                            .accessibilityLabel("Turn pages into images")
                    }

                    if showsImageControls {
                        Toggle("Convert to grayscale", isOn: $grayscale)
                            .accessibilityLabel("Convert to grayscale")
                        Picker("Image resolution", selection: $pageDPI) {
                            ForEach([72, 96, 150, 200, 300], id: \.self) { dpi in
                                Text("\(dpi) dpi").tag(dpi)
                            }
                        }
                        .accessibilityLabel("Image resolution in dots per inch")
                        if flattenPages && !usesGhostscript {
                            LabeledContent("Image quality") {
                                HStack {
                                    Slider(value: $imageQuality, in: 0.3...1.0, step: 0.05)
                                        .accessibilityLabel("JPEG image quality")
                                        .accessibilityValue("\(Int(imageQuality * 100)) percent")
                                    Text("\(Int(imageQuality * 100))%")
                                        .monospacedDigit()
                                        .frame(width: 40, alignment: .trailing)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Compression")
                } footer: {
                    FooterText(compressionFooter)
                }

                Section("Clean Up") {
                    Toggle("Remove document details (author, title, keywords)", isOn: $removeMetadata)
                        .accessibilityLabel("Remove document details")
                    Toggle("Remove comments and highlights", isOn: $removeAnnotations)
                        .accessibilityLabel("Remove comments and highlights")
                    if usesGhostscript {
                        Toggle("Optimize for fast web viewing", isOn: $linearize)
                            .accessibilityLabel("Optimize for fast web viewing")
                    }
                }

                Section {
                    LabeledContent("Name ending") {
                        TextField("Name ending", text: $nameEnding, prompt: Text("-compressed"))
                            .frame(maxWidth: 160)
                            .accessibilityLabel("Filename ending")
                    }
                    LabeledContent("Save to") {
                        HStack {
                            Text(customOutputDirectory.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                                ?? DestinationDescription.folder(for: initialPreset))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Change…") { chooseOutputDirectory() }
                                .accessibilityLabel("Change output folder")
                            if customOutputDirectory != nil {
                                Button("Use Default") { customOutputDirectory = nil }
                                    .accessibilityLabel("Use the default output folder")
                            }
                        }
                    }
                } header: {
                    Text("Saving")
                } footer: {
                    FooterText("Example: \(exampleName). If the result is not smaller, nothing is saved.")
                }
            }
            .formStyle(.grouped)

            Divider()

            footerView
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 480, idealHeight: 600)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .task {
            recalculateStats()
        }
        .alert("Cannot Add PDF", isPresented: Binding(
            get: { dropErrorMessage != nil },
            set: { if !$0 { dropErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(dropErrorMessage ?? "Only readable PDF files can be added.")
        }
    }

    private var compressionFooter: String {
        if usesGhostscript {
            return "Uses Ghostscript. Text and drawings stay sharp; images are resampled."
        }
        if flattenPages {
            return "Each page becomes one image, which gives the smallest file. Text is recognized on this Mac so it stays searchable."
        }
        return "Shrinks the images inside the PDF. Text, links, and bookmarks are kept. Install Ghostscript for stronger compression that keeps text sharp."
    }

    private var exampleName: String {
        let base = firstURL?.deletingPathExtension().lastPathComponent ?? "Document"
        return OutputNamingEngine.previewFilename(
            pattern: "{name}" + cleanedEnding,
            sourceName: base,
            sourceExtension: "pdf",
            targetExtension: "pdf",
            presetMenuName: initialPreset.menuName
        )
    }

    private var cleanedEnding: String {
        let trimmed = nameEnding.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: AppSettings.invalidPatternCharacters).joined()
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let collector = DropURLCollector()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    if let url { collector.store(url, at: index) }
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
            let candidates = collector.orderedURLs()
            let dropped = candidates.filter { url in
                guard url.pathExtension.lowercased() == "pdf" else { return false }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
                return true
            }
            guard !dropped.isEmpty else {
                self.dropErrorMessage = "Only readable PDF files can be added to this workflow."
                return
            }
            if dropped.count < candidates.count {
                self.dropErrorMessage = "Some dropped items were ignored. Only readable PDF files can be added."
            }
            var updated = self.currentURLs
            for url in dropped {
                if !updated.contains(where: { $0.path == url.path }) {
                    updated.append(url)
                }
            }
            self.currentURLs = updated
            self.recalculateStats()
        }
        return true
    }

    private func recalculateStats() {
        let files = currentURLs
        isLoadingStats = true
        Task {
            let stats = await Task.detached {
                let size = files.reduce(Int64(0)) { total, url in
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return total + Int64(fileSize)
                }
                let documents = files.compactMap { PDFDocument(url: $0) }
                let firstPageCount = documents.first?.pageCount
                let anyLocked = documents.contains(where: { $0.isLocked }) || documents.count != files.count
                return (size, firstPageCount, anyLocked)
            }.value
            await MainActor.run {
                guard self.currentURLs == files else { return }
                self.cachedTotalSize = stats.0
                self.cachedPageCount = stats.1
                self.isDocumentLocked = stats.2
                self.isLoadingStats = false
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(currentURLs.count == 1 ? (firstURL?.lastPathComponent ?? "PDF Document") : "\(currentURLs.count) PDF Documents")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statsText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDropTargeted {
                Label("Drop to add PDFs", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var statsText: String {
        if isLoadingStats { return "Reading PDF…" }
        let size = ByteCountFormatter.string(fromByteCount: cachedTotalSize, countStyle: .file)
        guard let pages = cachedPageCount else { return size }
        if currentURLs.count == 1 {
            return "\(size) · \(pages) page\(pages == 1 ? "" : "s")"
        }
        return "\(size) total"
    }

    // MARK: - Footer
    private var footerView: some View {
        VStack(spacing: 8) {
            if isDocumentLocked {
                Label("This PDF is password-protected. Locked documents cannot be compressed.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel compression")

                Spacer()

                Button(currentURLs.count == 1 ? "Compress" : "Compress \(currentURLs.count) PDFs") {
                    startCompression()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingStats || cachedPageCount == nil || isDocumentLocked)
                .accessibilityLabel("Start PDF compression")
            }
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            customOutputDirectory = panel.url
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func startCompression() {
        var preset = initialPreset
        var options = preset.processingOptions ?? ConversionProcessingOptions()
        options.pdfCompressionProfile = profile.ghostscriptName
        options.pdfFlattenToImages = !usesGhostscript && flattenPages
        options.pdfDPI = showsImageControls ? pageDPI : nil
        options.pdfImageQuality = options.pdfFlattenToImages ? imageQuality : nil
        options.pdfColorMode = showsImageControls && grayscale ? "grayscale" : "color"
        options.pdfRemoveMetadata = removeMetadata
        options.pdfRemoveAnnotations = removeAnnotations
        options.pdfRemoveThumbnails = usesGhostscript
        options.pdfLinearize = usesGhostscript && linearize
        preset.processingOptions = options

        // The dialog's choices are this run's own values, not General ones.
        var inheritance = preset.resolvedInheritance
        inheritance.filenamePattern = false
        preset.filenamePattern = "{name}" + (cleanedEnding.isEmpty ? "-compressed" : cleanedEnding)
        preset.sameFormatSuffix = nil

        if let customOutputDirectory {
            let bookmark = (try? customOutputDirectory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? customOutputDirectory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
            if let bookmark {
                preset.outputDirectoryPolicy = .customFolder(bookmarkData: bookmark, displayPath: customOutputDirectory.path)
                inheritance.outputLocation = false
            }
        }
        preset.inheritance = inheritance

        onStart(preset, currentURLs)
    }
}
