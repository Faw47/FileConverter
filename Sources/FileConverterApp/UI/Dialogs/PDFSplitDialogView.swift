import SwiftUI
import PDFKit
import FileConverterCore
import UniformTypeIdentifiers

/// Represents a single PDF file within a batch split workflow.
public struct PDFBatchItem: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public var pageCount: Int
    public var fileSize: Int64
    public var isLocked: Bool
    public var isValid: Bool
    public var validationError: String?
    public var customRangeString: String?

    public init(
        url: URL,
        pageCount: Int,
        fileSize: Int64,
        isLocked: Bool,
        isValid: Bool,
        validationError: String? = nil,
        customRangeString: String? = nil
    ) {
        self.url = url
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.isLocked = isLocked
        self.isValid = isValid
        self.validationError = validationError
        self.customRangeString = customRangeString
    }
}

public struct PDFSplitDialogView: View {
    let initialPreset: ConversionPreset
    let onCancel: () -> Void
    let onStart: (ConversionPreset, [URL]) -> Void

    @State private var currentURLs: [URL]
    @State private var batchItems: [PDFBatchItem] = []
    @State private var isDropTargeted = false

    public enum SplitMode: String, CaseIterable, Identifiable {
        case all = "All Pages"
        case ranges = "Page Ranges"
        case chunks = "Fixed Chunks"
        case evenOdd = "Even & Odd"
        case selected = "Select Pages"

        public var id: String { rawValue }

        public var icon: String {
            switch self {
            case .all: return "doc.on.doc"
            case .ranges: return "slider.horizontal.below.rectangle"
            case .chunks: return "square.grid.2x2"
            case .evenOdd: return "arrow.left.arrow.right"
            case .selected: return "hand.tap"
            }
        }
    }

    public enum NumberingPadding: Int, CaseIterable, Identifiable {
        case none = 1
        case twoDigits = 2
        case threeDigits = 3

        public var id: Int { rawValue }

        public var displayName: String {
            switch self {
            case .none: return "1, 2, 3..."
            case .twoDigits: return "01, 02, 03..."
            case .threeDigits: return "001, 002, 003..."
            }
        }
    }

    @State private var selectedMode: SplitMode = .all
    @State private var rangeString: String = "1"
    @State private var chunkSize: Int = 2
    @State private var mergeOutputs: Bool = false
    @State private var selectedPages: Set<Int> = [] {
        didSet { selectedPagesText = Self.rangeText(for: selectedPages) }
    }
    @State private var selectedPagesText = ""
    @State private var lastClickedPage: Int?
    @State private var zeroPadDigits: NumberingPadding = .twoDigits
    @State private var createSubfolder: Bool = false
    @State private var customOutputDirectory: URL? = nil
    @State private var isLoadingStats = true
    @State private var dropErrorMessage: String?

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
        let mode: SplitMode = {
            guard let raw = opts?.pdfSplitMode?.lowercased() else { return .all }
            switch raw {
            case "ranges": return .ranges
            case "chunks": return .chunks
            case "evenodd": return .evenOdd
            case "selected": return .selected
            default: return .all
            }
        }()
        self._selectedMode = State(initialValue: mode)
        self._rangeString = State(initialValue: opts?.pdfPageRanges ?? "1")
        self._chunkSize = State(initialValue: opts?.pdfChunkSize ?? 2)
        self._mergeOutputs = State(initialValue: opts?.pdfMergeSplitOutputs ?? false)
        self._selectedPages = State(initialValue: Set(opts?.pdfSelectedPages ?? []))
        self._zeroPadDigits = State(initialValue: NumberingPadding(rawValue: opts?.pdfZeroPadDigits ?? 2) ?? .twoDigits)

        let wantsSubfolder: Bool = {
            if case .sourceSubfolder = initialPreset.outputDirectoryPolicy {
                return true
            }
            return false
        }()
        self._createSubfolder = State(initialValue: wantsSubfolder)

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

    @State private var cachedTotalPages: Int = 1
    @State private var cachedTotalSize: Int64 = 0
    @State private var isDocumentLocked: Bool = false

    private var totalPages: Int { cachedTotalPages }
    private var totalOriginalSize: Int64 { cachedTotalSize }

    public func validateRange(for item: PDFBatchItem) -> (isValid: Bool, error: String?) {
        guard item.isValid, !item.isLocked else {
            return (false, item.validationError ?? "Cannot split document")
        }
        let rangeStr = item.customRangeString ?? rangeString
        let res = PDFPageRangeParser.parseRangesStrict(rangeStr, totalPages: item.pageCount)
        if !res.isValid {
            return (false, res.errorMessage ?? "Invalid range for \(item.pageCount) pages")
        }
        return (true, nil)
    }

    public func plannedOutputCount(for item: PDFBatchItem) -> Int {
        guard item.isValid, !item.isLocked else { return 0 }
        let effectiveRange = item.customRangeString ?? rangeString
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: item.pageCount,
            splitMode: currentModeKey,
            pageRanges: effectiveRange,
            chunkSize: chunkSize,
            selectedPages: Array(selectedPages.filter { $0 <= item.pageCount }),
            mergeOutputs: mergeOutputs,
            zeroPadDigits: zeroPadDigits.rawValue
        )
        return plans.count
    }

    private var totalPlannedOutputs: Int {
        guard !isLoadingStats else { return 0 }
        return batchItems.reduce(0) { $0 + plannedOutputCount(for: $1) }
    }

    private var plannedOutputCount: Int {
        totalPlannedOutputs
    }

    private var strictRangeResult: PDFPageRangeParser.ParseResult {
        PDFPageRangeParser.parseRangesStrict(rangeString, totalPages: totalPages)
    }

    private var isSplitDisabled: Bool {
        if isLoadingStats || batchItems.isEmpty { return true }
        if batchItems.contains(where: { !$0.isValid || $0.isLocked }) { return true }
        if totalPlannedOutputs <= 0 || totalPlannedOutputs > 1000 { return true }
        switch selectedMode {
        case .ranges:
            return batchItems.contains(where: { !validateRange(for: $0).isValid })
        case .selected:
            return selectedPages.isEmpty
        default:
            return false
        }
    }

    private var currentModeKey: String {
        switch selectedMode {
        case .all: return "all"
        case .ranges: return "ranges"
        case .chunks: return "chunks"
        case .evenOdd: return "evenOdd"
        case .selected: return "selected"
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
                    if batchItems.count > 1 {
                        batchFilesSection
                    }

                    modePickerSection

                    modeConfigSection

                    namingAndFolderSection
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
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, maxHeight: 680)
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

    public func removeItem(_ item: PDFBatchItem) {
        currentURLs.removeAll { $0 == item.url }
        batchItems.removeAll { $0.id == item.id }
        recalculateStats()
    }

    private func recalculateStats() {
        let files = currentURLs
        isLoadingStats = true
        Task {
            let items: [PDFBatchItem] = await Task.detached {
                return files.map { url in
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                        return PDFBatchItem(url: url, pageCount: 0, fileSize: 0, isLocked: false, isValid: false, validationError: "File not found or is a directory")
                    }
                    let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    guard let doc = PDFDocument(url: url) else {
                        return PDFBatchItem(url: url, pageCount: 0, fileSize: fileSize, isLocked: false, isValid: false, validationError: "Unreadable or corrupted PDF")
                    }
                    if doc.isLocked {
                        return PDFBatchItem(url: url, pageCount: doc.pageCount, fileSize: fileSize, isLocked: true, isValid: false, validationError: "Password-protected or encrypted")
                    }
                    if doc.pageCount <= 0 {
                        return PDFBatchItem(url: url, pageCount: 0, fileSize: fileSize, isLocked: false, isValid: false, validationError: "Document contains no pages")
                    }
                    return PDFBatchItem(url: url, pageCount: doc.pageCount, fileSize: fileSize, isLocked: false, isValid: true)
                }
            }.value

            await MainActor.run {
                guard self.currentURLs == files else { return }
                self.batchItems = items
                self.cachedTotalSize = items.reduce(0) { $0 + $1.fileSize }
                self.cachedTotalPages = items.map(\.pageCount).max() ?? 1
                self.isDocumentLocked = items.contains(where: { $0.isLocked })
                self.isLoadingStats = false
                let maxPages = items.map(\.pageCount).max() ?? 1
                if self.selectedPages.isEmpty {
                    self.selectedPages = Set(1...min(maxPages, 5))
                }
            }
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(batchItems.count <= 1 ? (firstURL?.lastPathComponent ?? "PDF Document") : "\(batchItems.count) PDF Documents")
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if isLoadingStats {
                        Text("Reading PDF…")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fontWeight(.medium)
                    } else if batchItems.count <= 1 {
                        Text("\(totalPages) Pages")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fontWeight(.medium)
                    } else {
                        let sumPages = batchItems.reduce(0) { $0 + $1.pageCount }
                        Text("\(sumPages) Pages Total across \(batchItems.count) files")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .fontWeight(.medium)
                    }

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(ByteCountFormatter.string(fromByteCount: totalOriginalSize, countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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

    // MARK: - Batch Files List
    private var batchFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Documents in Batch (\(batchItems.count))")
                    .font(.headline)
                Spacer()
                Text("Remove accidental files before splitting")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(batchItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(item.isValid && !item.isLocked ? .blue : .red)
                            .font(.system(size: 16))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            HStack(spacing: 6) {
                                if item.isValid && !item.isLocked {
                                    Text("\(item.pageCount) pages")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if selectedMode == .ranges {
                                        HStack(spacing: 4) {
                                            Text("Range:")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                            TextField(
                                                rangeString,
                                                text: Binding(
                                                    get: { item.customRangeString ?? "" },
                                                    set: { val in
                                                        if let idx = batchItems.firstIndex(where: { $0.id == item.id }) {
                                                            batchItems[idx].customRangeString = val.trimmingCharacters(in: .whitespaces).isEmpty ? nil : val
                                                        }
                                                    }
                                                )
                                            )
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 70)
                                            .font(.caption2)
                                            .accessibilityLabel("Custom range for \(item.url.lastPathComponent)")
                                        }
                                        if let err = validateRange(for: item).error {
                                            Text("• \(err)")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }
                                    }
                                } else {
                                    Text(item.validationError ?? "Cannot process document")
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                }
                            }
                        }

                        Spacer()

                        Button(action: { removeItem(item) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(item.url.lastPathComponent) from this batch")
                        .accessibilityLabel("Remove \(item.url.lastPathComponent)")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                }
            }
        }
    }

    // MARK: - Mode Picker
    private var modePickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Splitting Method")
                .font(.headline)

            HStack(spacing: 8) {
                ForEach(SplitMode.allCases) { mode in
                    Button(action: {
                        selectedMode = mode
                    }) {
                        VStack(spacing: 6) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedMode == mode ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(selectedMode == mode ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: selectedMode == mode ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                    .accessibilityLabel(mode.rawValue)
                    .accessibilityValue(selectedMode == mode ? "Selected" : "Not selected")
                }
            }
        }
    }

    // MARK: - Mode Config
    @ViewBuilder
    private var modeConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configuration")
                .font(.headline)

            VStack(alignment: .leading, spacing: 14) {
                switch selectedMode {
                case .all:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extract Every Page")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Every page in this document will be saved into its own separate single-page PDF file.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                case .ranges:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Specify Page Ranges")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack {
                            TextField("e.g. 1-3, 5, 7-10", text: $rangeString)
                                .textFieldStyle(.roundedBorder)

                            Text("Total: \(totalPages) pages")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        let parsed = strictRangeResult
                        if parsed.validRanges.isEmpty {
                            Text(parsed.errorMessage ?? "Please enter valid page numbers (1 to \(totalPages)).")
                                .font(.caption)
                                .foregroundColor(.red)
                        } else {
                            let totalExtracted = parsed.validRanges.reduce(0) { $0 + $1.count }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Valid: \(parsed.validRanges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")) (\(totalExtracted) pages total)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let warning = parsed.errorMessage {
                                    ScrollView {
                                        Text(warning)
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                    .frame(maxHeight: 60)
                                }
                            }
                        }

                        Toggle("Merge extracted ranges into a single new PDF document", isOn: $mergeOutputs)
                            .font(.subheadline)
                    }

                case .chunks:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Fixed Chunks")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 12) {
                            Text("Split every:")
                                .frame(width: 80, alignment: .leading)
                            Stepper("\(chunkSize) pages", value: $chunkSize, in: 1...max(1, totalPages))
                                .frame(width: 160)
                        }

                        let partsCount = (totalPages + chunkSize - 1) / chunkSize
                        Text("A \(totalPages)-page document will be divided into \(partsCount) files of up to \(chunkSize) pages each.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                case .evenOdd:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Split Even and Odd Pages")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        let oddCount = (totalPages + 1) / 2
                        let evenCount = totalPages / 2

                        Text("Creates two files:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Document_odd.pdf (\(oddCount) pages: 1, 3, 5...)")
                            Text("• Document_even.pdf (\(evenCount) pages: 2, 4, 6...)")
                        }
                        .font(.caption)
                        .foregroundColor(.primary)
                    }

                case .selected:
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Select Pages to Extract (\(selectedPages.count) selected)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            Button("Select All") {
                                selectedPages = Set(1...totalPages)
                                selectedPagesText = Self.rangeText(for: selectedPages)
                            }
                                .font(.caption)
                            Button("Clear") {
                                selectedPages.removeAll()
                                selectedPagesText = ""
                            }
                                .font(.caption)
                        }

                        HStack {
                            Text("Pages")
                                .foregroundStyle(.secondary)
                            TextField("e.g. 1-3, 5", text: $selectedPagesText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { applySelectedPagesText() }
                                .accessibilityLabel("Selected pages")
                        }
                        Text("Click a page to select it. Shift-click selects a range.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                                ForEach(1...totalPages, id: \.self) { page in
                                    PageThumbnailCell(
                                        documentURL: firstURL,
                                        pageNumber: page,
                                        isSelected: selectedPages.contains(page)
                                    ) {
                                        togglePage(page, extendingRange: NSEvent.modifierFlags.contains(.shift))
                                    }
                                }
                            }
                            .padding(2)
                        }
                        .frame(minHeight: 160, maxHeight: 300)

                        Toggle("Merge selected pages into a single new PDF document", isOn: $mergeOutputs)
                            .font(.subheadline)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Naming & Folder
    private var namingAndFolderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Naming & Destination")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Page Numbering:")
                        .frame(width: 140, alignment: .leading)
                    Picker("", selection: $zeroPadDigits) {
                        ForEach(NumberingPadding.allCases) { pad in
                            Text(pad.displayName).tag(pad)
                        }
                    }
                    .labelsHidden()
                }

                Toggle("Save into a dedicated subfolder", isOn: $createSubfolder)
                    .font(.subheadline)

                HStack {
                    Text("Save to:")
                        .frame(width: 140, alignment: .leading)
                    if let dir = customOutputDirectory {
                        Text(dir.path)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(dir.path)
                        Button("Change…") { chooseOutputDirectory() }
                        Button("Use Default") { customOutputDirectory = nil }
                    } else {
                        Text(createSubfolder ? "A “{name} - Pages” folder next to the original" : DestinationDescription.folder(for: initialPreset))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose Folder…") { chooseOutputDirectory() }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Footer
    private var isFooterStatusError: Bool {
        guard !isLoadingStats else { return false }
        return isSplitDisabled || totalPlannedOutputs == 0
    }

    private var footerStatusText: String {
        if isLoadingStats { return "Reading PDF…" }
        if batchItems.isEmpty { return "No documents in batch" }
        if let locked = batchItems.first(where: { $0.isLocked }) {
            return "\(locked.url.lastPathComponent) is password-protected"
        }
        if let invalid = batchItems.first(where: { !$0.isValid }) {
            return "\(invalid.url.lastPathComponent): \(invalid.validationError ?? "Invalid PDF")"
        }
        if selectedMode == .ranges, let rangeErr = batchItems.first(where: { !validateRange(for: $0).isValid }) {
            return "\(rangeErr.url.lastPathComponent): \(validateRange(for: rangeErr).error ?? "Invalid range")"
        }
        if totalPlannedOutputs == 0 {
            return "Enter a valid page selection"
        }
        if totalPlannedOutputs > 1000 {
            return "Exceeds safety limit of 1000 outputs (\(totalPlannedOutputs) planned)"
        }
        if batchItems.count == 1 {
            return "Will create \(totalPlannedOutputs) \(totalPlannedOutputs == 1 ? "file" : "files")"
        } else {
            return "Will create \(totalPlannedOutputs) files across \(batchItems.count) documents"
        }
    }

    private var footerView: some View {
        VStack(spacing: 8) {
            if isDocumentLocked {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.red)
                    Text("One or more PDFs are password-protected or locked. Encrypted documents cannot be split.")
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Text(footerStatusText)
                    .font(.subheadline)
                    .foregroundColor(isFooterStatusError ? .red : .secondary)

                Button("Split PDF") {
                    startSplitting()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSplitDisabled)
            }
        }
    }

    private func togglePage(_ page: Int, extendingRange: Bool) {
        if extendingRange, let anchor = lastClickedPage {
            let range = min(anchor, page)...max(anchor, page)
            selectedPages.formUnion(range)
        } else if selectedPages.contains(page) {
            selectedPages.remove(page)
        } else {
            selectedPages.insert(page)
        }
        lastClickedPage = page
        selectedPagesText = Self.rangeText(for: selectedPages)
    }

    private func applySelectedPagesText() {
        let ranges = PDFPageRangeParser.parseRanges(selectedPagesText, totalPages: totalPages)
        selectedPages = Set(ranges.flatMap { Array($0) })
        selectedPagesText = Self.rangeText(for: selectedPages)
    }

    /// "1, 2, 3, 5" → "1-3, 5".
    static func rangeText(for pages: Set<Int>) -> String {
        let sorted = pages.sorted()
        var parts: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            parts.append(end > index ? "\(sorted[index])-\(sorted[end])" : "\(sorted[index])")
            index = end + 1
        }
        return parts.joined(separator: ", ")
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

    private func startSplitting() {
        // Strict validation: invalid, reversed, or empty selections never
        // produce silent all-pages output.
        guard !isSplitDisabled else { return }
        if selectedMode == .ranges {
            for item in batchItems {
                guard validateRange(for: item).isValid else { return }
            }
        }
        if selectedMode == .selected, selectedPages.isEmpty { return }

        // Check if any batch item has a per-file custom range override
        let hasPerFileRanges = selectedMode == .ranges
            && batchItems.count > 1
            && batchItems.contains(where: { $0.customRangeString != nil })

        if hasPerFileRanges {
            // Submit individual jobs per file with their respective range
            for item in batchItems {
                var preset = initialPreset
                var options = preset.processingOptions ?? ConversionProcessingOptions()
                options.splitPDFIntoPages = true
                options.pdfSplitMode = currentModeKey
                options.pdfPageRanges = item.customRangeString ?? rangeString
                options.pdfChunkSize = chunkSize
                options.pdfSelectedPages = Array(selectedPages)
                options.pdfMergeSplitOutputs = mergeOutputs
                options.pdfZeroPadDigits = zeroPadDigits.rawValue
                applyOutputDirectory(to: &preset, options: &options)
                preset.processingOptions = options
                onStart(preset, [item.url])
            }
        } else {
            // Original single-batch path
            var preset = initialPreset
            var options = preset.processingOptions ?? ConversionProcessingOptions()
            options.splitPDFIntoPages = true
            options.pdfSplitMode = currentModeKey
            options.pdfPageRanges = rangeString
            options.pdfChunkSize = chunkSize
            options.pdfSelectedPages = Array(selectedPages)
            options.pdfMergeSplitOutputs = mergeOutputs
            options.pdfZeroPadDigits = zeroPadDigits.rawValue
            applyOutputDirectory(to: &preset, options: &options)
            preset.processingOptions = options
            onStart(preset, currentURLs)
        }
    }

    /// A folder chosen in this dialog is this run's own choice, so the
    /// preset stops following the General output location for it.
    private func applyOutputDirectory(to preset: inout ConversionPreset, options: inout ConversionProcessingOptions) {
        var inheritance = preset.resolvedInheritance
        defer { preset.inheritance = inheritance }
        if createSubfolder {
            options.pdfOutputSubfolder = "{name} - Pages"
            preset.outputDirectoryPolicy = .sourceSubfolder(subfolderName: "{name} - Pages")
            inheritance.outputLocation = false
        } else if let customOutputDirectory {
            inheritance.outputLocation = false
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
        }
    }
}

/// One page of the "select pages" grid, rendered as a small thumbnail.
private struct PageThumbnailCell: View {
    let documentURL: URL?
    let pageNumber: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .textBackgroundColor))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(2)
                    }
                }
                .frame(width: 72, height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 3 : 1)
                )
                Text("\(pageNumber)")
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(pageNumber)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .task(id: documentURL) {
            guard thumbnail == nil, let documentURL,
                  let page = ThumbnailDocumentCache.document(for: documentURL)?.page(at: pageNumber - 1) else { return }
            thumbnail = page.thumbnail(of: CGSize(width: 144, height: 192), for: .cropBox)
        }
    }
}

/// Opens each PDF once for all of its page thumbnails.
@MainActor
private enum ThumbnailDocumentCache {
    private static var documents: [URL: PDFDocument] = [:]

    static func document(for url: URL) -> PDFDocument? {
        if let cached = documents[url] { return cached }
        guard let document = PDFDocument(url: url) else { return nil }
        if documents.count > 8 { documents.removeAll() }
        documents[url] = document
        return document
    }
}
