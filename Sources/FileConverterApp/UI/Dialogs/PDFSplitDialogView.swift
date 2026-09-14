import SwiftUI
import PDFKit
import FileConverterCore

public struct PDFSplitDialogView: View {
    let urls: [URL]
    let initialPreset: ConversionPreset
    let onCancel: () -> Void
    let onStart: (ConversionPreset) -> Void

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
    @State private var rangeString: String = "1-3, 5"
    @State private var chunkSize: Int = 2
    @State private var mergeOutputs: Bool = false
    @State private var selectedPages: Set<Int> = []
    @State private var zeroPadDigits: NumberingPadding = .twoDigits
    @State private var createSubfolder: Bool = true
    @State private var customOutputDirectory: URL? = nil

    public init(
        urls: [URL],
        initialPreset: ConversionPreset,
        onCancel: @escaping () -> Void,
        onStart: @escaping (ConversionPreset) -> Void
    ) {
        self.urls = urls
        self.initialPreset = initialPreset
        self.onCancel = onCancel
        self.onStart = onStart
    }

    private var firstURL: URL? { urls.first }

    @State private var cachedTotalPages: Int = 1
    @State private var cachedTotalSize: Int64 = 0

    private var totalPages: Int { cachedTotalPages }
    private var totalOriginalSize: Int64 { cachedTotalSize }

    private var plannedOutputCount: Int {
        let plans = PDFPageRangeParser.planOutputs(
            totalPages: totalPages,
            splitMode: currentModeKey,
            pageRanges: rangeString,
            chunkSize: chunkSize,
            selectedPages: Array(selectedPages),
            mergeOutputs: mergeOutputs,
            zeroPadDigits: zeroPadDigits.rawValue
        )
        return max(1, plans.count)
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
        .task {
            let files = urls
            let size = await Task.detached {
                files.reduce(Int64(0)) { total, url in
                    let s = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return total + Int64(s)
                }
            }.value
            cachedTotalSize = size

            if let firstURL {
                let url = firstURL
                let count = await Task.detached {
                    PDFDocument(url: url)?.pageCount ?? 1
                }.value
                cachedTotalPages = max(1, count)
            }
            if selectedPages.isEmpty {
                selectedPages = Set(1...min(totalPages, 5))
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
                Text(firstURL?.lastPathComponent ?? "PDF Document")
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(totalPages) Pages")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fontWeight(.medium)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(ByteCountFormatter.string(fromByteCount: totalOriginalSize, countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
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

                        let parsed = PDFPageRangeParser.parseRanges(rangeString, totalPages: totalPages)
                        if parsed.isEmpty {
                            Text("Please enter valid page numbers (1 to \(totalPages)).")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            let totalExtracted = parsed.reduce(0) { $0 + $1.count }
                            Text("Valid: \(parsed.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")) (\(totalExtracted) pages total)")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                            Button("Select All") { selectedPages = Set(1...totalPages) }
                                .font(.caption)
                            Button("Clear") { selectedPages.removeAll() }
                                .font(.caption)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(10, max(4, totalPages))), spacing: 6) {
                            ForEach(1...totalPages, id: \.self) { page in
                                let isSelected = selectedPages.contains(page)
                                Button(action: {
                                    if isSelected {
                                        selectedPages.remove(page)
                                    } else {
                                        selectedPages.insert(page)
                                    }
                                }) {
                                    Text("\(page)")
                                        .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(isSelected ? Color.accentColor : Color(NSColor.windowBackgroundColor))
                                        )
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(isSelected ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }

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
                        Text(dir.lastPathComponent)
                            .font(.subheadline)
                            .lineLimit(1)
                        Button("Change...") { chooseOutputDirectory() }
                        Button("Reset") { customOutputDirectory = nil }
                    } else {
                        Text("Same folder as original")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                        Button("Choose Folder...") { chooseOutputDirectory() }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    // MARK: - Footer
    private var footerView: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Will create \(plannedOutputCount) \(plannedOutputCount == 1 ? "file" : "files")")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button("Split PDF") {
                startSplitting()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        if panel.runModal() == .OK {
            customOutputDirectory = panel.url
        }
    }

    private func startSplitting() {
        var preset = initialPreset
        var options = preset.processingOptions ?? ConversionProcessingOptions()

        options.splitPDFIntoPages = true
        options.pdfSplitMode = currentModeKey
        options.pdfPageRanges = rangeString
        options.pdfChunkSize = chunkSize
        options.pdfSelectedPages = Array(selectedPages)
        options.pdfMergeSplitOutputs = mergeOutputs
        options.pdfZeroPadDigits = zeroPadDigits.rawValue

        if createSubfolder {
            options.pdfOutputSubfolder = "{name} - Pages"
            preset.outputDirectoryPolicy = .sourceSubfolder(subfolderName: "{name} - Pages")
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
        }

        preset.processingOptions = options
        onStart(preset)
    }
}
