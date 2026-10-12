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
    @State private var showingOptions = false
    @State private var locationOverride: LocationOverride = .preset
    @State private var qualityOverride: QualityOverride = .preset
    @State private var customFolder: URL?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case search, grid }

    enum LocationOverride: Hashable { case preset, sameFolder, downloads, chosen }
    enum QualityOverride: Hashable { case preset, smaller, balanced, higher }

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
                MixedBatchView(groups: groups, onCancel: onCancel, onConvert: onConvert)
            } else if compatible.isEmpty {
                noPresets
            } else {
                presetGrid
                Divider()
                footer
                    .padding(16)
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

    // MARK: - Grid

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search", text: $searchText, prompt: Text("Search presets"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
                .onSubmit { focus = .grid }
                .accessibilityLabel("Search compatible presets")
                .padding(.horizontal, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    if ordered.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            if !recent.isEmpty {
                                section(title: "Recent", systemImage: "clock", presets: recent)
                            }
                            let recentIDs = Set(recent.map(\.id))
                            ForEach(FormatCategory.allCases) { category in
                                let presets = filtered.filter { $0.category == category && !recentIDs.contains($0.id) }
                                if !presets.isEmpty {
                                    section(title: category.displayName, systemImage: category.systemImage, presets: presets)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
                .focusable()
                .focused($focus, equals: .grid)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in
                    move(-1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(keys: [.rightArrow, .downArrow]) { _ in
                    move(1, proxy: proxy)
                    return .handled
                }
                .onKeyPress(.return) {
                    convertSelected()
                    return .handled
                }
                .onKeyPress(characters: .alphanumerics) { press in
                    searchText += press.characters
                    focus = .search
                    return .handled
                }
            }
        }
    }

    private func section(title: String, systemImage: String, presets: [ConversionPreset]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                ForEach(presets) { preset in
                    tile(preset)
                }
            }
        }
    }

    private func tile(_ preset: ConversionPreset) -> some View {
        let isSelected = preset.id == selectedID
        return VStack(alignment: .leading, spacing: 2) {
            Text(preset.menuName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(preset.name)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                .lineLimit(1)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(isSelected ? 0 : 0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .id(preset.id)
        .onTapGesture(count: 2) {
            selectedID = preset.id
            convertSelected()
        }
        .onTapGesture {
            selectedID = preset.id
            focus = .grid
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectedID = preset.id; convertSelected() }
    }

    private func move(_ step: Int, proxy: ScrollViewProxy) {
        let list = ordered
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? -1
        let next = list[max(0, min(list.count - 1, index + step))]
        selectedID = next.id
        proxy.scrollTo(next.id)
    }

    // MARK: - Footer

    private var effectivePreset: ConversionPreset? {
        guard var preset = selectedPreset else { return nil }
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
        switch qualityOverride {
        case .preset: break
        case .smaller: preset.quality = .low
        case .balanced: preset.quality = .medium
        case .higher: preset.quality = .veryHigh
        }
        return preset
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preset = effectivePreset {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Saves to")
                        .foregroundStyle(.secondary)
                    Text(DestinationDescription.folder(for: preset))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let name = DestinationDescription.exampleName(for: preset, source: recognized.first) {
                        Text("as").foregroundStyle(.secondary)
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.callout.monospaced())
                    }
                }
                .font(.callout)
            }

            DisclosureGroup("Options for This Conversion", isExpanded: $showingOptions) {
                Form {
                    Picker("Save to", selection: $locationOverride) {
                        Text("As the preset says").tag(LocationOverride.preset)
                        Text("Same folder as the original").tag(LocationOverride.sameFolder)
                        Text("Downloads").tag(LocationOverride.downloads)
                        Text(customFolder.map { "“\($0.lastPathComponent)”" } ?? "Choose a Folder…").tag(LocationOverride.chosen)
                    }
                    .onChange(of: locationOverride) { _, newValue in
                        if newValue == .chosen && customFolder == nil { chooseFolder() }
                    }
                    if !(selectedPreset?.isInteractiveWorkflow ?? false), selectedPreset?.category != .document {
                        Picker("Quality", selection: $qualityOverride) {
                            Text("As the preset says").tag(QualityOverride.preset)
                            Text("Smaller file").tag(QualityOverride.smaller)
                            Text("Balanced").tag(QualityOverride.balanced)
                            Text("Higher quality").tag(QualityOverride.higher)
                        }
                    }
                }
                .formStyle(.columns)
                .padding(.top, 6)
            }
            .font(.callout)

            HStack {
                Button("Manage Presets…", action: onManagePresets)
                    .buttonStyle(.link)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Convert") { convertSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
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
    let onCancel: () -> Void
    let onConvert: ([(urls: [URL], preset: ConversionPreset)]) -> Void

    @State private var choices: [FormatCategory: UUID] = [:]
    @State private var included: Set<FormatCategory> = []

    private func presets(for urls: [URL]) -> [ConversionPreset] {
        PresetValidator.compatiblePresets(forURLs: urls)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("These files are of different kinds. Choose a preset for each kind.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            Form {
                ForEach(groups, id: \.category) { group in
                    let options = presets(for: group.urls)
                    HStack {
                        Toggle(isOn: Binding(
                            get: { included.contains(group.category) },
                            set: { if $0 { included.insert(group.category) } else { included.remove(group.category) } }
                        )) {
                            Label("\(group.category.displayName) (\(group.urls.count))", systemImage: group.category.systemImage)
                        }
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
                            .frame(width: 220)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Convert") {
                    let work = groups.compactMap { group -> (urls: [URL], preset: ConversionPreset)? in
                        guard included.contains(group.category) else { return nil }
                        let options = presets(for: group.urls)
                        let id = choices[group.category] ?? options.first?.id
                        guard let preset = options.first(where: { $0.id == id }) else { return nil }
                        return (group.urls, preset)
                    }
                    onConvert(work)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(included.isEmpty)
            }
            .padding(16)
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
}
