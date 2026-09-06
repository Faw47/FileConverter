import AppKit
import FileConverterCore
import SwiftUI

public struct PresetEditorView: View {
    private let presetID: UUID
    private let onSaved: () -> Void
    private let onDeleted: () -> Void
    private let onDirtyChange: (Bool) -> Void

    @State private var draft: ConversionPreset?
    @State private var sourceScope: SourceScope = .category
    @State private var subfolderName = "Converted"
    @State private var usesCustomAudioSplit = false
    @State private var usesCustomAudioSize = false
    @State private var showingDeleteConfirmation = false
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""
    @State private var savedIndicatorVisible = false
    @State private var savedIndicatorTask: Task<Void, Never>?
    @State private var sourceSelection = "category:image"
    @State private var advancedOptionsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SourceScope: String, CaseIterable, Hashable {
        case category = "This category"
        case audioVideo = "Audio and video"
        case any = "Any file"
        case specific = "Specific format(s)"

        var helpText: String {
            switch self {
            case .category: return "Show this preset only for files in its selected category."
            case .audioVideo: return "Show this preset for both audio and video files."
            case .any: return "Show this preset for every file type."
            case .specific: return "Show this preset only for the format(s) chosen in Convert from."
            }
        }
    }

    private enum OutputChoice: Hashable {
        case sameAsSource
        case downloads
        case subfolder
        case custom
    }

    private struct SourceChoice: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let sourceFormats: [String]
    }

    private enum AudioSplitChoice: Int, CaseIterable, Hashable {
        case off = 0
        case seconds30 = 30
        case minute1 = 60
        case minutes5 = 300
        case minutes10 = 600
        case custom = -1

        var title: String {
            switch self {
            case .off: return "Don’t split"
            case .seconds30: return "Every 30 seconds"
            case .minute1: return "Every minute"
            case .minutes5: return "Every 5 minutes"
            case .minutes10: return "Every 10 minutes"
            case .custom: return "Custom length"
            }
        }
    }

    private enum AudioSizeChoice: Int, CaseIterable, Hashable {
        case off = 0
        case megabyte1 = 1_000_000
        case megabytes5 = 5_000_000
        case megabytes10 = 10_000_000
        case megabytes25 = 25_000_000
        case custom = -1

        var title: String {
            switch self {
            case .off: return "No size target"
            case .megabyte1: return "Up to 1 MB"
            case .megabytes5: return "Up to 5 MB"
            case .megabytes10: return "Up to 10 MB"
            case .megabytes25: return "Up to 25 MB"
            case .custom: return "Custom size"
            }
        }
    }

    public init(
        presetID: UUID,
        onSaved: @escaping () -> Void,
        onDeleted: @escaping () -> Void,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        self.presetID = presetID
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        self.onDirtyChange = onDirtyChange
    }

    public var body: some View {
        Group {
            if let draft {
                editor(for: Binding(
                    get: { self.draft ?? draft },
                    set: { newDraft in
                        self.draft = newDraft
                        self.onDirtyChange(newDraft != PresetStore.shared.preset(forID: presetID))
                    }
                ))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete this preset?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(draft?.isBuiltIn == true ? "Disable Preset" : "Delete Preset", role: .destructive) {
                PresetStore.shared.deletePreset(withID: presetID)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t Save Preset", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
    }

    private func editor(for preset: Binding<ConversionPreset>) -> some View {
        let errors = validationErrors(for: preset.wrappedValue)

        return VStack(spacing: 0) {
            // Pinned Inspector Header
            HStack(alignment: .center, spacing: 12) {
                SettingsIconBadge(
                    systemImage: preset.wrappedValue.category.systemImage,
                    color: categoryColor(preset.wrappedValue.category),
                    size: .tool
                )

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

                if preset.wrappedValue.isBuiltIn && !preset.wrappedValue.isEnabled {
                    Button("Restore") {
                        PresetStore.shared.restoreBuiltIn(withID: presetID)
                        load()
                        onSaved()
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Restore factory preset")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Scrollable Inspector Form
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    quickSetupSection(preset: preset)
                    identitySection(preset: preset)
                    outputSection(preset: preset)

                    DisclosureGroup(isExpanded: $advancedOptionsExpanded) {
                        VStack(alignment: .leading, spacing: 18) {
                            nameAndMatchingSection(preset: preset)
                            conversionEngineSection(preset: preset)

                            if preset.wrappedValue.category == .document,
                               (preset.wrappedValue.splitPDFIntoPages
                                   || PresetValidator.canSplitPDFPages(preset.wrappedValue)) {
                                documentToolsSection(preset: preset)
                            }

                            if preset.wrappedValue.category == .video {
                                videoSection(preset: preset)
                            }

                            if preset.wrappedValue.category == .audio || preset.wrappedValue.category == .video {
                                audioSection(preset: preset)
                            }

                            metadataSection(preset: preset)
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Advanced options")
                                    .font(.body.weight(.medium))
                                Text("Matching rules, engines, codecs, metadata, and special workflows")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 4)

                    if !errors.isEmpty {
                        needsAttentionSection(errors: errors)
                    }

                    if preset.wrappedValue.isBuiltIn {
                        builtInNoteSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Pinned Action Footer
            HStack(spacing: 8) {
                Button(preset.wrappedValue.isBuiltIn ? "Disable..." : "Delete...", role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .glassActionDestructive()
                .controlSize(.small)

                Button("Revert") {
                    load()
                }
                .glassAction()
                .controlSize(.small)
                .disabled(!hasChanges)

                Spacer()

                if savedIndicatorVisible {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                Button("Save Preset") {
                    save(preset.wrappedValue)
                }
                .glassActionProminent()
                .controlSize(.small)
                .disabled(!hasChanges || !errors.isEmpty)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private func quickSetupSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Quick setup", accessory: "Start here")

            SettingsCard {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Describe the conversion in two choices")
                                .font(.body.weight(.medium))
                            Text("Choose the kind of file you start with and the format you want back. The rest can stay automatic.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "Convert from",
                        subtitle: selectedSourceChoice?.subtitle ?? "Choose a source type"
                    ) {
                        Picker("Source file type", selection: sourceSelectionBinding(for: preset)) {
                            Section("Common file groups") {
                                ForEach(commonSourceChoices) { choice in
                                    Text(choice.title).tag(choice.id)
                                }
                            }

                            Section("Specific formats") {
                                ForEach(specificSourceChoices) { choice in
                                    Text(choice.title).tag(choice.id)
                                }
                            }

                            Text("Custom matching rule").tag("custom")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 260)
                        .accessibilityLabel("Source file type")
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "Convert to",
                        subtitle: destinationFormatDescription(for: preset.wrappedValue)
                    ) {
                        Picker("Output format", selection: destinationSelectionBinding(for: preset)) {
                            ForEach(destinationCategories) { category in
                                Section(category.displayName) {
                                    ForEach(destinationFormats.filter { $0.category == category }) { format in
                                        Text(destinationLabel(for: format)).tag(format.primaryExtension)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 260)
                        .accessibilityLabel("Output format")
                    }

                    Divider().padding(.leading, 14)

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(Color.accentColor)
                        Text("Finder action")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(selectedSourceChoice?.title ?? "Custom source") → \(destinationFormatDescription(for: preset.wrappedValue))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func identitySection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Name this preset")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "Preset name", subtitle: "A descriptive name for this recipe in File Converter") {
                        TextField("e.g. HEIC photos to JPEG", text: preset.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 250)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "Finder menu title", subtitle: "The short action label shown after right-clicking a file") {
                        TextField("e.g. HEIC → JPEG", text: preset.menuName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "Finder section",
                        subtitle: "Where this action is grouped in the context menu"
                    ) {
                        Picker("Finder section", selection: preset.category) {
                            ForEach(FormatCategory.allCases) { category in
                                Text(category.displayName).tag(category)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170)
                        .onChange(of: preset.wrappedValue.category) { _, newCategory in
                            guard sourceScope == .category else { return }
                            if newCategory == .custom {
                                sourceSelection = "custom"
                                return
                            }
                            sourceSelection = "category:\(newCategory.rawValue.lowercased())"
                            preset.wrappedValue.sourceFormats = [newCategory.rawValue.lowercased()]
                        }
                    }
                }
            }
        }
    }

    private func nameAndMatchingSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Advanced matching")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "Show for", subtitle: sourceScope.helpText) {
                        Picker("", selection: $sourceScope) {
                            ForEach(SourceScope.allCases, id: \.self) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                        .onChange(of: sourceScope) { _, newScope in
                            applySourceScope(newScope, to: preset)
                        }
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "Output extension", subtitle: "Target format extension without leading dot") {
                        TextField("mp3", text: preset.destinationFormat)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100)
                            .onChange(of: preset.wrappedValue.destinationFormat) { _, newValue in
                                let normalized = newValue
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                                    .lowercased()
                                if normalized != newValue {
                                    preset.wrappedValue.destinationFormat = normalized
                                }
                            }
                    }

                    if let format = resolvedFormat(for: preset.wrappedValue) {
                        Divider().padding(.leading, 14)

                        SettingsRow(title: "Detected format") {
                            Text("\(format.name), \(format.category.displayName)")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func conversionEngineSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Conversion Engine")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "Engine", subtitle: "Auto chooses the optimal backend unless specified") {
                        Picker("", selection: preset.backend) {
                            ForEach(BackendResolver.shared.registeredBackendTypes, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "Quality") {
                        Picker("", selection: preset.quality) {
                            ForEach(QualitySetting.allCases, id: \.self) { quality in
                                Text(quality.displayName).tag(quality)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "Hardware acceleration") {
                        Picker("", selection: preset.hardwareAcceleration) {
                            ForEach(HardwareAccelerationPolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    if !BackendResolver.shared.supportsAnySource(for: preset.wrappedValue) {
                        Divider().padding(.leading, 14)

                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                            Text("No installed backend can run this preset. Check External Tools for missing dependencies.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func documentToolsSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("PDF Tools")

            SettingsCard {
                SettingsRow(
                    title: "Split PDF into individual pages",
                    subtitle: "Creates one PDF per page and names each output clearly."
                ) {
                    Toggle("", isOn: Binding(
                        get: { preset.wrappedValue.splitPDFIntoPages },
                        set: { enabled in
                            preset.wrappedValue.splitPDFIntoPages = enabled
                            guard enabled else { return }
                            preset.wrappedValue.sourceFormats = ["pdf"]
                            preset.wrappedValue.destinationFormat = "pdf"
                            preset.wrappedValue.backend = .pdfKit
                            sourceScope = .category
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    private func videoSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Video")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "Video codec") {
                        Picker("", selection: preset.videoCodec) {
                            ForEach(VideoCodecType.allCases, id: \.self) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "Video bitrate",
                        subtitle: preset.wrappedValue.videoBitrateKbps != nil
                            ? "\(preset.wrappedValue.videoBitrateKbps ?? 4500) kbps"
                            : "Default rate"
                    ) {
                        if preset.wrappedValue.videoBitrateKbps != nil {
                            HStack(spacing: 8) {
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { preset.wrappedValue.videoBitrateKbps ?? 4500 },
                                        set: { preset.wrappedValue.videoBitrateKbps = $0 }
                                    ),
                                    in: 500...50_000,
                                    step: 500
                                )
                                .labelsHidden()

                                Button("Clear") {
                                    preset.wrappedValue.videoBitrateKbps = nil
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Button("Set Custom Bitrate") {
                                preset.wrappedValue.videoBitrateKbps = 4500
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "CRF target",
                        subtitle: preset.wrappedValue.crf != nil
                            ? "Value: \(preset.wrappedValue.crf ?? 23)"
                            : "Default constant rate factor"
                    ) {
                        if preset.wrappedValue.crf != nil {
                            HStack(spacing: 8) {
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { preset.wrappedValue.crf ?? 23 },
                                        set: { preset.wrappedValue.crf = $0 }
                                    ),
                                    in: 0...51
                                )
                                .labelsHidden()

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
            }
        }
    }

    private func audioSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Audio")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "Audio codec") {
                        Picker("", selection: preset.audioCodec) {
                            ForEach(AudioCodecType.allCases, id: \.self) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "Audio bitrate",
                        subtitle: preset.wrappedValue.audioBitrateKbps != nil
                            ? "\(preset.wrappedValue.audioBitrateKbps ?? 256) kbps"
                            : "Default rate"
                    ) {
                        if preset.wrappedValue.audioBitrateKbps != nil {
                            HStack(spacing: 8) {
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { preset.wrappedValue.audioBitrateKbps ?? 256 },
                                        set: { preset.wrappedValue.audioBitrateKbps = $0 }
                                    ),
                                    in: 32...512,
                                    step: 32
                                )
                                .labelsHidden()

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

                    if preset.wrappedValue.category == .audio {
                        Divider().padding(.leading, 14)

                        SettingsRow(
                            title: "Split into parts",
                            subtitle: "Creates separately named audio files at a friendly interval. Requires the FFmpeg toolset."
                        ) {
                            Picker("", selection: audioSplitChoice(for: preset)) {
                                ForEach(AudioSplitChoice.allCases, id: \.self) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }

                        if audioSplitChoice(for: preset).wrappedValue == .custom {
                            Divider().padding(.leading, 14)
                            SettingsRow(
                                title: "Part length",
                                subtitle: formattedDuration(preset.wrappedValue.audioSplitDurationSeconds ?? 300)
                            ) {
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { preset.wrappedValue.audioSplitDurationSeconds ?? 300 },
                                        set: { preset.wrappedValue.audioSplitDurationSeconds = $0 }
                                    ),
                                    in: 10...86_400,
                                    step: 10
                                )
                                .labelsHidden()
                            }
                        }

                        Divider().padding(.leading, 14)

                        SettingsRow(
                            title: "Fit within a file size",
                            subtitle: "Chooses an audio bitrate automatically to fit one shared file. Requires the FFmpeg toolset."
                        ) {
                            Picker("", selection: audioSizeChoice(for: preset)) {
                                ForEach(AudioSizeChoice.allCases, id: \.self) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }

                        if audioSizeChoice(for: preset).wrappedValue == .custom {
                            Divider().padding(.leading, 14)
                            SettingsRow(
                                title: "Target size",
                                subtitle: ByteCountFormatter.string(
                                    fromByteCount: Int64(preset.wrappedValue.audioTargetFileSizeBytes ?? 5_000_000),
                                    countStyle: .file
                                )
                            ) {
                                Stepper(
                                    "",
                                    value: Binding(
                                        get: { max(1, (preset.wrappedValue.audioTargetFileSizeBytes ?? 5_000_000) / 1_000_000) },
                                        set: { preset.wrappedValue.audioTargetFileSizeBytes = $0 * 1_000_000 }
                                    ),
                                    in: 1...500,
                                    step: 1
                                )
                                .labelsHidden()
                            }
                        }
                    }
                }
            }
        }
    }

    private func outputSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Output Location & Naming")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(title: "Save converted files to") {
                        Picker("", selection: outputPolicySelection(for: preset)) {
                            Text("Same folder as source").tag(OutputChoice.sameAsSource)
                            Text("Downloads folder").tag(OutputChoice.downloads)
                            Text("Named subfolder").tag(OutputChoice.subfolder)
                            Text("Chosen folder...").tag(OutputChoice.custom)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    if case .sourceSubfolder = preset.wrappedValue.outputDirectoryPolicy {
                        Divider().padding(.leading, 14)

                        SettingsRow(title: "Subfolder name", subtitle: "Single directory name without slashes") {
                            TextField("Converted", text: $subfolderName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 160)
                                .onChange(of: subfolderName) { _, newName in
                                    preset.wrappedValue.outputDirectoryPolicy = .sourceSubfolder(subfolderName: newName)
                                }
                        }
                    }

                    if case .customFolder(_, let displayPath) = preset.wrappedValue.outputDirectoryPolicy {
                        Divider().padding(.leading, 14)

                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(displayPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button("Choose Another Folder...") {
                                    chooseCustomFolder(for: preset)
                                }
                                .controlSize(.small)

                                Button("Use Source Folder") {
                                    preset.wrappedValue.outputDirectoryPolicy = .sameAsSource
                                }
                                .controlSize(.small)

                                Spacer()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "Filename pattern", subtitle: "Tokens: {name}, {preset}, {date}, {time}, {ext}") {
                        TextField("{name}", text: preset.filenamePattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 180)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "Live preview") {
                        Text(filenamePreview(for: preset.wrappedValue))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(title: "If the file already exists") {
                        Picker("", selection: preset.overwritePolicy) {
                            ForEach(OverwritePolicy.allCases, id: \.self) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }
                }
            }
        }
    }

    private func metadataSection(preset: Binding<ConversionPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Metadata & Timestamps")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Preserve metadata and tags",
                        subtitle: "Retains EXIF tags, ID3 audio tags, and creator metadata"
                    ) {
                        Toggle("", isOn: preset.preserveMetadata)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider().padding(.leading, 14)

                    SettingsRow(
                        title: "Preserve creation date",
                        subtitle: "Copies the source file's exact timestamps to converted files"
                    ) {
                        Toggle("", isOn: preset.preserveCreationDate)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private func needsAttentionSection(errors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Needs Attention")

            SettingsCard {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(errors, id: \.self) { error in
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var builtInNoteSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Changes to this built-in preset are saved. Disable it to hide it from menus; Restore returns factory values.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func categoryColor(_ category: FormatCategory) -> Color {
        switch category {
        case .video: return .purple
        case .audio: return .orange
        case .image: return .blue
        case .document: return .green
        case .custom: return .pink
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
            onDirtyChange(false)
            return
        }

        draft = stored
        usesCustomAudioSplit = stored.audioSplitDurationSeconds.map { AudioSplitChoice(rawValue: $0) == nil } ?? false
        usesCustomAudioSize = stored.audioTargetFileSizeBytes.map { AudioSizeChoice(rawValue: $0) == nil } ?? false
        onDirtyChange(false)
        sourceScope = inferredSourceScope(for: stored)
        sourceSelection = inferredSourceSelection(for: stored)

        if case .sourceSubfolder(let name) = stored.outputDirectoryPolicy {
            subfolderName = name
        } else {
            subfolderName = "Converted"
        }

        savedIndicatorVisible = false
    }

    private var commonSourceChoices: [SourceChoice] {
        [
            SourceChoice(
                id: "category:image",
                title: "Any image",
                subtitle: "PNG, JPEG, HEIC, WebP, TIFF, and more",
                sourceFormats: ["image"]
            ),
            SourceChoice(
                id: "category:video",
                title: "Any video",
                subtitle: "MP4, MOV, MKV, WebM, and more",
                sourceFormats: ["video"]
            ),
            SourceChoice(
                id: "category:audio",
                title: "Any audio",
                subtitle: "MP3, WAV, M4A, FLAC, and more",
                sourceFormats: ["audio"]
            ),
            SourceChoice(
                id: "category:document",
                title: "Any document",
                subtitle: "PDF, Word, Excel, text, and more",
                sourceFormats: ["document"]
            ),
            SourceChoice(
                id: "audio-video",
                title: "Audio or video",
                subtitle: "Useful for extracting or re-encoding sound",
                sourceFormats: ["audio", "video"]
            ),
            SourceChoice(
                id: "any",
                title: "Any supported file",
                subtitle: "Use this only when the output works for every source",
                sourceFormats: ["*"]
            )
        ]
    }

    private var specificSourceChoices: [SourceChoice] {
        FormatRegistry.shared.allFormats()
            .filter(\.supportedInput)
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { format in
                SourceChoice(
                    id: "format:\(format.id)",
                    title: "\(format.name) (.\(format.primaryExtension))",
                    subtitle: "Only .\(format.primaryExtension) / \(format.name) files",
                    sourceFormats: [format.id]
                )
            }
    }

    private var selectedSourceChoice: SourceChoice? {
        if let common = commonSourceChoices.first(where: { $0.id == sourceSelection }) {
            return common
        }
        return specificSourceChoices.first(where: { $0.id == sourceSelection })
    }

    private var destinationFormats: [FormatDefinition] {
        FormatRegistry.shared.allFormats()
            .filter(\.supportedOutput)
            .sorted { lhs, rhs in
                if lhs.category != rhs.category {
                    return lhs.category < rhs.category
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var destinationCategories: [FormatCategory] {
        FormatCategory.allCases.filter { category in
            destinationFormats.contains { $0.category == category }
        }
    }

    private func sourceSelectionBinding(for preset: Binding<ConversionPreset>) -> Binding<String> {
        Binding(
            get: { sourceSelection },
            set: { newValue in
                sourceSelection = newValue
                guard let choice = commonSourceChoices.first(where: { $0.id == newValue })
                    ?? specificSourceChoices.first(where: { $0.id == newValue }) else {
                    return
                }
                preset.wrappedValue.sourceFormats = choice.sourceFormats
                switch newValue {
                case "audio-video":
                    sourceScope = .audioVideo
                case "any":
                    sourceScope = .any
                case "custom":
                    sourceScope = .specific
                case let value where value.hasPrefix("category:"):
                    sourceScope = .category
                default:
                    sourceScope = .specific
                }
            }
        )
    }

    private func destinationSelectionBinding(for preset: Binding<ConversionPreset>) -> Binding<String> {
        Binding(
            get: {
                resolvedFormat(for: preset.wrappedValue)?.primaryExtension
                    ?? preset.wrappedValue.destinationFormat
            },
            set: { newValue in
                preset.wrappedValue.destinationFormat = newValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
            }
        )
    }

    private func destinationLabel(for format: FormatDefinition) -> String {
        "\(format.name) (.\(format.primaryExtension))"
    }

    private func destinationFormatDescription(for preset: ConversionPreset) -> String {
        guard let format = resolvedFormat(for: preset) else {
            let extensionName = preset.destinationFormat.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return extensionName.isEmpty ? "Choose an output format" : "Unknown (.\(extensionName))"
        }
        return "\(format.name) (.\(format.primaryExtension))"
    }

    private func inferredSourceSelection(for preset: ConversionPreset) -> String {
        let formats = Set(preset.sourceFormats.map { $0.lowercased() })
        if formats == ["*"] { return "any" }
        if formats == ["audio", "video"] { return "audio-video" }
        if formats.count == 1, let value = formats.first {
            if commonSourceChoices.contains(where: { $0.id == "category:\(value)" }) {
                return "category:\(value)"
            }
            if specificSourceChoices.contains(where: { $0.id == "format:\(value)" }) {
                return "format:\(value)"
            }
        }
        return "custom"
    }

    private func save(_ preset: ConversionPreset) {
        PresetStore.shared.updatePreset(preset)
        guard PresetStore.shared.lastSaveSucceeded else {
            savedIndicatorVisible = false
            saveErrorMessage = PresetStore.shared.lastErrorDescription ?? "The preset could not be saved."
            showingSaveError = true
            return
        }
        onSaved()
        draft = PresetStore.shared.preset(forID: presetID) ?? preset
        onDirtyChange(false)

        if reduceMotion { savedIndicatorVisible = true }
        else { withAnimation(.easeOut(duration: 0.15)) { savedIndicatorVisible = true } }

        savedIndicatorTask?.cancel()
        savedIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.25))
            guard !Task.isCancelled else { return }
            if reduceMotion { savedIndicatorVisible = false }
            else { withAnimation(.easeOut(duration: 0.15)) { savedIndicatorVisible = false } }
        }
    }

    private func inferredSourceScope(for preset: ConversionPreset) -> SourceScope {
        let formats = Set(preset.sourceFormats.map { $0.lowercased() })
        if formats == ["*"] { return .any }
        if formats == ["audio", "video"] { return .audioVideo }
        if formats.count == 1, let value = formats.first,
           FormatCategory(rawValue: value) != nil {
            return .category
        }
        return .specific
    }

    private func applySourceScope(_ scope: SourceScope, to preset: Binding<ConversionPreset>) {
        switch scope {
        case .category:
            preset.wrappedValue.sourceFormats = [preset.wrappedValue.category.rawValue.lowercased()]
        case .audioVideo:
            preset.wrappedValue.sourceFormats = ["audio", "video"]
        case .any:
            preset.wrappedValue.sourceFormats = ["*"]
        case .specific:
            // The friendly source picker owns the exact format list. The
            // advanced scope control should not erase it.
            return
        }

        if scope == .category {
            sourceSelection = preset.wrappedValue.category == .custom
                ? "custom"
                : "category:\(preset.wrappedValue.category.rawValue.lowercased())"
        }
    }

    private func audioSplitChoice(for preset: Binding<ConversionPreset>) -> Binding<AudioSplitChoice> {
        Binding(
            get: {
                guard let seconds = preset.wrappedValue.audioSplitDurationSeconds else { return .off }
                if usesCustomAudioSplit { return .custom }
                return AudioSplitChoice(rawValue: seconds) ?? .custom
            },
            set: { choice in
                usesCustomAudioSplit = choice == .custom
                if choice != .off { preset.wrappedValue.backend = .ffmpeg }
                switch choice {
                case .off:
                    preset.wrappedValue.audioSplitDurationSeconds = nil
                case .custom:
                    preset.wrappedValue.audioSplitDurationSeconds = preset.wrappedValue.audioSplitDurationSeconds ?? 5 * 60
                    preset.wrappedValue.audioTargetFileSizeBytes = nil
                    preset.wrappedValue.sourceFormats = ["audio"]
                    sourceScope = .category
                default:
                    preset.wrappedValue.audioSplitDurationSeconds = choice.rawValue
                    preset.wrappedValue.audioTargetFileSizeBytes = nil
                    preset.wrappedValue.sourceFormats = ["audio"]
                    sourceScope = .category
                }
            }
        )
    }

    private func audioSizeChoice(for preset: Binding<ConversionPreset>) -> Binding<AudioSizeChoice> {
        Binding(
            get: {
                guard let bytes = preset.wrappedValue.audioTargetFileSizeBytes else { return .off }
                if usesCustomAudioSize { return .custom }
                return AudioSizeChoice(rawValue: bytes) ?? .custom
            },
            set: { choice in
                usesCustomAudioSize = choice == .custom
                switch choice {
                case .off:
                    preset.wrappedValue.audioTargetFileSizeBytes = nil
                case .custom:
                    preset.wrappedValue.audioTargetFileSizeBytes = preset.wrappedValue.audioTargetFileSizeBytes ?? 5_000_000
                    configurePresetForAudioSize(preset)
                default:
                    preset.wrappedValue.audioTargetFileSizeBytes = choice.rawValue
                    configurePresetForAudioSize(preset)
                }
            }
        )
    }

    private func configurePresetForAudioSize(_ preset: Binding<ConversionPreset>) {
        preset.wrappedValue.backend = .ffmpeg
        preset.wrappedValue.audioSplitDurationSeconds = nil
        preset.wrappedValue.sourceFormats = ["audio"]
        sourceScope = .category
        if !["m4a", "mp3", "opus", "ogg"].contains(preset.wrappedValue.destinationFormat.lowercased()) {
            preset.wrappedValue.destinationFormat = "m4a"
        }
        // Let the selected output container choose its compatible encoder.
        preset.wrappedValue.audioCodec = .auto
    }

    private func formattedDuration(_ seconds: Int) -> String {
        if seconds % 3_600 == 0 { return "\(seconds / 3_600) hr" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) sec"
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
        PresetValidator.validationErrors(for: preset)
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
