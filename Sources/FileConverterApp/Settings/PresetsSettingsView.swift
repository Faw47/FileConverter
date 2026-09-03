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

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(
                title: "Presets",
                subtitle: "Choose what appears in Finder and how each conversion is performed.",
                systemImage: "slider.horizontal.3"
            )
            Divider()

            HSplitView {
                presetSidebar
                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 340)

                presetDetail
                    .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
        .onChange(of: searchText) { _, _ in normalizeSelectionForFilter() }
        .onChange(of: categoryFilter) { _, _ in normalizeSelectionForFilter() }
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
            Text("Built-in presets can be restored with Reset All Presets. Deleted custom presets cannot be recovered unless you exported them.")
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
                List(selection: $selection) {
                    ForEach(filteredPresets) { preset in
                        PresetSidebarRow(preset: preset)
                            .tag(preset.id)
                            .contextMenu {
                                Button(preset.isEnabled ? "Disable" : "Enable") {
                                    toggleEnabled(preset)
                                }
                                Button("Duplicate") {
                                    duplicate(preset)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    selection = preset.id
                                    showingDeleteConfirmation = true
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            HStack(spacing: 6) {
                Button(action: addNewPreset) {
                    Image(systemName: "plus")
                }
                .help("Add preset")

                Button {
                    if let selectedPreset {
                        duplicate(selectedPreset)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selectedPreset == nil)
                .help("Duplicate selected preset")

                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedPreset == nil)
                .help("Delete selected preset")

                Spacer()

                Menu {
                    Button("Import Presets...") {
                        importPresets()
                    }
                    Button("Export Presets...") {
                        exportPresets()
                    }
                    Divider()
                    Toggle("Replace matching presets on import", isOn: $replaceOnImport)
                    Divider()
                    Button("Reset All Presets...", role: .destructive) {
                        showingResetConfirmation = true
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
                    reload()
                }
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
        selection = filteredPresets.first?.id
    }

    private func toggleEnabled(_ preset: ConversionPreset) {
        var updatedPreset = preset
        updatedPreset.isEnabled.toggle()
        PresetStore.shared.updatePreset(updatedPreset)
        reload()
    }

    private func addNewPreset() {
        var preset = ConversionPreset(
            name: "Custom Conversion",
            menuName: "Custom",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            outputDirectoryPolicy: settings.defaultOutputPolicyRaw == "downloads" ? .downloads : .sameAsSource,
            filenamePattern: settings.defaultFilenamePattern,
            overwritePolicy: settings.defaultOverwritePolicy,
            isBuiltIn: false
        )
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
        return "\(kind)  ·  .\(preset.destinationFormat)"
    }
}
