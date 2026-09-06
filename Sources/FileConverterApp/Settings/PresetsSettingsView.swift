import AppKit
import FileConverterCore
import SwiftUI
import UniformTypeIdentifiers

public struct PresetsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    @State private var presets: [ConversionPreset] = []
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var categoryFilter: FormatCategory?
    @State private var showingDeleteConfirmation = false
    @State private var showingResetConfirmation = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    @State private var replaceOnImport = false
    @State private var isEditorDirty = false
    @State private var showingUnsavedChangesConfirmation = false
    @State private var pendingEditorAction: PendingEditorAction?
    @State private var showingNewPresetWizard = false

    private enum PendingEditorAction {
        case select(UUID?)
        case add
        case duplicate(UUID)
        case delete(UUID)
        case toggle(UUID)
        case importPresets
        case resetAll
    }

    public init() {}

    public var body: some View {
        LiquidGlassContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 14) {
                    SettingsIconBadge(systemImage: "slider.horizontal.3", color: .purple, size: .header)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Presets")
                            .font(.title2.weight(.bold))

                        Text("Choose what appears in Finder and how each conversion is performed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()

                HSplitView {
                    presetSidebar
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360, maxHeight: .infinity)

                    presetDetail
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
        .onChange(of: searchText) { _, _ in normalizeSelectionForFilter() }
        .onChange(of: categoryFilter) { _, _ in normalizeSelectionForFilter() }
        .sheet(isPresented: $showingNewPresetWizard) {
            NewPresetWizardView { preset in
                addPreset(preset)
            }
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage.isEmpty ? "That file is not a valid presets export." : importErrorMessage)
        }
        .confirmationDialog(
            "Delete this preset?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Preset", role: .destructive) {
                deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectedPreset?.isBuiltIn == true ? "Built-in presets are disabled instead of deleted. Restore it from the editor or reset factory values." : "Deleted custom presets cannot be recovered unless you exported them.")
        }
        .confirmationDialog(
            "Reset all presets to factory values?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All Presets", role: .destructive) {
                PresetStore.shared.resetToDefaults()
                selection = nil
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Custom presets will be removed and built-in presets will return to their original settings.")
        }
        .confirmationDialog(
            "Discard unsaved preset changes?",
            isPresented: $showingUnsavedChangesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) {
                let action = pendingEditorAction
                pendingEditorAction = nil
                isEditorDirty = false
                if let action { perform(action) }
            }
            Button("Keep Editing", role: .cancel) {
                pendingEditorAction = nil
            }
        } message: {
            Text("Save or revert the current preset before switching to another one.")
        }
        .onDeleteCommand {
            if selection != nil {
                showingDeleteConfirmation = true
            }
        }
    }

    private var presetSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search presets", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Category", selection: $categoryFilter) {
                    Text("All Categories").tag(nil as FormatCategory?)
                    ForEach(FormatCategory.allCases) { category in
                        Text(category.displayName).tag(category as FormatCategory?)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(10)

            Divider()

            if filteredPresets.isEmpty {
                ContentUnavailableView(
                    "No Matching Presets",
                    systemImage: "magnifyingglass",
                    description: Text("Change the search or category filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: guardedSelection) {
                    ForEach(filteredPresets) { preset in
                        PresetSidebarRow(preset: preset)
                            .tag(preset.id)
                            .contextMenu {
                                Button(preset.isEnabled ? "Disable" : "Enable") {
                                    request(.toggle(preset.id))
                                }
                                Button("Duplicate") {
                                    request(.duplicate(preset.id))
                                }
                                Divider()
                                Button(preset.isBuiltIn ? "Disable" : "Delete", role: .destructive) {
                                    request(.delete(preset.id))
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack(spacing: 6) {
                Button {
                    request(.add)
                } label: {
                    Image(systemName: "plus")
                }
                .help("Create a preset from a common recipe")
                .accessibilityLabel("Create preset")

                Button {
                    if let selectedPreset {
                        request(.duplicate(selectedPreset.id))
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selectedPreset == nil)
                .help("Duplicate selected preset")

                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: selectedPreset?.isBuiltIn == true ? "eye.slash" : "trash")
                }
                .disabled(selectedPreset == nil)
                .help(selectedPreset?.isBuiltIn == true ? "Disable selected built-in preset" : "Delete selected preset")

                Spacer()

                Menu {
                    Button("Import Presets...") {
                        request(.importPresets)
                    }
                    Button("Export Presets...") {
                        exportPresets()
                    }
                    Divider()
                    Toggle("Replace matching presets on import", isOn: $replaceOnImport)
                    Divider()
                    Button("Reset All Presets...", role: .destructive) {
                        request(.resetAll)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("More preset actions")
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var presetDetail: some View {
        if let selectedPreset {
            PresetEditorView(
                presetID: selectedPreset.id,
                onSaved: reload,
                onDeleted: {
                    selection = nil
                    isEditorDirty = false
                    reload()
                },
                onDirtyChange: { isEditorDirty = $0 }
            )
            .id(selectedPreset.id)
        } else {
            ContentUnavailableView(
                "Select a Preset",
                systemImage: "slider.horizontal.3",
                description: Text("Choose a preset on the left, or create a new one.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filteredPresets: [ConversionPreset] {
        var result = presets

        if let categoryFilter {
            result = result.filter { $0.category == categoryFilter }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { preset in
                preset.name.lowercased().contains(query)
                    || preset.menuName.lowercased().contains(query)
                    || preset.destinationFormat.lowercased().contains(query)
            }
        }

        return result
    }

    private var selectedPreset: ConversionPreset? {
        guard let selection else { return nil }
        return presets.first { $0.id == selection }
    }

    private var guardedSelection: Binding<UUID?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard newSelection != selection else { return }
                request(.select(newSelection))
            }
        )
    }

    private func reload() {
        presets = PresetStore.shared.presets

        if let selection, !presets.contains(where: { $0.id == selection }) {
            self.selection = nil
        }

        normalizeSelectionForFilter()
    }

    private func normalizeSelectionForFilter() {
        let visibleIDs = Set(filteredPresets.map(\.id))
        if let selection, visibleIDs.contains(selection) {
            return
        }
        // Keep an actively edited preset visible in the detail pane even if a
        // filter temporarily hides its row. This prevents search from silently
        // destroying an unsaved draft.
        if selection != nil { return }
        selection = filteredPresets.first?.id
    }

    private func toggleEnabled(_ preset: ConversionPreset) {
        var updatedPreset = preset
        updatedPreset.isEnabled.toggle()
        PresetStore.shared.updatePreset(updatedPreset)
        reload()
    }

    private func addPreset(_ template: ConversionPreset) {
        var preset = template
        preset.outputDirectoryPolicy = settings.defaultOutputPolicy
        preset.filenamePattern = settings.defaultFilenamePattern
        preset.overwritePolicy = settings.defaultOverwritePolicy
        preset.preserveCreationDate = settings.preserveTimestamps

        PresetStore.shared.addPreset(preset)
        presets = PresetStore.shared.presets
        categoryFilter = nil
        searchText = ""
        selection = preset.id
    }

    private func duplicate(_ preset: ConversionPreset) {
        guard let copy = PresetStore.shared.duplicatePreset(withID: preset.id) else { return }
        presets = PresetStore.shared.presets
        categoryFilter = nil
        searchText = ""
        selection = copy.id
    }

    private func deleteSelected() {
        guard let selection else { return }
        PresetStore.shared.deletePreset(withID: selection)
        self.selection = nil
        reload()
    }

    private func request(_ action: PendingEditorAction) {
        if isEditorDirty {
            pendingEditorAction = action
            showingUnsavedChangesConfirmation = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingEditorAction) {
        switch action {
        case .select(let id):
            selection = id
        case .add:
            showingNewPresetWizard = true
        case .duplicate(let id):
            guard let preset = presets.first(where: { $0.id == id }) else { return }
            duplicate(preset)
        case .delete(let id):
            selection = id
            showingDeleteConfirmation = true
        case .toggle(let id):
            guard let preset = presets.first(where: { $0.id == id }) else { return }
            toggleEnabled(preset)
        case .importPresets:
            importPresets()
        case .resetAll:
            showingResetConfirmation = true
        }
    }

    private func exportPresets() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "file-converter-presets.json"
        panel.allowedContentTypes = [.json]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try PresetStore.shared.exportPresetsJSON().write(to: url)
            } catch {
                Task { @MainActor in
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let data = try Data(contentsOf: url)
                try PresetStore.shared.importPresetsJSON(data, overwrite: replaceOnImport)
                Task { @MainActor in
                    reload()
                }
            } catch {
                Task { @MainActor in
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }
    }
}

private struct PresetSidebarRow: View {
    let preset: ConversionPreset

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: preset.category.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.menuName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if !preset.isEnabled {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .help("Disabled")
            } else if !BackendResolver.shared.supportsAnySource(for: preset) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Requires an external tool")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let kind = preset.isBuiltIn ? "Built-in" : "Custom"
        return "\(kind)  ·  \(sourceSummary) → .\(preset.destinationFormat.uppercased())"
    }

    private var sourceSummary: String {
        let sources = Set(preset.sourceFormats.map { $0.lowercased() })
        if sources == ["*"] { return "Any file" }
        if sources == ["audio", "video"] { return "Audio/video" }
        if sources.count == 1, let source = sources.first {
            if let category = FormatCategory(rawValue: source) {
                return "Any \(category.displayName.lowercased())"
            }
            if let format = FormatRegistry.shared.format(forID: source) {
                return format.primaryExtension.uppercased()
            }
        }
        return "Custom sources"
    }
}

private enum PresetTemplate: String, CaseIterable, Identifiable, Hashable {
    case imageToJPEG
    case heicToJPEG
    case heicToPNG
    case imageToPNG
    case videoToMP4
    case audioToMP3
    case documentToPDF
    case startBlank

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageToJPEG: return "Images → JPEG"
        case .heicToJPEG: return "HEIC photos → JPEG"
        case .heicToPNG: return "HEIC photos → PNG"
        case .imageToPNG: return "Images → PNG"
        case .videoToMP4: return "Video → MP4"
        case .audioToMP3: return "Audio/video → MP3"
        case .documentToPDF: return "Documents → PDF"
        case .startBlank: return "Start from scratch"
        }
    }

    var subtitle: String {
        switch self {
        case .imageToJPEG: return "A small, widely compatible photo file"
        case .heicToJPEG: return "Share iPhone photos with almost anyone"
        case .heicToPNG: return "Keep a lossless image for editing"
        case .imageToPNG: return "Keep transparency and image quality"
        case .videoToMP4: return "The safest choice for video sharing"
        case .audioToMP3: return "Play audio on phones, cars, and web apps"
        case .documentToPDF: return "Make a document that looks the same everywhere"
        case .startBlank: return "Choose every detail yourself"
        }
    }

    var systemImage: String {
        switch self {
        case .imageToJPEG, .heicToJPEG, .heicToPNG, .imageToPNG: return "photo"
        case .videoToMP4: return "film"
        case .audioToMP3: return "waveform"
        case .documentToPDF: return "doc.text"
        case .startBlank: return "slider.horizontal.3"
        }
    }

    func makePreset() -> ConversionPreset {
        switch self {
        case .imageToJPEG:
            return ConversionPreset(
                name: "Images to JPEG",
                menuName: "Images → JPEG",
                category: .image,
                sourceFormats: ["image"],
                destinationFormat: "jpg",
                backend: .imageIO,
                quality: .high
            )
        case .heicToJPEG:
            return ConversionPreset(
                name: "HEIC Photos to JPEG",
                menuName: "HEIC → JPEG",
                category: .image,
                sourceFormats: ["heic"],
                destinationFormat: "jpg",
                backend: .imageIO,
                quality: .high
            )
        case .heicToPNG:
            return ConversionPreset(
                name: "HEIC Photos to PNG",
                menuName: "HEIC → PNG",
                category: .image,
                sourceFormats: ["heic"],
                destinationFormat: "png",
                backend: .imageIO,
                quality: .lossless
            )
        case .imageToPNG:
            return ConversionPreset(
                name: "Images to PNG",
                menuName: "Images → PNG",
                category: .image,
                sourceFormats: ["image"],
                destinationFormat: "png",
                backend: .imageIO,
                quality: .lossless
            )
        case .videoToMP4:
            return ConversionPreset(
                name: "Video to MP4",
                menuName: "Video → MP4",
                category: .video,
                sourceFormats: ["video"],
                destinationFormat: "mp4",
                backend: .auto,
                videoCodec: .h264,
                audioCodec: .aac,
                quality: .high,
                crf: 22
            )
        case .audioToMP3:
            return ConversionPreset(
                name: "Audio or Video to MP3",
                menuName: "Audio/video → MP3",
                category: .audio,
                sourceFormats: ["audio", "video"],
                destinationFormat: "mp3",
                backend: .auto,
                audioCodec: .mp3,
                quality: .high,
                audioBitrateKbps: 320
            )
        case .documentToPDF:
            return ConversionPreset(
                name: "Documents to PDF",
                menuName: "Documents → PDF",
                category: .document,
                sourceFormats: ["document", "image"],
                destinationFormat: "pdf",
                backend: .auto,
                quality: .high
            )
        case .startBlank:
            return ConversionPreset(
                name: "Custom Conversion",
                menuName: "Custom Conversion",
                category: .custom,
                sourceFormats: ["*"],
                destinationFormat: "jpg",
                backend: .auto,
                quality: .high
            )
        }
    }
}

private struct NewPresetWizardView: View {
    let onCreate: (ConversionPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: PresetTemplate = .imageToJPEG

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconBadge(systemImage: "wand.and.stars", color: .purple, size: .header)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Create a preset")
                        .font(.title2.weight(.bold))
                    Text("Start with a recipe. You can fine-tune it after it is created.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text("What do you usually want to do?")
                .font(.headline)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(PresetTemplate.allCases) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                SettingsIconBadge(
                                    systemImage: template.systemImage,
                                    color: template == selectedTemplate ? .accentColor : .secondary,
                                    size: .tool
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Text(template.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                            .background(
                                (template == selectedTemplate ? Color.accentColor.opacity(0.1) : Color.clear),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        template == selectedTemplate ? Color.accentColor : Color.secondary.opacity(0.25),
                                        lineWidth: template == selectedTemplate ? 1.5 : 0.75
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(template == selectedTemplate ? .isSelected : [])
                        .accessibilityLabel("\(template.title). \(template.subtitle)")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 330)

            SettingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected recipe")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(selectedTemplate.title)
                            .font(.body.weight(.medium))
                    }
                    Spacer()
                    Text("Editable after creation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Preset") {
                    onCreate(selectedTemplate.makePreset())
                    dismiss()
                }
                .glassActionProminent()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 620)
    }
}
