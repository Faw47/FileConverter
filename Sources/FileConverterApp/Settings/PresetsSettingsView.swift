import SwiftUI
import AppKit
import FileConverterCore
import UniformTypeIdentifiers

public struct PresetsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var presets: [ConversionPreset] = []
    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var categoryFilter: FormatCategory?
    @State private var showingDeleteConfirm = false
    @State private var showingResetConfirm = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    @State private var importOverwrites = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            if let id = selection, presets.contains(where: { $0.id == id }) {
                PresetEditorView(
                    presetID: id,
                    onSaved: reload,
                    onDeleted: {
                        selection = nil
                        reload()
                    }
                )
                .id(id)
            } else {
                ContentUnavailableView(
                    "Select a preset",
                    systemImage: "slider.horizontal.3",
                    description: Text("Pick a preset on the left to inspect it, or add a new one.")
                )
            }
        }
        .navigationTitle("Presets")
        .searchable(text: $searchText, prompt: "Search presets")
        .onAppear(perform: reload)
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage.isEmpty ? "That file is not a valid presets export." : importErrorMessage)
        }
        .confirmationDialog(
            "Delete this preset?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Preset", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Built-in presets return on Reset. Custom presets are gone for good.")
        }
        .confirmationDialog(
            "Reset every preset to factory values?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                PresetStore.shared.resetToDefaults()
                reload()
                selection = presets.first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your custom presets are removed and built-ins return to their original settings.")
        }
        .onDeleteCommand { deleteSelected() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("Category", selection: $categoryFilter) {
                Text("All").tag(nil as FormatCategory?)
                ForEach(FormatCategory.allCases) { cat in
                    Text(cat.displayName).tag(cat as FormatCategory?)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityLabel("Filter presets by category")

            Divider()

            List(selection: $selection) {
                ForEach(filtered) { preset in
                    HStack(spacing: 8) {
                        Image(systemName: preset.category.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.menuName)
                                .font(.system(size: 13, weight: .medium))
                            Text(subtitle(for: preset))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !preset.isEnabled {
                            Text("Off")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(.rect(cornerRadius: 6))
                                .accessibilityLabel("Preset disabled")
                        } else if !BackendResolver.shared.supportsAnySource(for: preset) {
                            Text("Needs tool")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18))
                                .foregroundStyle(.orange)
                                .clipShape(.rect(cornerRadius: 6))
                                .accessibilityLabel("Preset needs an external tool")
                        }
                    }
                    .tag(preset.id)
                    .contextMenu {
                        Button(preset.isEnabled ? "Disable" : "Enable") {
                            toggleEnabled(preset)
                        }
                        Button("Duplicate") { duplicate(preset) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            selection = preset.id
                            showingDeleteConfirm = true
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Button(action: addNew) {
                    Image(systemName: "plus")
                }
                .help("Add new preset")
                .accessibilityLabel("Add new preset")

                Button(action: { if let p = selectedPreset { duplicate(p) } }) {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selection == nil)
                .help("Duplicate selected preset")
                .accessibilityLabel("Duplicate selected preset")

                Button(action: { showingDeleteConfirm = true }) {
                    Image(systemName: "trash")
                }
                .disabled(selection == nil)
                .help("Delete selected preset (Delete)")
                .accessibilityLabel("Delete selected preset")

                Spacer()

                Menu {
                    Button("Export Presets JSON...") { exportPresets() }
                    Button("Import Presets JSON...") { importPresets() }
                    Divider()
                    Toggle("Replace on import", isOn: $importOverwrites)
                    Divider()
                    Button("Reset Built-In Presets...") { showingResetConfirm = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More preset actions")
            }
            .padding(8)
        }
    }

    private var filtered: [ConversionPreset] {
        var list = presets
        if let cat = categoryFilter {
            list = list.filter { $0.category == cat }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(query)
                    || $0.menuName.lowercased().contains(query)
                    || $0.destinationFormat.lowercased().contains(query)
            }
        }
        return list
    }

    private var selectedPreset: ConversionPreset? {
        guard let selection else { return nil }
        return presets.first { $0.id == selection }
    }

    private func subtitle(for preset: ConversionPreset) -> String {
        let kind = preset.isBuiltIn ? "Built-in" : "Custom"
        return "\(kind) · .\(preset.destinationFormat) · \(preset.backend.displayName.components(separatedBy: " ").first ?? "")"
    }

    private func reload() {
        presets = PresetStore.shared.presets
        if let selection, !presets.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        if selection == nil {
            selection = filtered.first?.id
        }
    }

    private func toggleEnabled(_ preset: ConversionPreset) {
        var updated = preset
        updated.isEnabled.toggle()
        PresetStore.shared.updatePreset(updated)
        reload()
    }

    private func addNew() {
        let custom = ConversionPreset(
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
        var preset = custom
        preset.preserveCreationDate = settings.preserveTimestamps
        let newID = preset.id
        PresetStore.shared.addPreset(preset)
        reload()
        selection = newID
    }

    private func duplicate(_ preset: ConversionPreset) {
        guard let copy = PresetStore.shared.duplicatePreset(withID: preset.id) else { return }
        reload()
        selection = copy.id
    }

    private func deleteSelected() {
        guard let id = selection else { return }
        PresetStore.shared.deletePreset(withID: id)
        selection = nil
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
                try PresetStore.shared.importPresetsJSON(data, overwrite: importOverwrites)
                Task { @MainActor in reload() }
            } catch {
                Task { @MainActor in
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }
    }
}
