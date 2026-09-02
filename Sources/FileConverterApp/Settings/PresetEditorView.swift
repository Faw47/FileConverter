import SwiftUI
import AppKit
import FileConverterCore
import UniformTypeIdentifiers

public struct PresetEditorView: View {
    private let presetID: UUID
    private let onSaved: () -> Void
    private let onDeleted: () -> Void

    @State private var draft: ConversionPreset?
    @State private var sourceScope: SourceScope = .category
    @State private var subfolderName = ""
    @State private var showingDeleteConfirm = false
    @State private var saveFlash = false

    private enum SourceScope: String, CaseIterable {
        case category = "This section only"
        case audioVideo = "Audio & video"
        case any = "Any file"

        var help: String {
            switch self {
            case .category: return "Matches the preset's own section."
            case .audioVideo: return "Shows for every audio or video file."
            case .any: return "Shows for every file (use sparingly)."
            }
        }
    }

    public init(presetID: UUID, onSaved: @escaping () -> Void, onDeleted: @escaping () -> Void) {
        self.presetID = presetID
        self.onSaved = onSaved
        self.onDeleted = onDeleted
    }

    public var body: some View {
        Group {
            if draft != nil {
                editor(for: Binding(get: { draft! }, set: { draft = $0 }))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Delete this preset?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Preset", role: .destructive) {
                PresetStore.shared.deletePreset(withID: presetID)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func editor(for preset: Binding<ConversionPreset>) -> some View {
        let errors = validationErrors(for: preset.wrappedValue)
        return Form {
            Section {
                Toggle("Enabled", isOn: preset.isEnabled)
                    .accessibilityLabel("Preset enabled")
                    .help("Disabled presets never appear in Finder or the convert sheet.")

                if preset.wrappedValue.isBuiltIn {
                    Text("Built-in preset — your edits are kept across updates; Reset restores the original.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !BackendResolver.shared.supportsAnySource(for: preset.wrappedValue) {
                    Label("No installed backend can run this preset yet. Open External Tools to install what's missing.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("State").font(.headline)
            }

            Section {
                TextField("Full name", text: preset.name, prompt: Text("e.g. MP3 Audio (320 kbps)"))
                    .accessibilityLabel("Preset full name")
                TextField("Menu title", text: preset.menuName, prompt: Text("e.g. MP3"))
                    .accessibilityLabel("Finder menu title")
                    .help("Short label shown in Finder and the convert sheet.")
                Picker("Section", selection: preset.category) {
                    ForEach(FormatCategory.allCases) { cat in
                        Text(cat.displayName).tag(cat)
                    }
                }
                .accessibilityLabel("Preset section")
                Picker("Shows for", selection: $sourceScope) {
                    ForEach(SourceScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .accessibilityLabel("Which files show this preset")
                .help(sourceScope.help)
                .onChange(of: sourceScope) { _, scope in
                    applyScope(scope, to: preset)
                }

                TextField("Output extension", text: preset.destinationFormat, prompt: Text("mp3"))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Output file extension")
                    .help("Lowercase extension without the dot, e.g. mp3, m4a, mkv.")
                    .onChange(of: preset.wrappedValue.destinationFormat) { _, value in
                        let clean = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if clean != value { preset.wrappedValue.destinationFormat = clean }
                    }

                if let format = resolvedFormat(for: preset.wrappedValue) {
                    Text("\(format.name) · \(format.category.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !preset.wrappedValue.destinationFormat.isEmpty {
                    Text("Unknown output format “.\(preset.wrappedValue.destinationFormat)” — pick a format from the matrix in Help.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Identity & Matching").font(.headline)
            }

            Section {
                Picker("Engine", selection: preset.backend) {
                    ForEach(BackendResolver.shared.registeredBackendTypes, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .accessibilityLabel("Backend engine")
                .help("Auto picks the best installed engine. Pin one only to debug a failure.")

                Picker("Quality", selection: preset.quality) {
                    ForEach(QualitySetting.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }

                Picker("Hardware", selection: preset.hardwareAcceleration) {
                    ForEach(HardwareAccelerationPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .accessibilityLabel("Hardware acceleration")
            } header: {
                Text("Engine").font(.headline)
            }

            if preset.wrappedValue.category == .video {
                Section {
                    Picker("Video codec", selection: preset.videoCodec) {
                        ForEach(VideoCodecType.allCases, id: \.self) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    if preset.wrappedValue.videoBitrateKbps != nil {
                        Stepper(
                            "Video bitrate: \(preset.wrappedValue.videoBitrateKbps ?? 4500) kbps",
                            value: Binding(get: { preset.wrappedValue.videoBitrateKbps ?? 4500 }, set: { preset.wrappedValue.videoBitrateKbps = $0 }),
                            in: 500...50000, step: 500
                        )
                    }
                    if preset.wrappedValue.crf != nil {
                        Stepper(
                            "CRF target: \(preset.wrappedValue.crf ?? 23)",
                            value: Binding(get: { preset.wrappedValue.crf ?? 23 }, set: { preset.wrappedValue.crf = $0 }),
                            in: 0...51
                        )
                    }
                } header: {
                    Text("Video").font(.headline)
                }
            }

            if preset.wrappedValue.category == .audio || preset.wrappedValue.category == .video {
                Section {
                    Picker("Audio codec", selection: preset.audioCodec) {
                        ForEach(AudioCodecType.allCases, id: \.self) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    if preset.wrappedValue.audioBitrateKbps != nil {
                        Stepper(
                            "Audio bitrate: \(preset.wrappedValue.audioBitrateKbps ?? 256) kbps",
                            value: Binding(get: { preset.wrappedValue.audioBitrateKbps ?? 256 }, set: { preset.wrappedValue.audioBitrateKbps = $0 }),
                            in: 32...512, step: 32
                        )
                    } else {
                        Button("Add audio bitrate control") {
                            preset.wrappedValue.audioBitrateKbps = 256
                        }
                        .controlSize(.small)
                    }
                } header: {
                    Text("Audio").font(.headline)
                }
            }

            Section {
                Picker("Save converted files to", selection: outputPolicySelection(for: preset)) {
                    Text("Same folder as source").tag(OutputChoice.sameAsSource)
                    Text("Downloads folder").tag(OutputChoice.downloads)
                    Text("Named subfolder").tag(OutputChoice.subfolder)
                    Text("Chosen folder...").tag(OutputChoice.custom)
                }
                .accessibilityLabel("Output folder")

                if case .sourceSubfolder = preset.wrappedValue.outputDirectoryPolicy {
                    TextField("Subfolder name", text: $subfolderName, prompt: Text("Converted"))
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Subfolder name")
                        .help("Single folder name — no slashes.")
                        .onChange(of: subfolderName) { _, name in
                            preset.wrappedValue.outputDirectoryPolicy = .sourceSubfolder(subfolderName: name)
                        }
                }

                if case .customFolder(_, let displayPath) = preset.wrappedValue.outputDirectoryPolicy {
                    Text(displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Choose Another Folder...") { chooseCustomFolder(for: preset) }
                            .controlSize(.small)
                        Button("Use Source Folder Instead") {
                            preset.wrappedValue.outputDirectoryPolicy = .sameAsSource
                        }
                        .controlSize(.small)
                    }
                }

                TextField("Filename pattern", text: preset.filenamePattern, prompt: Text("{name}"))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Filename pattern")
                    .help("Tokens: {name} {preset} {date} {time} {ext}.")
                Text("Saves as “\(filenamePreview(for: preset.wrappedValue))”")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("If the file already exists", selection: preset.overwritePolicy) {
                    ForEach(OverwritePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .accessibilityLabel("Conflict policy")
            } header: {
                Text("Output").font(.headline)
            }

            Section {
                Toggle("Preserve metadata & tags", isOn: preset.preserveMetadata)
                Toggle("Preserve creation date", isOn: preset.preserveCreationDate)
            } header: {
                Text("Metadata").font(.headline)
            }

            if !errors.isEmpty {
                Section {
                    ForEach(errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Needs Attention").font(.headline)
                }
            }

            Section {
                HStack {
                    Button("Revert") { load() }
                        .disabled(!hasChanges)
                        .keyboardShortcut("z", modifiers: .command)
                    Spacer()
                    if saveFlash {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Button("Delete...", role: .destructive) { showingDeleteConfirm = true }
                    Button("Save Preset") { save(preset.wrappedValue) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges || !errors.isEmpty)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private enum OutputChoice: Hashable {
        case sameAsSource, downloads, subfolder, custom
    }

    private func outputPolicySelection(for preset: Binding<ConversionPreset>) -> Binding<OutputChoice> {
        Binding(
            get: {
                switch preset.wrappedValue.outputDirectoryPolicy {
                case .sameAsSource: return .sameAsSource
                case .downloads: return .downloads
                case .sourceSubfolder: return .subfolder
                case .customFolder: return .custom
                }
            },
            set: { choice in
                switch choice {
                case .sameAsSource:
                    preset.wrappedValue.outputDirectoryPolicy = .sameAsSource
                case .downloads:
                    preset.wrappedValue.outputDirectoryPolicy = .downloads
                case .subfolder:
                    if subfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        subfolderName = "Converted"
                    }
                    preset.wrappedValue.outputDirectoryPolicy = .sourceSubfolder(subfolderName: subfolderName)
                case .custom:
                    chooseCustomFolder(for: preset)
                }
            }
        )
    }

    private var hasChanges: Bool {
        guard let draft, let stored = PresetStore.shared.preset(forID: presetID) else { return false }
        return draft != stored
    }

    private func load() {
        guard let stored = PresetStore.shared.preset(forID: presetID) else {
            draft = nil
            return
        }
        draft = stored
        sourceScope = inferredScope(for: stored)
        if case .sourceSubfolder(let name) = stored.outputDirectoryPolicy {
            subfolderName = name
        } else if subfolderName.isEmpty {
            subfolderName = "Converted"
        }
        saveFlash = false
    }

    private func save(_ preset: ConversionPreset) {
        PresetStore.shared.updatePreset(preset)
        onSaved()
        saveFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            saveFlash = false
        }
    }

    private func inferredScope(for preset: ConversionPreset) -> SourceScope {
        let set = Set(preset.sourceFormats.map { $0.lowercased() })
        if set == ["*"] { return .any }
        if set == ["audio", "video"] { return .audioVideo }
        return .category
    }

    private func applyScope(_ scope: SourceScope, to preset: Binding<ConversionPreset>) {
        switch scope {
        case .category:
            preset.wrappedValue.sourceFormats = [preset.wrappedValue.category.rawValue.lowercased()]
        case .audioVideo:
            preset.wrappedValue.sourceFormats = ["audio", "video"]
        case .any:
            preset.wrappedValue.sourceFormats = ["*"]
        }
    }

    private func resolvedFormat(for preset: ConversionPreset) -> FormatDefinition? {
        let key = preset.destinationFormat.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return FormatRegistry.shared.format(forID: key) ?? FormatRegistry.shared.format(forExtension: key)
    }

    private func validationErrors(for preset: ConversionPreset) -> [String] {
        var errors: [String] = []
        if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give the preset a full name.")
        }
        if preset.menuName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Give the preset a short menu title.")
        }
        let ext = preset.destinationFormat.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ext.isEmpty {
            errors.append("Choose an output extension like mp3 or mkv.")
        } else if let format = FormatRegistry.shared.format(forID: ext) ?? FormatRegistry.shared.format(forExtension: ext) {
            if !format.supportedOutput {
                errors.append(".\(ext) is input-only — pick a writable format.")
            }
        } else {
            errors.append("Unknown output format “.\(ext)”.")
        }
        if preset.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Filename pattern cannot be empty (use {name}).")
        }
        if case .sourceSubfolder(let name) = preset.outputDirectoryPolicy {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == "." || clean == ".." || clean.contains("/") || clean.contains("\\") {
                errors.append("Subfolder must be a single folder name.")
            }
        }
        if preset.sourceFormats.isEmpty {
            errors.append("Pick which files show this preset.")
        }
        return errors
    }

    private func filenamePreview(for preset: ConversionPreset) -> String {
        let sample = URL(fileURLWithPath: "/tmp/Example Clip.mov")
        var preview = preset
        if preview.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preview.filenamePattern = "{name}"
        }
        return OutputNamingEngine.generateFormattedFilename(
            sourceURL: sample,
            preset: preview,
            targetExtension: preview.destinationFormat.isEmpty ? "mp4" : preview.destinationFormat
        )
    }

    private func chooseCustomFolder(for preset: Binding<ConversionPreset>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Converted files for this preset will be saved here."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                Task { @MainActor in
                    preset.wrappedValue.outputDirectoryPolicy = .customFolder(bookmarkData: data, displayPath: url.path)
                }
            } catch {
                NSSound.beep()
            }
        }
    }
}
