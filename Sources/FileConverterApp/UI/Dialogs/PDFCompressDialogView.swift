import SwiftUI
import PDFKit
import FileConverterCore

public struct PDFCompressDialogView: View {
    let urls: [URL]
    let initialPreset: ConversionPreset
    let onCancel: () -> Void
    let onStart: (ConversionPreset) -> Void

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
            case .prepress: return "Original DPI • Lossless fidelity"
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

    public enum CompatibilityLevel: String, CaseIterable, Identifiable {
        case v14 = "PDF 1.4 (Acrobat 5)"
        case v15 = "PDF 1.5 (Acrobat 6)"
        case v16 = "PDF 1.6 (Acrobat 7)"
        case v17 = "PDF 1.7 (Acrobat 8+)"

        public var id: String { rawValue }

        public var versionNumber: String {
            switch self {
            case .v14: return "1.4"
            case .v15: return "1.5"
            case .v16: return "1.6"
            case .v17: return "1.7"
            }
        }
    }

    @State private var selectedProfile: CompressionProfile = .ebook
    @State private var colorMode: ColorMode = .color
    @State private var targetDPI: Int = 150
    @State private var imageQuality: Double = 0.70
    @State private var removeMetadata: Bool = true
    @State private var removeAnnotations: Bool = false
    @State private var removeThumbnails: Bool = true
    @State private var linearize: Bool = true
    @State private var compatibilityLevel: CompatibilityLevel = .v14
    @State private var filenameSuffix: String = "_compressed"
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

    @State private var cachedTotalSize: Int64 = 0
    private var totalOriginalSize: Int64 { cachedTotalSize }

    @State private var cachedPageCount: Int? = nil

    private var pageCountText: String {
        guard let count = cachedPageCount else { return "" }
        if urls.count == 1 {
            return "\(count) pages"
        } else {
            return "\(count) pages in first file • \(urls.count) files selected"
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
        .task {
            let files = urls
            let size = await Task.detached {
                files.reduce(Int64(0)) { total, url in
                    let s = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return total + Int64(s)
                }
            }.value
            cachedTotalSize = size

            guard let firstURL else { return }
            let url = firstURL
            let count = await Task.detached {
                PDFDocument(url: url)?.pageCount
            }.value
            cachedPageCount = count
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
                Text(urls.count == 1 ? (firstURL?.lastPathComponent ?? "PDF Document") : "\(urls.count) PDF Documents")
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
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
            Spacer()
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
                    Picker("", selection: $colorMode) {
                        ForEach(ColorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                HStack {
                    Text("Target Resolution:")
                        .frame(width: 140, alignment: .leading)
                    Picker("", selection: $targetDPI) {
                        Text("72 DPI (Web)").tag(72)
                        Text("96 DPI (Email)").tag(96)
                        Text("150 DPI (eBook)").tag(150)
                        Text("200 DPI (Medium)").tag(200)
                        Text("300 DPI (Print)").tag(300)
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("JPEG Quality:")
                            .frame(width: 140, alignment: .leading)
                        Slider(value: $imageQuality, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(imageQuality * 100))%")
                            .frame(width: 45, alignment: .trailing)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                HStack {
                    Text("PDF Compatibility:")
                        .frame(width: 140, alignment: .leading)
                    Picker("", selection: $compatibilityLevel) {
                        ForEach(CompatibilityLevel.allCases) { level in
                            Text(level.rawValue).tag(level)
                        }
                    }
                    .labelsHidden()
                }
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
                Toggle("Remove annotations, comments, and highlights", isOn: $removeAnnotations)
                Toggle("Remove embedded page thumbnails", isOn: $removeThumbnails)
                Toggle("Linearize for fast web view (streamable page delivery)", isOn: $linearize)
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
                    TextField("", text: $filenameSuffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("e.g. document\(filenameSuffix).pdf")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                HStack {
                    Text("Save to:")
                        .frame(width: 120, alignment: .leading)
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

            Button("Compress PDF") {
                startCompression()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
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
        if panel.runModal() == .OK {
            customOutputDirectory = panel.url
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
        options.pdfCompatibilityLevel = compatibilityLevel.versionNumber

        preset.processingOptions = options
        preset.filenamePattern = "{name}\(filenameSuffix)"

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

        onStart(preset)
    }
}
