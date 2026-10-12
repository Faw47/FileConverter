import SwiftUI
import PDFKit
import FileConverterCore
import UniformTypeIdentifiers

public struct PDFCompressDialogView: View {
    let initialPreset: ConversionPreset
    let onCancel: () -> Void
    let onStart: (ConversionPreset, [URL]) -> Void

    @State private var currentURLs: [URL]
    @State private var isDropTargeted = false

    public enum CompressionProfile: String, CaseIterable, Identifiable {
        case web = "Web & Email"
        case ebook = "eBook & Balanced"
        case print = "High Quality Print"
        case prepress = "Prepress / Lossless"
        case custom = "Custom"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .web: return "bolt.fill"
            case .ebook: return "book.fill"
            case .print: return "printer.fill"
            case .prepress: return "sparkles"
            case .custom: return "slider.horizontal.3"
            }
        }

        public var subtitle: String {
            switch self {
            case .web: return "72 DPI • Maximum compression"
            case .ebook: return "150 DPI • Balanced size & clarity"
            case .print: return "300 DPI • Crisp text & high resolution"
            case .prepress: return "300 DPI • High-fidelity raster (not vector-lossless)"
            case .custom: return "Fine-tune DPI, quality, and color"
            }
        }
    }

    public enum ColorMode: String, CaseIterable, Identifiable {
        case color = "Keep Color"
        case grayscale = "Grayscale"
        case monochrome = "Black & White (1-bit)"

        public var id: String { rawValue }
    }

    @State private var selectedProfile: CompressionProfile = .ebook
    @State private var colorMode: ColorMode = .color
    @State private var targetDPI: Int = 150
    @State private var imageQuality: Double = 0.70
    @State private var removeMetadata: Bool = true
    @State private var removeAnnotations: Bool = false
    @State private var removeThumbnails: Bool = true
    @State private var linearize: Bool = true
    @State private var filenameSuffix: String = "_compressed"
    @State private var customOutputDirectory: URL? = nil

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
        let profile: CompressionProfile = {
            guard let raw = opts?.pdfCompressionProfile?.lowercased() else { return .ebook }
            switch raw {
            case "screen": return .web
            case "ebook": return .ebook
            case "printer": return .print
            case "prepress": return .prepress
            case "custom": return .custom
            default: return .ebook
            }
        }()
        self._selectedProfile = State(initialValue: profile)

        let mode: ColorMode = {
            guard let raw = opts?.pdfColorMode?.lowercased() else { return .color }
            switch raw {
            case "grayscale": return .grayscale
            case "monochrome": return .monochrome
            default: return .color
            }
        }()
        self._colorMode = State(initialValue: mode)
        self._targetDPI = State(initialValue: opts?.pdfDPI ?? 150)
        self._imageQuality = State(initialValue: opts?.pdfImageQuality ?? 0.70)
        self._removeMetadata = State(initialValue: opts?.pdfRemoveMetadata ?? true)
        self._removeAnnotations = State(initialValue: opts?.pdfRemoveAnnotations ?? false)
        self._removeThumbnails = State(initialValue: opts?.pdfRemoveThumbnails ?? true)
        self._linearize = State(initialValue: opts?.pdfLinearize ?? true)

        let pattern = initialPreset.filenamePattern
        let suffix: String
        if pattern.hasPrefix("{name}") {
            suffix = String(pattern.dropFirst("{name}".count))
        } else if pattern.isEmpty {
            suffix = "_compressed"
        } else {
            suffix = pattern
        }
        self._filenameSuffix = State(initialValue: suffix.isEmpty ? "_compressed" : suffix)

        var customDir: URL? = nil
        if case .customFolder(let bookmark, let displayPath) = initialPreset.outputDirectoryPolicy {
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
    private var totalOriginalSize: Int64 { cachedTotalSize }

    @State private var cachedPageCount: Int? = nil
    @State private var isDocumentLocked: Bool = false
    @State private var isLoadingStats = true
    @State private var dropErrorMessage: String?

    private var pageCountText: String {
        guard let count = cachedPageCount else { return "" }
        if currentURLs.count == 1 {
            return "\(count) pages"
        } else {
            return "\(count) pages in first file • \(currentURLs.count) files selected"
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profileSelectionSection

                    // Native compression always rasterizes; never label as lossless.
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.orange)
                        Text("Native compression rasterizes pages to images. Install Ghostscript for lossless vector output.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))

                    if selectedProfile == .custom {
                        customSettingsSection
                    }

                    optimizationSection

                    outputDestinationSection
                }
                .padding(24)
            }

            Divider()

            // Footer
            footerView
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 480, maxHeight: 680)
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
            Text(dropErrorMessage ?? "Only readable PDF files can be added to this workflow.")
        }
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
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(currentURLs.count == 1 ? (firstURL?.lastPathComponent ?? "PDF Document") : "\(currentURLs.count) PDF Documents")
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if isLoadingStats {
                        Text("Reading PDF…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: totalOriginalSize, countStyle: .file))
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if !pageCountText.isEmpty {
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(pageCountText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Spacer()
            if isDropTargeted {
                Label("Drop to add PDFs", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Profile Selection
    private var profileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compression Preset")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(CompressionProfile.allCases) { profile in
                    Button(action: {
                        selectedProfile = profile
                        applyProfileSettings(profile)
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: profile.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 24)
                                .foregroundColor(selectedProfile == profile ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)

                                Text(profile.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if selectedProfile == profile {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 16))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedProfile == profile ? Color.accentColor.opacity(0.1) : Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selectedProfile == profile ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(profile.rawValue) profile")
                    .accessibilityHint(profile.subtitle)
                }
            }
        }
    }

    // MARK: - Custom Settings
    private var customSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom Quality Controls")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Color Mode:")
                        .frame(width: 140, alignment: .leading)
                    Picker("Color Mode", selection: $colorMode) {
                        ForEach(ColorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Color Mode")
                }

                HStack {
                    Text("Target Resolution:")
                        .frame(width: 140, alignment: .leading)
                    Picker("Target Resolution", selection: $targetDPI) {
                        Text("72 DPI (Web)").tag(72)
                        Text("96 DPI (Email)").tag(96)
                        Text("150 DPI (eBook)").tag(150)
                        Text("200 DPI (Medium)").tag(200)
                        Text("300 DPI (Print)").tag(300)
                    }
                    .labelsHidden()
                    .accessibilityLabel("Target Resolution in DPI")
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("JPEG Quality:")
                            .frame(width: 140, alignment: .leading)
                        Slider(value: $imageQuality, in: 0.1...1.0, step: 0.05)
                            .accessibilityLabel("JPEG Image Quality")
                            .accessibilityValue("\(Int(imageQuality * 100)) percent")
                        Text("\(Int(imageQuality * 100))%")
                            .frame(width: 45, alignment: .trailing)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                    Text("Native compression does not enforce PDF compatibility levels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Optimization Toggles
    private var optimizationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Document Cleanup & Optimization")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Remove metadata (author, title, creation timestamps)", isOn: $removeMetadata)
                    .accessibilityLabel("Remove metadata")
                Toggle("Remove annotations, comments, and highlights", isOn: $removeAnnotations)
                    .accessibilityLabel("Remove annotations")
                Toggle("Remove embedded page thumbnails", isOn: $removeThumbnails)
                    .accessibilityLabel("Remove embedded page thumbnails")
                Toggle("Linearize for fast web view (streamable page delivery)", isOn: $linearize)
                    .accessibilityLabel("Linearize for fast web view")
            }
            .font(.subheadline)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Output Destination
    private var outputDestinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output Options")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Filename Suffix:")
                        .frame(width: 120, alignment: .leading)
                    TextField("Filename suffix", text: $filenameSuffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .accessibilityLabel("Filename suffix")
                    Text("e.g. document\(filenameSuffix).pdf")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                HStack {
                    Text("Save to:")
                        .frame(width: 120, alignment: .leading)
                    if let dir = customOutputDirectory {
                        Text(dir.path)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(dir.path)
                        Button("Change...") { chooseOutputDirectory() }
                            .accessibilityLabel("Change output folder")
                        Button("Reset") { customOutputDirectory = nil }
                            .accessibilityLabel("Reset output folder to preset default")
                    } else {
                        Text("Same folder as original")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Button("Choose Folder...") { chooseOutputDirectory() }
                            .accessibilityLabel("Choose custom output folder")
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Footer
    private var footerView: some View {
        VStack(spacing: 8) {
            if isDocumentLocked {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.red)
                    Text("This PDF is password-protected or locked. Encrypted documents cannot be compressed.")
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel compression")

                Spacer()

                Button("Compress PDF") {
                    startCompression()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingStats || cachedPageCount == nil || isDocumentLocked)
                .accessibilityLabel("Start PDF compression")
            }
        }
    }

    private func applyProfileSettings(_ profile: CompressionProfile) {
        switch profile {
        case .web:
            targetDPI = 72
            imageQuality = 0.45
            colorMode = .color
            removeMetadata = true
            removeThumbnails = true
            linearize = true
        case .ebook:
            targetDPI = 150
            imageQuality = 0.70
            colorMode = .color
            removeMetadata = true
            removeThumbnails = true
            linearize = true
        case .print:
            targetDPI = 300
            imageQuality = 0.85
            colorMode = .color
            removeMetadata = false
            removeThumbnails = false
            linearize = false
        case .prepress:
            targetDPI = 300
            imageQuality = 0.95
            colorMode = .color
            removeMetadata = false
            removeThumbnails = false
            linearize = false
        case .custom:
            break
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
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

        let profileName: String = {
            switch selectedProfile {
            case .web: return "screen"
            case .ebook: return "ebook"
            case .print: return "printer"
            case .prepress: return "prepress"
            case .custom: return "custom"
            }
        }()

        options.pdfCompressionProfile = profileName
        options.pdfDPI = targetDPI
        options.pdfImageQuality = imageQuality
        options.pdfColorMode = {
            switch colorMode {
            case .color: return "color"
            case .grayscale: return "grayscale"
            case .monochrome: return "monochrome"
            }
        }()
        options.pdfRemoveMetadata = removeMetadata
        options.pdfRemoveAnnotations = removeAnnotations
        options.pdfRemoveThumbnails = removeThumbnails
        options.pdfLinearize = linearize
        // Preserve a compatibility level selected by the preset/editor. The
        // native PDFKit backend will report that it cannot enforce it, while
        // Ghostscript consumes the value when it is available.

        preset.processingOptions = options
        if filenameSuffix.hasPrefix("{name}") {
            preset.filenamePattern = filenameSuffix
        } else {
            preset.filenamePattern = "{name}\(filenameSuffix)"
        }

        if let customOutputDirectory {
            if let bookmark = try? customOutputDirectory.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                preset.outputDirectoryPolicy = .customFolder(bookmarkData: bookmark, displayPath: customOutputDirectory.path)
            } else if let fallbackBookmark = try? customOutputDirectory.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                preset.outputDirectoryPolicy = .customFolder(bookmarkData: fallbackBookmark, displayPath: customOutputDirectory.path)
            }
        } else if case .customFolder = initialPreset.outputDirectoryPolicy {
            // Keep unchanged custom folder
        } else {
            // Retain original directory policy (e.g. .sameAsSource, .downloads)
            preset.outputDirectoryPolicy = initialPreset.outputDirectoryPolicy
        }

        onStart(preset, currentURLs)
    }
}
