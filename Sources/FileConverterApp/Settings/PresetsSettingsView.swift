import SwiftUI
import FileConverterCore
import UniformTypeIdentifiers

public struct PresetsSettingsView: View {
    @State private var presets: [ConversionPreset] = []
    @State private var selectedPresetID: UUID?
    @State private var selectedCategoryFilter: FormatCategory?
    @State private var showingExportSuccess = false
    @State private var showingImportError = false
    @State private var importErrorMessage = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            if let id = selectedPresetID, let binding = bindingForPreset(id: id) {
                PresetDetailEditorView(preset: binding, onSave: {
                    PresetStore.shared.updatePreset(binding.wrappedValue)
                    reloadPresets()
                })
            } else {
                Text("Select a preset to inspect or edit.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            reloadPresets()
            if selectedPresetID == nil {
                selectedPresetID = presets.first?.id
            }
        }
    }

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Category Filter
            Picker("Category", selection: $selectedCategoryFilter) {
                Text("All Categories").tag(nil as FormatCategory?)
                ForEach(FormatCategory.allCases) { cat in
                    Text(cat.displayName).tag(cat as FormatCategory?)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selectedPresetID) {
                ForEach(filteredPresets) { preset in
                    HStack {
                        Image(systemName: preset.category.systemImage)
                            .foregroundColor(.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.menuName)
                                .font(.system(size: 13, weight: .medium))

                            Text(preset.name)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { preset.isEnabled },
                            set: { val in
                                var updated = preset
                                updated.isEnabled = val
                                PresetStore.shared.updatePreset(updated)
                                reloadPresets()
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    }
                    .tag(preset.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            // Bottom action toolbar
            HStack(spacing: 6) {
                Button(action: addNewPreset) {
                    Image(systemName: "plus")
                }
                .help("Add New Preset")

                Button(action: duplicateSelected) {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(selectedPresetID == nil)
                .help("Duplicate Selected Preset")

                Button(action: deleteSelected) {
                    Image(systemName: "trash")
                }
                .disabled(selectedPresetID == nil)
                .help("Delete Selected Preset")

                Spacer()

                Menu {
                    Button("Reset Built-In Presets") {
                        PresetStore.shared.resetToDefaults()
                        reloadPresets()
                    }
                    Divider()
                    Button("Export Presets JSON...") {
                        exportPresets()
                    }
                    Button("Import Presets JSON...") {
                        importPresets()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(8)
        }
    }

    private var filteredPresets: [ConversionPreset] {
        if let cat = selectedCategoryFilter {
            return presets.filter { $0.category == cat }
        }
        return presets
    }

    private func reloadPresets() {
        presets = PresetStore.shared.presets.filter {
            BackendResolver.shared.supportsAnySource(for: $0)
        }
    }

    private func bindingForPreset(id: UUID) -> Binding<ConversionPreset>? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.presets[index] },
            set: { self.presets[index] = $0 }
        )
    }

    private func addNewPreset() {
        let newPreset = ConversionPreset(
            name: "Custom Conversion",
            menuName: "Custom MP4",
            category: .video,
            sourceFormats: ["video"],
            destinationFormat: "mp4",
            isBuiltIn: false
        )
        PresetStore.shared.addPreset(newPreset)
        reloadPresets()
        selectedPresetID = newPreset.id
    }

    private func duplicateSelected() {
        guard let id = selectedPresetID,
              let dup = PresetStore.shared.duplicatePreset(withID: id) else { return }
        reloadPresets()
        selectedPresetID = dup.id
    }

    private func deleteSelected() {
        guard let id = selectedPresetID else { return }
        PresetStore.shared.deletePreset(withID: id)
        reloadPresets()
        selectedPresetID = presets.first?.id
    }

    private func exportPresets() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "file_converter_presets.json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let data = try? PresetStore.shared.exportPresetsJSON() {
                    try? data.write(to: url)
                }
            }
        }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
                do {
                    try PresetStore.shared.importPresetsJSON(data, overwrite: false)
                    reloadPresets()
                } catch {
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }
    }
}

public struct PresetDetailEditorView: View {
    @Binding var preset: ConversionPreset
    var onSave: () -> Void

    public var body: some View {
        Form {
            Section(header: Text("Preset Identity").font(.headline)) {
                TextField("Preset Full Name", text: $preset.name)
                TextField("Finder Menu Title", text: $preset.menuName)

                Picker("Category", selection: $preset.category) {
                    ForEach(FormatCategory.allCases) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }

                TextField("Destination Format Extension", text: $preset.destinationFormat)
            }

            Section(header: Text("Engine & Backend").font(.headline)) {
                Picker("Backend Engine", selection: $preset.backend) {
                    ForEach(BackendResolver.shared.registeredBackendTypes, id: \.self) { b in
                        Text(b.displayName).tag(b)
                    }
                }

                Picker("Quality Profile", selection: $preset.quality) {
                    ForEach(QualitySetting.allCases, id: \.self) { q in
                        Text(q.displayName).tag(q)
                    }
                }

                Picker("Hardware Acceleration", selection: $preset.hardwareAcceleration) {
                    ForEach(HardwareAccelerationPolicy.allCases, id: \.self) { h in
                        Text(h.displayName).tag(h)
                    }
                }
            }

            if preset.category == .video {
                Section(header: Text("Video Settings").font(.headline)) {
                    Picker("Video Codec", selection: $preset.videoCodec) {
                        ForEach(VideoCodecType.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }

                    if let crf = preset.crf {
                        Stepper("CRF Quality Target: \(crf)", value: Binding(
                            get: { preset.crf ?? 23 },
                            set: { preset.crf = $0 }
                        ), in: 0...51)
                    }

                    if let bitrate = preset.videoBitrateKbps {
                        Stepper("Video Bitrate: \(bitrate) kbps", value: Binding(
                            get: { preset.videoBitrateKbps ?? 4500 },
                            set: { preset.videoBitrateKbps = $0 }
                        ), in: 500...50000, step: 500)
                    }
                }
            }

            if preset.category == .audio || preset.category == .video {
                Section(header: Text("Audio Settings").font(.headline)) {
                    Picker("Audio Codec", selection: $preset.audioCodec) {
                        ForEach(AudioCodecType.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }

                    if let audioBitrate = preset.audioBitrateKbps {
                        Stepper("Audio Bitrate: \(audioBitrate) kbps", value: Binding(
                            get: { preset.audioBitrateKbps ?? 256 },
                            set: { preset.audioBitrateKbps = $0 }
                        ), in: 64...320, step: 32)
                    }
                }
            }

            Section(header: Text("Advanced").font(.headline)) {
                Toggle("Preserve Metadata & Tags", isOn: $preset.preserveMetadata)
                Toggle("Preserve File Creation Timestamp", isOn: $preset.preserveCreationDate)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: preset) { _, _ in
            onSave()
        }
    }
}
