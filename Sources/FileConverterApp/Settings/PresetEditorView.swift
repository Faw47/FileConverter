import AppKit
import FileConverterCore
import SwiftUI

public struct PresetEditorView: View {
    private let presetID: UUID
    private let onSaved: () -> Void
    private let onDeleted: () -> Void

    @State private var draft: ConversionPreset?
    @State private var sourceScope: SourceScope = .category
    @State private var subfolderName = "Converted"
    @State private var showingDeleteConfirmation = false
    @State private var savedIndicatorVisible = false

    private enum SourceScope: String, CaseIterable, Hashable {
        case category = "This category"
        case audioVideo = "Audio and video"
        case any = "Any file"

        var helpText: String {
            switch self {
            case .category: return "Show this preset only for files in its selected category."
            case .audioVideo: return "Show this preset for both audio and video files."
            case .any: return "Show this preset for every file type."
            }
        }
    }

    private enum OutputChoice: Hashable {
        case sameAsSource
        case downloads
        case subfolder
        case custom
    }

    public init(
        presetID: UUID,
        onSaved: @escaping () -> Void,
        onDeleted: @escaping () -> Void
    ) {
        self.presetID = presetID
        self.onSaved = onSaved
        self.onDeleted = onDeleted
    }

    public var body: some View {
        Group {
            if let draft {
                editor(for: Binding(
                    get: { self.draft ?? draft },
                    set: { self.draft = $0 }
                ))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete this preset?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Preset", role: .destructive) {
                PresetStore.shared.deletePreset(withID: presetID)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func editor(for preset: Binding<ConversionPreset>) -> some View {
        let errors = validationErrors(for: preset.wrappedValue)

        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: preset.wrappedValue.category.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.wrappedValue.name.isEmpty ? "Untitled Preset" : preset.wrappedValue.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(preset.wrappedValue.isBuiltIn ? "Built-in preset" : "Custom preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Enabled", isOn: preset.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(preset.wrappedValue.isEnabled ? "Preset enabled" : "Preset disabled")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()

            Form {
                Section("Name and Matching") {
                    TextField("Full name", text: preset.name, prompt: Text("MP3 Audio (320 kbps)"))
                    TextField("Menu title", text: preset.menuName, prompt: Text("MP3"))
                        .help("Short label shown in Finder and the conversion sheet.")

                    Picker("Category", selection: preset.category) {
                        ForEach(FormatCategory.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .onChange(of: preset.wrappedValue.category) { _, _ in
                        if sourceScope == .category {
                            applySourceScope(.category, to: preset)
                        }
                    }

                    Picker("Show for", selection: $sourceScope) {
                        ForEach(SourceScope.allCases, id: \.self) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .help(sourceScope.helpText)
                    .onChange(of: sourceScope) { _, newScope in
                        applySourceScope(newScope, to: preset)
                    }

                    TextField("Output extension", text: preset.destinationFormat, prompt: Text("mp3"))
                        .font(.system(.body, design: .monospaced))
                        .help("Enter the lowercase extension without a period.")
                        .onChange(of: preset.wrappedValue.destinationFormat) { _, newValue in
                            let normalized = newValue
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                                .lowercased()
                            if normalized != newValue {
                                preset.wrappedValue.destinationFormat = normalized
                            }
                        }

                    if let format = resolvedFormat(for: preset.wrappedValue) {
                        LabeledContent("Detected format") {
                            Text("\(format.name), \(format.category.displayName)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Conversion Engine") {
                    Picker("Engine", selection: preset.backend) {
                        ForEach(BackendResolver.shared.registeredBackendTypes, id: \.self) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .help("Auto chooses the best available engine unless a backend is explicitly selected.")

                    Picker("Quality", selection: preset.quality) {
                        ForEach(QualitySetting.allCases, id: \.self) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }

                    Picker("Hardware acceleration", selection: preset.hardwareAcceleration) {
                        ForEach(HardwareAccelerationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }

                    if !BackendResolver.shared.supportsAnySource(for: preset.wrappedValue) {
                        Label("No installed backend can run this preset. Check External Tools for missing dependencies.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if preset.wrappedValue.category == .video {
                    Section("Video") {
                        Picker("Video codec", selection: preset.videoCodec) {
                            ForEach(VideoCodecType.allCases, id: \.self) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }

                        if preset.wrappedValue.videoBitrateKbps != nil {
                            HStack {
                                Stepper(
                                    "Video bitrate: \(preset.wrappedValue.videoBitrateKbps ?? 4500) kbps",
                                    value: Binding(
                                        get: { preset.wrappedValue.videoBitrateKbps ?? 4500 },
                                        set: { preset.wrappedValue.videoBitrateKbps = $0 }
                                    ),
                                    in: 500...50_000,
                                    step: 500
                                )
                                Spacer()
                                Button("Clear") {
                                    preset.wrappedValue.videoBitrateKbps = nil
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button("Set Video Bitrate") {
                                preset.wrappedValue.videoBitrateKbps = 4500
                            }
                            .controlSize(.small)
                        }

                        if preset.wrappedValue.crf != nil {
                            HStack {
                                Stepper(
                                    "CRF target: \(preset.wrappedValue.crf ?? 23)",
                                    value: Binding(
                                        get: { preset.wrappedValue.crf ?? 23 },
                                        set: { preset.wrappedValue.crf = $0 }
                                    ),
                                    in: 0...51
                                )
                                Spacer()
                                Button("Clear") {
                                    preset.wrappedValue.crf = nil
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button("Set CRF Target") {
                                preset.wrappedValue.crf = 23
                            }
                            .controlSize(.small)
                        }
                    }
                }

                if preset.wrappedValue.category == .audio || preset.wrappedValue.category == .video {
                    Section("Audio") {
                        Picker("Audio codec", selection: preset.audioCodec) {
                            ForEach(AudioCodecType.allCases, id: \.self) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }

                        if preset.wrappedValue.audioBitrateKbps != nil {
                            HStack {
                                Stepper(
                                    "Audio bitrate: \(preset.wrappedValue.audioBitrateKbps ?? 256) kbps",
                                    value: Binding(
                                        get: { preset.wrappedValue.audioBitrateKbps ?? 256 },
                                        set: { preset.wrappedValue.audioBitrateKbps = $0 }
                                    ),
                                    in: 32...512,
                                    step: 32
                                )
                                Spacer()
                                Button("Clear") {
                                    preset.wrappedValue.audioBitrateKbps = nil
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button("Set Audio Bitrate") {
                                preset.wrappedValue.audioBitrateKbps = 256
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Section("Output") {
                    Picker("Save converted files to", selection: outputPolicySelection(for: preset)) {
                        Text("Same folder as source").tag(OutputChoice.sameAsSource)
                        Text("Downloads folder").tag(OutputChoice.downloads)
                        Text("Named subfolder").tag(OutputChoice.subfolder)
                        Text("Chosen folder...").tag(OutputChoice.custom)
                    }

                    if case .sourceSubfolder = preset.wrappedValue.outputDirectoryPolicy {
                        TextField("Subfolder name", text: $subfolderName, prompt: Text("Converted"))
                            .font(.system(.body, design: .monospaced))
                            .help("Use one folder name without slashes.")
                            .onChange(of: subfolderName) { _, newName in
                                preset.wrappedValue.outputDirectoryPolicy = .sourceSubfolder(subfolderName: newName)
                            }
                    }

                    if case .customFolder(_, let displayPath) = preset.wrappedValue.outputDirectoryPolicy {
                        LabeledContent("Folder") {
                            Text(displayPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }

                        HStack {
                            Button("Choose Another Folder...") {
                                chooseCustomFolder(for: preset)
                            }
                            .controlSize(.small)

                            Button("Use Source Folder") {
                                preset.wrappedValue.outputDirectoryPolicy = .sameAsSource
                            }
                            .controlSize(.small)
                        }
                    }

                    TextField("Filename pattern", text: preset.filenamePattern, prompt: Text("{name}"))
                        .font(.system(.body, design: .monospaced))
                        .help("Tokens: {name}, {preset}, {date}, {time}, and {ext}.")

                    LabeledContent("Example") {
                        Text(filenamePreview(for: preset.wrappedValue))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Picker("If the file already exists", selection: preset.overwritePolicy) {
                        ForEach(OverwritePolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }

                Section("Metadata") {
                    Toggle("Preserve metadata and tags", isOn: preset.preserveMetadata)
                    Toggle("Preserve creation date", isOn: preset.preserveCreationDate)
                }

                if !errors.isEmpty {
                    Section("Needs Attention") {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if preset.wrappedValue.isBuiltIn {
                    Section {
                        Text("Changes to this built-in preset are retained. Reset All Presets restores the factory version.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            HStack(spacing: 8) {
                Button("Delete...", role: .destructive) {
                    showingDeleteConfirmation = true
                }

                Button("Revert") {
                    load()
                }
                .disabled(!hasChanges)

                Spacer()

                if savedIndicatorVisible {
                    Label("Saved", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button("Save Preset") {
                    save(preset.wrappedValue)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || !errors.isEmpty)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private var hasChanges: Bool {
        guard let draft,
              let stored = PresetStore.shared.preset(forID: presetID) else {
            return false
        }
        return draft != stored
    }

    private func load() {
        guard let stored = PresetStore.shared.preset(forID: presetID) else {
            draft = nil
            return
        }

        draft = stored
        sourceScope = inferredSourceScope(for: stored)

        if case .sourceSubfolder(let name) = stored.outputDirectoryPolicy {
            subfolderName = name
        } else {
            subfolderName = "Converted"
        }

        savedIndicatorVisible = false
    }

    private func save(_ preset: ConversionPreset) {
        PresetStore.shared.updatePreset(preset)
        onSaved()
        draft = PresetStore.shared.preset(forID: presetID) ?? preset

        withAnimation(.easeInOut(duration: 0.15)) {
            savedIndicatorVisible = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.25))
            withAnimation(.easeInOut(duration: 0.15)) {
                savedIndicatorVisible = false
            }
        }
    }

    private func inferredSourceScope(for preset: ConversionPreset) -> SourceScope {
        let formats = Set(preset.sourceFormats.map { $0.lowercased() })
        if formats == ["*"] { return .any }
        if formats == ["audio", "video"] { return .audioVideo }
        return .category
    }

    private func applySourceScope(_ scope: SourceScope, to preset: Binding<ConversionPreset>) {
        switch scope {
        case .category:
            preset.wrappedValue.sourceFormats = [preset.wrappedValue.category.rawValue.lowercased()]
        case .audioVideo:
            preset.wrappedValue.sourceFormats = ["audio", "video"]
        case .any:
            preset.wrappedValue.sourceFormats = ["*"]
        }
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
            set: { newChoice in
                switch newChoice {
                case .sameAsSource:
                    preset.wrappedValue.outputDirectoryPolicy = .sameAsSource
                case .downloads:
                    preset.wrappedValue.outputDirectoryPolicy = .downloads
                case .subfolder:
                    let cleaned = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.isEmpty {
                        subfolderName = "Converted"
                    }
                    preset.wrappedValue.outputDirectoryPolicy = .sourceSubfolder(subfolderName: subfolderName)
                case .custom:
                    chooseCustomFolder(for: preset)
                }
            }
        )
    }

    private func resolvedFormat(for preset: ConversionPreset) -> FormatDefinition? {
        let key = preset.destinationFormat
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !key.isEmpty else { return nil }
        return FormatRegistry.shared.format(forID: key)
            ?? FormatRegistry.shared.format(forExtension: key)
    }

    private func validationErrors(for preset: ConversionPreset) -> [String] {
        var errors: [String] = []

        if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Enter a full preset name.")
        }

        if preset.menuName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Enter a short Finder menu title.")
        }

        let extensionName = preset.destinationFormat
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if extensionName.isEmpty {
            errors.append("Choose an output extension such as mp3 or mkv.")
        } else if let format = FormatRegistry.shared.format(forID: extensionName)
                    ?? FormatRegistry.shared.format(forExtension: extensionName) {
            if !format.supportedOutput {
                errors.append(".\(extensionName) is input-only. Choose a writable format.")
            }
        } else {
            errors.append("Unknown output format .\(extensionName).")
        }

        if preset.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Filename pattern cannot be empty. Use {name} for the source filename.")
        }

        if case .sourceSubfolder(let name) = preset.outputDirectoryPolicy {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned.contains("/") || cleaned.contains("\\") {
                errors.append("Subfolder must be a single folder name without slashes.")
            }
        }

        if preset.sourceFormats.isEmpty {
            errors.append("Choose which source files can show this preset.")
        }

        return errors
    }

    private func filenamePreview(for preset: ConversionPreset) -> String {
        let sourceURL = URL(fileURLWithPath: "/tmp/Example Clip.mov")
        var previewPreset = preset

        if previewPreset.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previewPreset.filenamePattern = "{name}"
        }

        let targetExtension = previewPreset.destinationFormat.isEmpty
            ? "mp4"
            : previewPreset.destinationFormat

        return OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: previewPreset,
            targetExtension: targetExtension
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
                let bookmarkData = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                Task { @MainActor in
                    preset.wrappedValue.outputDirectoryPolicy = .customFolder(
                        bookmarkData: bookmarkData,
                        displayPath: url.path
                    )
                }
            } catch {
                NSSound.beep()
            }
        }
    }
}
