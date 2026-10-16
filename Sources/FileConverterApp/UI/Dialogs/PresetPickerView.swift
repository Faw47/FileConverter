import AppKit
import FileConverterCore
import SwiftUI

/// Choose how to convert files that arrived without a preset (drag and drop,
/// Add Files, Open With). Picks the last preset used for these file types,
/// shows where the result will be saved, and starts on Return.
struct PresetPickerView: View {
    let urls: [URL]
    let excludedCount: Int
    let pendingBatches: Int
    let onCancel: () -> Void
    /// Each pair is (files, preset to convert them with).
    let onConvert: ([(urls: [URL], preset: ConversionPreset)]) -> Void
    let onManagePresets: () -> Void

    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var locationOverride: LocationOverride = .preset
    @State private var qualityOverride: QualityOverride = .preset
    @State private var sizeOverride: SizeOverride = .preset
    @State private var sizeEstimate: String?
    @State private var customFolder: URL?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case search, grid }

    enum LocationOverride: Hashable { case preset, sameFolder, downloads, chosen }
    enum QualityOverride: Hashable { case preset, smaller, balanced, higher }
    /// Longest side for images, in pixels.
    enum SizeOverride: Int, Hashable { case preset = 0, large = 3840, medium = 2048, small = 1280, tiny = 640 }

    // MARK: - Inputs

    private var recognized: [URL] {
        urls.filter { FormatDetector.detect(url: $0).format != nil }
    }

    private var unsupported: [URL] {
        urls.filter { FormatDetector.detect(url: $0).format == nil }
    }

    private var groups: [(category: FormatCategory, urls: [URL])] {
        let grouped = Dictionary(grouping: recognized) { FormatDetector.detect(url: $0).format?.category ?? .custom }
        return FormatCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
    }

    private var compatible: [ConversionPreset] {
        PresetValidator.compatiblePresets(forURLs: recognized)
    }

    private var isMixed: Bool { compatible.isEmpty && groups.count > 1 }

    private var filtered: [ConversionPreset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return compatible }
        return compatible.filter {
            $0.menuName.lowercased().contains(query)
                || $0.name.lowercased().contains(query)
                || $0.destinationFormat.lowercased().contains(query)
        }
    }

    private var recent: [ConversionPreset] {
        guard searchText.isEmpty else { return [] }
        let ids = PresetUsageStore.recentPresetIDs()
        return ids.prefix(4).compactMap { id in compatible.first { $0.id == id } }
    }

    /// Presets in on-screen order, used for arrow-key navigation.
    private var ordered: [ConversionPreset] {
        let recentIDs = Set(recent.map(\.id))
        return recent + FormatCategory.allCases.flatMap { category in
            filtered.filter { $0.category == category && !recentIDs.contains($0.id) }
        }
    }

    private var selectedPreset: ConversionPreset? {
        selectedID.flatMap { id in compatible.first { $0.id == id } }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            if PresetStore.shared.state.isRecoveryRequired {
                recoveryMessage
            } else if recognized.isEmpty {
                unsupportedOnly
            } else if isMixed {
                MixedBatchView(
                    groups: groups,
                    options: AnyView(optionPickers(showQuality: true, showSize: groups.contains { $0.category == .image })),
                    applyingOverrides: applyingOverrides,
                    onCancel: onCancel,
                    onConvert: onConvert,
                    onManagePresets: onManagePresets
                )
            } else if compatible.isEmpty {
                noPresets
            } else {
                presetGrid
                    .edgeBar(.bottom, style: .sheet) { footer }
            }
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: 960, minHeight: 420, idealHeight: 540)
        .onAppear {
            selectedID = PresetUsageStore.lastCompatiblePreset(for: recognized, among: compatible)?.id ?? compatible.first?.id
            focus = .grid
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recognized.count == 1 ? "Convert \(recognized[0].lastPathComponent)" : "Convert \(recognized.count) Files")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if !unsupported.isEmpty || excludedCount > 0 {
                Text(unsupportedSummary)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if pendingBatches > 0 {
                Text(Inflect.string("^[\(pendingBatches) more batch](inflect: true) waiting after this one."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unsupportedSummary: String {
        let names = unsupported.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        let count = unsupported.count + excludedCount
        let more = count > 3 ? " and \(count - min(3, unsupported.count)) more" : ""
        if names.isEmpty {
            return Inflect.string("^[\(excludedCount) item](inflect: true) left out (folders, empty or missing files).")
        }
        return "Not supported, left out: \(names)\(more)."
    }

    // MARK: - List

    /// The files' own kinds first, so a photo shows image presets before
    /// Animated GIF (filed under Video).
    private var categoryOrder: [FormatCategory] {
        let own = groups.map(\.category)
        return own + FormatCategory.allCases.filter { !own.contains($0) }
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search", text: $searchText, prompt: Text("Search presets"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
                .onSubmit { focus = .grid }
                .accessibilityLabel("Search compatible presets")
                .padding(.horizontal, 20)

            if ordered.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    if !recent.isEmpty {
                        Section("Recent") {
                            ForEach(recent) { row($0) }
                        }
                    }
                    let recentIDs = Set(recent.map(\.id))
                    ForEach(categoryOrder) { category in
                        let presets = filtered.filter { $0.category == category && !recentIDs.contains($0.id) }
                        if !presets.isEmpty {
                            Section(category.displayName) {
                                ForEach(presets) { row($0) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .focused($focus, equals: .grid)
                .contextMenu(forSelectionType: UUID.self) { _ in
                    EmptyView()
                } primaryAction: { ids in
                    if let id = ids.first {
                        selectedID = id
                        convertSelected()
                    }
                }
                .onKeyPress(characters: .alphanumerics) { press in
                    searchText += press.characters
                    focus = .search
                    return .handled
                }
            }
        }
    }

    private func row(_ preset: ConversionPreset) -> some View {
        HStack {
            Text(preset.menuName)
            Spacer()
            if let detail = Self.detail(for: preset) {
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(preset.id)
    }

    /// The long name, only when it says more than the short one: "PNG Image
    /// (Lossless)" adds "Lossless" to "PNG"; "HEIC Image" adds nothing.
    static func detail(for preset: ConversionPreset) -> String? {
        let generic: Set<String> = ["image", "video", "audio", "document", "file", "files", "to", "→", "–", "-"]
        let shortWords = Set(preset.menuName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let extra = preset.name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !shortWords.contains($0) && !generic.contains($0) }
        return extra.isEmpty ? nil : preset.name
    }

    // MARK: - Footer

    private var effectivePreset: ConversionPreset? {
        selectedPreset.map(applyingOverrides)
    }

    /// This conversion's own choices from "Options for This Conversion".
    private func applyingOverrides(_ original: ConversionPreset) -> ConversionPreset {
        var preset = original
        var inheritance = preset.resolvedInheritance
        switch locationOverride {
        case .preset: break
        case .sameFolder:
            preset.outputDirectoryPolicy = .sameAsSource
            inheritance.outputLocation = false
        case .downloads:
            preset.outputDirectoryPolicy = .downloads
            inheritance.outputLocation = false
        case .chosen:
            if let customFolder,
               let bookmark = (try? customFolder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? customFolder.bookmarkData()) {
                preset.outputDirectoryPolicy = .customFolder(bookmarkData: bookmark, displayPath: customFolder.path)
                inheritance.outputLocation = false
            }
        }
        preset.inheritance = inheritance
        if preset.category == .image, sizeOverride != .preset {
            preset.resolution = .custom(width: sizeOverride.rawValue, height: sizeOverride.rawValue)
        }
        guard Self.takesQualityOverride(preset) else { return preset }
        switch qualityOverride {
        case .preset: break
        case .smaller: preset.quality = .low
        case .balanced: preset.quality = .medium
        case .higher: preset.quality = .veryHigh
        }
        return preset
    }

    static func takesQualityOverride(_ preset: ConversionPreset) -> Bool {
        !preset.isInteractiveWorkflow && preset.category != .document
    }

    /// "Save to", "Quality", and for images "Size", shared by single-kind
    /// and mixed batches.
    @ViewBuilder
    private func optionPickers(showQuality: Bool, showSize: Bool) -> some View {
        Picker("Save to", selection: $locationOverride) {
            Text("As the preset says").tag(LocationOverride.preset)
            Text("Same folder as the original").tag(LocationOverride.sameFolder)
            Text("Downloads").tag(LocationOverride.downloads)
            Text(customFolder.map { "“\($0.lastPathComponent)”" } ?? "Choose a Folder…").tag(LocationOverride.chosen)
        }
        .onChange(of: locationOverride) { _, newValue in
            if newValue == .chosen && customFolder == nil { chooseFolder() }
        }
        if showQuality {
            Picker("Quality", selection: $qualityOverride) {
                Text("As the preset says").tag(QualityOverride.preset)
                Text("Smaller file").tag(QualityOverride.smaller)
                Text("Balanced").tag(QualityOverride.balanced)
                Text("Higher quality").tag(QualityOverride.higher)
            }
        }
        if showSize {
            Picker("Image size", selection: $sizeOverride) {
                Text("As the preset says").tag(SizeOverride.preset)
                Divider()
                Text("Large (3840 px)").tag(SizeOverride.large)
                Text("Medium (2048 px)").tag(SizeOverride.medium)
                Text("Small (1280 px)").tag(SizeOverride.small)
                Text("Tiny (640 px)").tag(SizeOverride.tiny)
            }
            .help("Longest side; images are never enlarged")
        }
    }

    /// Recomputed when the chosen preset or an option changes.
    private struct EstimateKey: Hashable {
        let presetID: UUID?
        let quality: QualityOverride
        let size: SizeOverride
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preset = effectivePreset {
                Text([DestinationDescription.sentence(for: preset, sources: recognized),
                      sizeEstimate.map { "Expected size: \($0)." },
                      DestinationDescription.metadataNote(for: preset)].compactMap { $0 }.joined(separator: " "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .task(id: EstimateKey(presetID: selectedID, quality: qualityOverride, size: sizeOverride)) {
                        sizeEstimate = nil
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, let preset = effectivePreset else { return }
                        let estimate = await OutputSizePreview.estimate(preset: preset, sources: recognized)
                        if !Task.isCancelled { sizeEstimate = estimate }
                    }
            }

            // This conversion's own choices, always in view: two menus
            // rather than a disclosure to open first.
            HStack(spacing: 16) {
                optionPickers(showQuality: selectedPreset.map(Self.takesQualityOverride) ?? false, showSize: selectedPreset?.category == .image)
                    .fixedSize()
            }

            HStack {
                Button("Manage Presets…", action: onManagePresets)
                    .edgeBarButtonStyle()
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .edgeBarButtonStyle()
                Button("Convert") { convertSelected() }
                    .keyboardShortcut(.defaultAction)
                    .edgeBarButtonStyle(prominent: true)
                    .disabled(effectivePreset == nil)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            customFolder = url
        } else if customFolder == nil {
            locationOverride = .preset
        }
    }

    private func convertSelected() {
        guard let preset = effectivePreset else { return }
        onConvert([(recognized, preset)])
    }

    // MARK: - Other states

    private var recoveryMessage: some View {
        ContentUnavailableView {
            Label("Your presets need attention", systemImage: "exclamationmark.triangle")
        } description: {
            Text("File Converter could not read your preset library. Recover it in Settings before converting.")
        } actions: {
            Button("Open Preset Settings…", action: onManagePresets)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unsupportedOnly: some View {
        ContentUnavailableView {
            Label("These files can't be converted", systemImage: "doc.questionmark")
        } description: {
            Text(unsupported.prefix(5).map(\.lastPathComponent).joined(separator: "\n"))
        } actions: {
            Button("OK", action: onCancel).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noPresets: some View {
        ContentUnavailableView {
            Label("No preset fits these files", systemImage: "slider.horizontal.3")
        } description: {
            Text("Turn on or create a preset for \(Set(recognized.map { $0.pathExtension.uppercased() }).sorted().joined(separator: ", ")) files in Settings.")
        } actions: {
            Button("Manage Presets…", action: onManagePresets)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Files of different kinds (photos and videos): one preset per kind, one
/// Convert button.
private struct MixedBatchView: View {
    let groups: [(category: FormatCategory, urls: [URL])]
    let options: AnyView
    let applyingOverrides: (ConversionPreset) -> ConversionPreset
    let onCancel: () -> Void
    let onConvert: ([(urls: [URL], preset: ConversionPreset)]) -> Void
    let onManagePresets: () -> Void

    @State private var choices: [FormatCategory: UUID] = [:]
    @State private var included: Set<FormatCategory> = []

    private func presets(for urls: [URL]) -> [ConversionPreset] {
        PresetValidator.compatiblePresets(forURLs: urls)
    }

    /// "Clip.mov", "a.jpg, b.jpg", or "a.jpg, b.jpg, and 3 more".
    static func names(_ urls: [URL]) -> String {
        let shown = urls.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
        return urls.count > 2 ? "\(shown), and \(urls.count - 2) more" : shown
    }

    /// The chosen presets' photo and video notes, without repeats.
    private var metadataNote: String? {
        var notes: [String] = []
        for group in groups where included.contains(group.category) {
            let options = presets(for: group.urls)
            let id = choices[group.category] ?? options.first?.id
            guard let preset = options.first(where: { $0.id == id }),
                  let note = DestinationDescription.metadataNote(for: applyingOverrides(preset)),
                  !notes.contains(note) else { continue }
            notes.append(note)
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("These files are of different kinds. Choose a preset for each kind, or uncheck a kind to leave it out.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            Form {
                ForEach(groups, id: \.category) { group in
                    let options = presets(for: group.urls)
                    let isIncluded = Binding(
                        get: { included.contains(group.category) },
                        set: { if $0 { included.insert(group.category) } else { included.remove(group.category) } }
                    )
                    HStack {
                        Toggle(isOn: isIncluded) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Inflect.string("\(group.category.displayName): ^[\(group.urls.count) file](inflect: true)"))
                                Text(Self.names(group.urls))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(options.isEmpty)
                        Spacer()
                        if options.isEmpty {
                            Text("No preset fits").foregroundStyle(.secondary)
                        } else {
                            Picker("Preset for \(group.category.displayName)", selection: Binding(
                                get: { choices[group.category] ?? options[0].id },
                                set: { choices[group.category] = $0 }
                            )) {
                                ForEach(options) { preset in
                                    Text(preset.menuName).tag(preset.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .disabled(!isIncluded.wrappedValue)
                        }
                    }
                }
                Section("Options for This Conversion") {
                    options
                }
            }
            .formStyle(.grouped)
            .edgeBar(.bottom, style: .sheet) { footer }
        }
        .onAppear {
            for group in groups {
                let options = presets(for: group.urls)
                guard !options.isEmpty else { continue }
                included.insert(group.category)
                choices[group.category] = PresetUsageStore.lastCompatiblePreset(for: group.urls, among: options)?.id ?? options[0].id
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note = metadataNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Manage Presets…", action: onManagePresets)
                    .edgeBarButtonStyle()
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .edgeBarButtonStyle()
                Button("Convert") {
                    let work = groups.compactMap { group -> (urls: [URL], preset: ConversionPreset)? in
                        guard included.contains(group.category) else { return nil }
                        let options = presets(for: group.urls)
                        let id = choices[group.category] ?? options.first?.id
                        guard let preset = options.first(where: { $0.id == id }) else { return nil }
                        return (group.urls, applyingOverrides(preset))
                    }
                    onConvert(work)
                }
                .keyboardShortcut(.defaultAction)
                .edgeBarButtonStyle(prominent: true)
                .disabled(included.isEmpty)
            }
        }
    }
}
