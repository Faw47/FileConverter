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
    /// Kept only in this dialog's memory; see `PDFPasswordVault`.
    @State private var protectWithPassword = false
    @State private var password = ""
    @State private var passwordAgain = ""

    public init(
        urls: [URL],
        initialPreset: ConversionPreset,
        onCancel: @escaping () -> Void,
        onStart: @escaping (ConversionPreset, [URL]) -> Void,
        startsProtected: Bool = false
    ) {
        self._currentURLs = State(initialValue: urls)
        self._protectWithPassword = State(initialValue: startsProtected)
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
    /// Files that cannot be compressed, with the reason, in batch order.
    @State private var problemFiles: [(url: URL, reason: String)] = []
    /// "about 2.1 MB (−64%)" for the first PDF with the current choices.
    @State private var expectedSize: String?
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
        Form {
            Section {
                Picker("Aim for", selection: $profile) {
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
                if usesGhostscript {
                    // Adding a password rewrites the file, which undoes it.
                    Toggle("Optimize for fast web viewing", isOn: protectWithPassword ? .constant(false) : $linearize)
                        .accessibilityLabel("Optimize for fast web viewing")
                        .disabled(protectWithPassword)
                }
            } footer: {
                FooterText(compressionFooter)
            }

            Section {
                Toggle("Protect with a password", isOn: $protectWithPassword)
                    .accessibilityLabel("Protect with a password")
                if protectWithPassword {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Verify", text: $passwordAgain)
                        .textContentType(.newPassword)
                        .accessibilityLabel("Enter the password again")
                }
            } header: {
                Text("Password")
            } footer: {
                if protectWithPassword && passwordsDiffer {
                    Text("The passwords don’t match.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    FooterText(protectWithPassword
                        ? "The PDF can’t be opened without this password. File Converter doesn’t save it anywhere, so keep it somewhere safe." + (usesGhostscript ? " Fast web viewing isn’t available for protected PDFs." : "")
                        : "Anyone with the file can open it.")
                }
            }

            Section("Remove") {
                Toggle("Document details (author, title, keywords)", isOn: $removeMetadata)
                    .accessibilityLabel("Remove document details")
                Toggle("Comments and highlights", isOn: $removeAnnotations)
                    .accessibilityLabel("Remove comments and highlights")
            }

            Section {
                TextField("Name ending", text: $nameEnding, prompt: Text("-compressed"))
                    .accessibilityLabel("Filename ending")
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
                FooterText("Example: \(exampleName). " + (protectWithPassword
                    ? "The protected PDF is saved even if it isn’t smaller."
                    : "If the result is not smaller, nothing is saved."))
            }
        }
        .formStyle(.grouped)
        .edgeBar(.top, style: .sheet) { headerView }
        .edgeBar(.bottom, style: .sheet) { footerView }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 480, idealHeight: 600)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .dropHighlight(isDropTargeted, "Drop to add PDFs")
        .task {
            recalculateStats()
        }
        .task(id: previewKey) { await previewCompression() }
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
        DropURLCollector.fileURLs(from: providers) { candidates in
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
                var firstPageCount: Int?
                var problems: [(url: URL, reason: String)] = []
                for url in files {
                    guard let document = PDFDocument(url: url) else {
                        problems.append((url, "can’t be opened"))
                        continue
                    }
                    if document.isLocked {
                        problems.append((url, "is password-protected"))
                    } else if firstPageCount == nil {
                        firstPageCount = document.pageCount
                    }
                }
                return (size, firstPageCount, problems)
            }.value
            await MainActor.run {
                guard self.currentURLs == files else { return }
                self.cachedTotalSize = stats.0
                self.cachedPageCount = stats.1
                self.problemFiles = stats.2
                self.isLoadingStats = false
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currentURLs.count == 1 ? "Compress “\(firstURL?.lastPathComponent ?? "PDF Document")”" : "Compress \(currentURLs.count) PDFs")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(statsText)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statsText: String {
        if isLoadingStats { return "Reading PDF…" }
        let size = ByteCountFormatter.string(fromByteCount: cachedTotalSize, countStyle: .file)
        guard let pages = cachedPageCount else { return size }
        if currentURLs.count == 1 {
            return Inflect.string("\(size) · ^[\(pages) page](inflect: true)")
        }
        return "\(size) total"
    }

    // MARK: - Footer
    private var footerView: some View {
        VStack(spacing: 8) {
            if let expectedSize {
                Text(expectedSize)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !problemFiles.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(problemSummary)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if problemFiles.count < currentURLs.count {
                        Button(problemFiles.count == 1 ? "Leave It Out" : "Leave Them Out") {
                            let left = Set(problemFiles.map(\.url))
                            currentURLs.removeAll { left.contains($0) }
                            recalculateStats()
                        }
                        .edgeBarButtonStyle()
                    }
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .edgeBarButtonStyle()
                    .accessibilityLabel("Cancel compression")

                Spacer()

                Button(currentURLs.count == 1 ? "Compress" : "Compress \(currentURLs.count) PDFs") {
                    startCompression()
                }
                .keyboardShortcut(.defaultAction)
                .edgeBarButtonStyle(prominent: true)
                .disabled(isLoadingStats || cachedPageCount == nil || !problemFiles.isEmpty || (protectWithPassword && passwordProblem != nil))
                .accessibilityLabel("Start PDF compression")
            }
        }
    }

    /// "This PDF is password-protected and can't be compressed." or, for a
    /// batch, which files and why.
    private var problemSummary: String {
        if currentURLs.count == 1, let only = problemFiles.first {
            return "This PDF \(only.reason) and can’t be compressed."
        }
        let listed = problemFiles.prefix(3).map { "“\($0.url.lastPathComponent)” \($0.reason)" }
        let more = problemFiles.count > 3 ? Inflect.string(", and ^[\(problemFiles.count - 3) more PDF](inflect: true) can’t be used") : ""
        return listed.joined(separator: "; ") + more + "."
    }

    /// Shown only once both fields have something in them.
    private var passwordsDiffer: Bool {
        !password.isEmpty && !passwordAgain.isEmpty && password != passwordAgain
    }

    /// Why the password can't be used yet, or nil when it can.
    private var passwordProblem: String? {
        if password.isEmpty { return "Enter a password." }
        if passwordAgain.isEmpty { return "Enter the password again to verify it." }
        if password != passwordAgain { return "The passwords don’t match." }
        return nil
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

    private struct PreviewKey: Hashable {
        let source: URL?
        let options: ConversionProcessingOptions
    }

    private var previewKey: PreviewKey {
        PreviewKey(source: previewSource, options: compressionOptions())
    }

    private var previewSource: URL? {
        let unusable = Set(problemFiles.map(\.url))
        return isLoadingStats ? nil : currentURLs.first { !unusable.contains($0) }
    }

    /// Compresses the first PDF into a temporary file with the current
    /// choices and reports how big it came out, before anything is saved.
    private func previewCompression() async {
        expectedSize = nil
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, let source = previewSource else { return }
        let originalSize = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard originalSize > 0, originalSize <= 300_000_000 else { return }

        var preset = initialPreset
        preset.processingOptions = compressionOptions()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileConverterPreview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("preview.pdf")
        var job = ConversionJob(sourceURL: source, preset: preset)
        job.destinationURL = output
        job.temporaryOutputURL = output
        guard let backend = try? BackendResolver.shared.resolveBackend(for: job) else { return }

        let jobID = job.id
        let previewJob = job
        do {
            try await withTaskCancellationHandler {
                _ = try await backend.convert(
                    job: previewJob,
                    outputs: [PlannedConversionOutput(finalURL: output, temporaryURL: output)],
                    progressHandler: { _ in }
                )
            } onCancel: {
                Task { await backend.cancel(jobID: jobID) }
            }
        } catch {
            if !Task.isCancelled { expectedSize = "These settings may not make this PDF smaller." }
            return
        }
        guard !Task.isCancelled else { return }
        let produced = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard produced > 0 else { return }
        let prefix = currentURLs.count > 1 ? "First PDF: about" : "Expected size: about"
        if produced >= originalSize {
            expectedSize = "These settings don’t make \(currentURLs.count > 1 ? "the first PDF" : "this PDF") smaller, so nothing would be saved."
        } else {
            let saved = Int((1 - Double(produced) / Double(originalSize)) * 100)
            expectedSize = "\(prefix) \(ByteCountFormatter.string(fromByteCount: produced, countStyle: .file)) (−\(saved)%)."
        }
    }

    /// The dialog's compression choices as processing options.
    private func compressionOptions() -> ConversionProcessingOptions {
        var options = initialPreset.processingOptions ?? ConversionProcessingOptions()
        options.pdfCompressionProfile = profile.ghostscriptName
        options.pdfFlattenToImages = !usesGhostscript && flattenPages
        options.pdfDPI = showsImageControls ? pageDPI : nil
        options.pdfImageQuality = options.pdfFlattenToImages ? imageQuality : nil
        options.pdfColorMode = showsImageControls && grayscale ? "grayscale" : "color"
        options.pdfRemoveMetadata = removeMetadata
        options.pdfRemoveAnnotations = removeAnnotations
        options.pdfRemoveThumbnails = usesGhostscript
        options.pdfLinearize = usesGhostscript && linearize && !protectWithPassword
        // A token from an earlier run names a password this run didn't ask for.
        options.pdfPasswordToken = nil
        return options
    }

    private func startCompression() {
        var preset = initialPreset
        var options = compressionOptions()
        if protectWithPassword, passwordProblem == nil {
            options.pdfPasswordToken = PDFPasswordVault.shared.store(password)
        }
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
