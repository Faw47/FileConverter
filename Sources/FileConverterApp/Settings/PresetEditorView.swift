import AppKit
import FileConverterCore
import SwiftUI

public struct PresetEditorView: View {
    private let presetID: UUID
    private let onSaved: () -> Void
    private let onDeleted: () -> Void
    private let onDirtyChange: (Bool) -> Void
    @EnvironmentObject private var appState: AppState

    @State private var draft: ConversionPreset?
    @State private var baselinePreset: ConversionPreset?
    @State private var sourceScope: SourceScope = .category
    @State private var subfolderName = "Converted"
    @State private var usesCustomAudioSplit = false
    @State private var usesCustomAudioSize = false
    @State private var showingDeleteConfirmation = false
    @State private var showingUnsavedDeleteConfirmation = false
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""
    @State private var savedIndicatorVisible = false
    @State private var savedIndicatorTask: Task<Void, Never>?
    @State private var sourceSelection = "category:image"
    @State private var partLengthText = "00:05:00.00"
    @State private var partLengthValidationError: String?
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
        case useGeneral
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
                        self.onDirtyChange(newDraft != self.baselinePreset)
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
        .onDisappear {
            savedIndicatorTask?.cancel()
            savedIndicatorTask = nil
        }
        .confirmationDialog(
            "Delete this preset?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(draft?.isBuiltIn == true ? "Disable Preset" : "Delete Preset", role: .destructive) {
                do {
                    try PresetStore.shared.deletePreset(withID: presetID)
                    onDeleted()
                } catch {
                    saveErrorMessage = error.localizedDescription
                    showingSaveError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t Save Preset", isPresented: $showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
        .confirmationDialog(
            "Discard unsaved changes and delete this preset?",
            isPresented: $showingUnsavedDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard and Delete", role: .destructive) {
                load()
                showingDeleteConfirmation = true
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your unsaved changes will be discarded before the preset is deleted.")
        }
    }

    private func editor(for preset: Binding<ConversionPreset>) -> some View {
        let errors = validationErrors(for: preset.wrappedValue)

        return VStack(spacing: 0) {
            // Pinned Inspector Header
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: preset.wrappedValue.category.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.wrappedValue.name.isEmpty ? "Untitled Preset" : preset.wrappedValue.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(preset.wrappedValue.isBuiltIn ? "Built-in preset · your changes are kept" : "Your preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Show in menus", isOn: preset.isEnabled)
                    .toggleStyle(.switch)
                    .help("Show this preset in the Finder menu and the preset picker")
                    .accessibilityLabel("Show in menus")

                if preset.wrappedValue.isBuiltIn && (hasFactoryChanges || !preset.wrappedValue.isEnabled) {
                    Button("Restore Factory Settings") {
                        do {
                            try PresetStore.shared.restoreBuiltIn(withID: presetID)
                            load()
                            onSaved()
                        } catch {
                            saveErrorMessage = error.localizedDescription
                            showingSaveError = true
                        }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Restore factory preset")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Form {
                if !errors.isEmpty {
                    needsAttentionSection(errors: errors)
                }

                quickSetupSection(preset: preset)

                if preset.wrappedValue.category == .document,
                   (preset.wrappedValue.splitPDFIntoPages
                       || PresetValidator.canSplitPDFPages(preset.wrappedValue)) {
                    documentToolsSection(preset: preset)
                }
                if preset.wrappedValue.category == .video {
                    videoSection(preset: preset)
                }
                if preset.wrappedValue.category == .image {
                    imageSection(preset: preset)
                }
                if preset.wrappedValue.category == .audio || preset.wrappedValue.category == .video {
                    audioSection(preset: preset)
                }

                outputSection(preset: preset)
                metadataSection(preset: preset)
                identitySection(preset: preset)
                nameAndMatchingSection(preset: preset)
                conversionEngineSection(preset: preset)
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Pinned Action Footer
            HStack(spacing: 8) {
                if !preset.wrappedValue.isBuiltIn {
                    Button("Delete…", role: .destructive) {
                        if hasChanges {
                            showingUnsavedDeleteConfirmation = true
                        } else {
                            showingDeleteConfirmation = true
                        }
                    }
                }

                Button("Revert") {
                    load()
                }
                .disabled(!hasChanges)

                Button("Export…") {
                    exportSinglePreset(preset.wrappedValue)
                }

                Spacer()

                if hasChanges {
                    Text("Changes are saved when you click Save")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                Button("Save") {
                    save(preset.wrappedValue)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || !errors.isEmpty)
                .keyboardShortcut("s", modifiers: .command)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sections

    private func quickSetupSection(preset: Binding<ConversionPreset>) -> some View {
        Section("Conversion") {
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
                .fixedSize()
                .accessibilityLabel("Source file type")
            }

            SettingsRow(
                title: "Convert to",
                subtitle: resolvedFormat(for: preset.wrappedValue) == nil ? destinationFormatDescription(for: preset.wrappedValue) : nil
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
                .fixedSize()
                .accessibilityLabel("Output format")
            }

                            SettingsRow(
                title: stateController.qualitySectionTitle(for: preset.wrappedValue),
                subtitle: stateController.qualitySectionSubtitle(for: preset.wrappedValue)
            ) {
                Picker("", selection: preset.quality) {
                    ForEach(stateController.availableQualities(for: preset.wrappedValue), id: \.self) { quality in
                        Text(stateController.qualityDisplayName(quality, for: preset.wrappedValue)).tag(quality)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!stateController.isQualityEnabled(for: preset.wrappedValue))
            }
        }
    }

    private func identitySection(preset: Binding<ConversionPreset>) -> some View {
        Section("Name") {
            SettingsRow(title: "Preset name", subtitle: "Shown in Settings and the preset picker") {
                TextField("e.g. HEIC photos to JPEG", text: preset.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
            }

            SettingsRow(title: "Finder menu name", subtitle: "Shown when you right-click a file") {
                TextField("e.g. HEIC → JPEG", text: preset.menuName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
            }

            SettingsRow(
                title: "Finder menu group"
            ) {
                Picker("Finder section", selection: preset.category) {
                    ForEach(FormatCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
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

    private func nameAndMatchingSection(preset: Binding<ConversionPreset>) -> some View {
        Section("Matching") {
            SettingsRow(title: "Show for", subtitle: sourceScope.helpText) {
                Picker("", selection: $sourceScope) {
                    ForEach(SourceScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: sourceScope) { _, newScope in
                    applySourceScope(newScope, to: preset)
                }
            }

            SettingsRow(title: "File extension") {
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
                SettingsRow(title: "Detected format") {
                    Text("\(format.name), \(format.category.displayName)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func conversionEngineSection(preset: Binding<ConversionPreset>) -> some View {
        Section("Engine") {
            SettingsRow(title: "Converter", subtitle: "Automatic picks the best one installed") {
                Picker("", selection: preset.backend) {
                    ForEach(BackendResolver.shared.registeredBackendTypes, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            SettingsRow(
                title: "Hardware acceleration",
                subtitle: (preset.wrappedValue.audioCodec == .copy || preset.wrappedValue.category == .audio)
                    ? "Not applicable for this preset"
                    : nil
            ) {
                Picker("", selection: preset.hardwareAcceleration) {
                    ForEach(HardwareAccelerationPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(preset.wrappedValue.audioCodec == .copy || preset.wrappedValue.category == .audio)
            }

            if !BackendResolver.shared.supportsAnySource(for: preset.wrappedValue) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text("No installed backend can run this preset. Check External Tools for missing dependencies.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open External Tools…") {
                        appState.openSettings(tab: .externalTools)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func documentToolsSection(preset: Binding<ConversionPreset>) -> some View {
        Section("PDF") {
            SettingsRow(
                title: "Split PDF into individual pages",
                subtitle: "One PDF per page"
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

    private func videoSection(preset: Binding<ConversionPreset>) -> some View {
        Section("Video") {
            SettingsRow(title: "Video codec") {
                Picker("", selection: preset.videoCodec) {
                    ForEach(VideoCodecType.allCases, id: \.self) { codec in
                        Text(codec.displayName).tag(codec)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            SettingsRow(
                title: "Video bitrate",
                subtitle: withIgnoredNote(
                    preset.wrappedValue.videoBitrateKbps != nil
                        ? "Higher numbers look better and make bigger files"
                        : "Automatic, based on picture size and quality",
                    key: .videoBitrate,
                    preset: preset.wrappedValue
                )
            ) {
                if preset.wrappedValue.videoBitrateKbps != nil {
                    HStack(spacing: 6) {
                        numberField(
                            "Video bitrate in kilobits per second",
                            value: Binding(
                                get: { preset.wrappedValue.videoBitrateKbps ?? 4500 },
                                set: { preset.wrappedValue.videoBitrateKbps = $0 }
                            ),
                            in: 500...50_000,
                            step: 500,
                            unit: "kbps"
                        )

                        Button("Automatic") {
                            preset.wrappedValue.videoBitrateKbps = nil
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("Set Bitrate") {
                        preset.wrappedValue.videoBitrateKbps = 4500
                    }
                    .controlSize(.small)
                }
            }

            SettingsRow(
                title: "Constant quality (CRF)",
                subtitle: withIgnoredNote(
                    preset.wrappedValue.crf != nil
                        ? "Lower numbers look better and make bigger files"
                        : "Automatic, based on quality",
                    key: .crf,
                    preset: preset.wrappedValue
                )
            ) {
                if preset.wrappedValue.crf != nil {
                    HStack(spacing: 6) {
                        numberField(
                            "Constant quality value",
                            value: Binding(
                                get: { preset.wrappedValue.crf ?? 23 },
                                set: { preset.wrappedValue.crf = $0 }
                            ),
                            in: 0...51,
                            step: 1,
                            unit: nil
                        )

                        Button("Automatic") {
                            preset.wrappedValue.crf = nil
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("Set Value") {
                        preset.wrappedValue.crf = 23
                    }
                    .controlSize(.small)
                }
            }

            SettingsRow(title: "Picture size", subtitle: "Never larger than the original") {
                resolutionPicker(preset: preset, originalLabel: "Original size")
            }

            SettingsRow(title: "Frame rate") {
                Picker("Frame rate", selection: Binding<Double?>(
                    get: { preset.wrappedValue.framerate },
                    set: { preset.wrappedValue.framerate = $0 }
                )) {
                    Text("Same as original").tag(Double?.none)
                    Divider()
                    ForEach([15.0, 24, 25, 30, 50, 60], id: \.self) { rate in
                        Text("\(Int(rate)) fps").tag(Double?.some(rate))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private func imageSection(preset: Binding<ConversionPreset>) -> some View {
        Section("Image") {
            SettingsRow(title: "Maximum size", subtitle: "Longest side; images are never enlarged") {
                resolutionPicker(preset: preset, originalLabel: "Original size")
            }
            if preset.wrappedValue.sourceFormats.contains("pdf") {
                SettingsRow(title: "Page resolution", subtitle: "Dots per inch when rendering PDF pages") {
                    Picker("Page resolution", selection: Binding<Int?>(
                        get: { preset.wrappedValue.processingOptions?.pdfDPI },
                        set: { newValue in
                            var options = preset.wrappedValue.processingOptions ?? ConversionProcessingOptions()
                            options.pdfDPI = newValue
                            preset.wrappedValue.processingOptions = options.isEmpty ? nil : options
                        }
                    )) {
                        Text("Automatic").tag(Int?.none)
                        Divider()
                        ForEach([72, 150, 200, 300, 600], id: \.self) { dpi in
                            Text("\(dpi) dpi").tag(Int?.some(dpi))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    private enum ResolutionChoice: Hashable {
        case original, uhd4k, hd1080p, hd720p, sd480p, custom
    }

    @ViewBuilder
    private func resolutionPicker(preset: Binding<ConversionPreset>, originalLabel: String) -> some View {
        let isImage = preset.wrappedValue.category == .image
        HStack(spacing: 6) {
            Picker("Size", selection: Binding<ResolutionChoice>(
                get: {
                    switch preset.wrappedValue.resolution {
                    case .original: return .original
                    case .uhd4k: return .uhd4k
                    case .hd1080p: return .hd1080p
                    case .hd720p: return .hd720p
                    case .sd480p: return .sd480p
                    case .custom: return .custom
                    }
                },
                set: { choice in
                    switch choice {
                    case .original: preset.wrappedValue.resolution = .original
                    case .uhd4k: preset.wrappedValue.resolution = .uhd4k
                    case .hd1080p: preset.wrappedValue.resolution = .hd1080p
                    case .hd720p: preset.wrappedValue.resolution = .hd720p
                    case .sd480p: preset.wrappedValue.resolution = .sd480p
                    case .custom:
                        if case .custom = preset.wrappedValue.resolution { return }
                        preset.wrappedValue.resolution = isImage
                            ? .custom(width: 2048, height: 2048)
                            : .custom(width: 1280, height: 720)
                    }
                }
            )) {
                Text(originalLabel).tag(ResolutionChoice.original)
                Divider()
                Text(isImage ? "3840 px" : "4K (3840 × 2160)").tag(ResolutionChoice.uhd4k)
                Text(isImage ? "1920 px" : "1080p (1920 × 1080)").tag(ResolutionChoice.hd1080p)
                Text(isImage ? "1280 px" : "720p (1280 × 720)").tag(ResolutionChoice.hd720p)
                Text(isImage ? "854 px" : "480p (854 × 480)").tag(ResolutionChoice.sd480p)
                Text("Custom…").tag(ResolutionChoice.custom)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            if case .custom(let width, let height) = preset.wrappedValue.resolution {
                TextField("Width", value: Binding(
                    get: { width },
                    set: { preset.wrappedValue.resolution = .custom(width: max(16, $0), height: height) }
                ), format: .number)
                .frame(width: 60)
                .accessibilityLabel("Custom width")
                Text("×")
                TextField("Height", value: Binding(
                    get: { height },
                    set: { preset.wrappedValue.resolution = .custom(width: width, height: max(16, $0)) }
                ), format: .number)
                .frame(width: 60)
                .accessibilityLabel("Custom height")
            }
        }
    }

    /// Adds "Ignored when the original is MP4 or MOV…" when some sources would
    /// run on a backend that ignores this setting.
    /// A number field with a stepper, clamped to `range`.
    private func numberField(
        _ accessibilityLabel: String,
        value: Binding<Int>,
        in range: ClosedRange<Int>,
        step: Int,
        unit: String?
    ) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        return HStack(spacing: 4) {
            TextField(accessibilityLabel, value: clamped, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Stepper(accessibilityLabel, value: clamped, in: range, step: step)
                .labelsHidden()
            if let unit {
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func withIgnoredNote(_ text: String, key: PresetSettingKey, preset: ConversionPreset) -> String {
        let affected = BackendResolver.shared.ignoredSettings(for: preset).filter { $0.keys.contains(key) }
        guard !affected.isEmpty else { return text }
        let formats = Array(Set(affected.map { $0.format.primaryExtension.uppercased() })).sorted()
        var shown = Array(formats.prefix(3))
        if formats.count > 3 { shown.append("\(formats.count - 3) more") }
        let list = ListFormatter.localizedString(byJoining: shown)
        return "\(text). Ignored when the original is \(list), because a different converter handles those."
    }

    private func audioSection(preset: Binding<ConversionPreset>) -> some View {
        let isCopy = preset.wrappedValue.audioCodec == .copy
        let isNone = preset.wrappedValue.audioCodec == .none
        let isTranscodingDisabled = isCopy || isNone
        let isPCM = isPCMFormat(preset.wrappedValue)

        return Section("Audio") {
                    SettingsRow(title: "Audio codec") {
                        Picker("", selection: preset.audioCodec) {
                            ForEach(AudioCodecType.allCases, id: \.self) { codec in
                                Text(codec.displayName).tag(codec)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .onChange(of: preset.wrappedValue.audioCodec) { _, newCodec in
                            handleAudioCodecChange(to: newCodec, preset: preset)
                        }
                    }

                    if isPCM && !isTranscodingDisabled {
                        SettingsRow(title: "Bit depth") {
                            Picker("", selection: Binding(
                                get: { preset.wrappedValue.audioBitDepth ?? .bit16 },
                                set: { preset.wrappedValue.audioBitDepth = $0 }
                            )) {
                                ForEach(AudioBitDepth.allCases, id: \.self) { depth in
                                    Text(depth.displayName).tag(depth)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }

                    if shouldShowAudioBitrate(for: preset.wrappedValue) {
                        SettingsRow(
                            title: "Audio bitrate",
                            subtitle: preset.wrappedValue.audioBitrateKbps != nil
                                ? "Higher numbers sound better and make bigger files"
                                : "Automatic"
                        ) {
                            if preset.wrappedValue.audioBitrateKbps != nil {
                                HStack(spacing: 6) {
                                    numberField(
                                        "Audio bitrate in kilobits per second",
                                        value: Binding(
                                            get: { preset.wrappedValue.audioBitrateKbps ?? 256 },
                                            set: { preset.wrappedValue.audioBitrateKbps = $0 }
                                        ),
                                        in: 32...512,
                                        step: 32,
                                        unit: "kbps"
                                    )

                                    Button("Automatic") {
                                        preset.wrappedValue.audioBitrateKbps = nil
                                    }
                                    .controlSize(.small)
                                }
                            } else {
                                Button("Set Bitrate") {
                                    preset.wrappedValue.audioBitrateKbps = 256
                                }
                                .controlSize(.small)
                            }
                        }
                        .disabled(isTranscodingDisabled)
                    }

                    SettingsRow(
                        title: "Sample rate",
                        subtitle: isCopy ? "Copied unchanged from the original" : nil
                    ) {
                        Picker("", selection: preset.audioSampleRate) {
                            Text("Same as original").tag(nil as Int?)
                            Text("8 kHz").tag(8_000 as Int?)
                            Text("16 kHz").tag(16_000 as Int?)
                            Text("22.05 kHz").tag(22_050 as Int?)
                            Text("44.1 kHz").tag(44_100 as Int?)
                            Text("48 kHz").tag(48_000 as Int?)
                            Text("96 kHz").tag(96_000 as Int?)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(isTranscodingDisabled)
                    }

                    SettingsRow(
                        title: "Channels",
                        subtitle: isCopy ? "Copied unchanged from the original" : nil
                    ) {
                        Picker("", selection: preset.audioChannels) {
                            Text("Same as original").tag(nil as Int?)
                            Text("Mono").tag(1 as Int?)
                            Text("Stereo").tag(2 as Int?)
                            Text("5.1 surround").tag(6 as Int?)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .disabled(isTranscodingDisabled)
                    }

                    if preset.wrappedValue.category == .audio {
                        SettingsRow(
                            title: "Split into parts",
                            subtitle: "Starts a new file at a set length. Needs FFmpeg."
                        ) {
                            Picker("", selection: audioSplitChoice(for: preset)) {
                                ForEach(AudioSplitChoice.allCases, id: \.self) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        if audioSplitChoice(for: preset).wrappedValue == .custom {
                            SettingsRow(
                                title: "Part length",
                                subtitle: partLengthValidationError ?? "Format: HH:MM:SS.ss (e.g. 00:05:00.00)"
                            ) {
                                VStack(alignment: .trailing, spacing: 4) {
                                    TextField("00:05:00.00", text: $partLengthText)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 140)
                                        .onChange(of: partLengthText) { _, newText in
                                            handlePartLengthChange(newText, preset: preset)
                                        }

                                    if let error = partLengthValidationError {
                                        Text(error)
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }

                        if !isCopy && !isPCM {
                            SettingsRow(
                                title: "Fit within a file size",
                                subtitle: "Picks the bitrate so the file fits. Needs FFmpeg."
                            ) {
                                Picker("", selection: audioSizeChoice(for: preset)) {
                                    ForEach(AudioSizeChoice.allCases, id: \.self) { choice in
                                        Text(choice.title).tag(choice)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .fixedSize()
                            }

                            if audioSizeChoice(for: preset).wrappedValue == .custom {
                                SettingsRow(
                                    title: "Target size"
                                ) {
                                    numberField(
                                        "Target size in megabytes",
                                        value: Binding(
                                            get: { max(1, (preset.wrappedValue.audioTargetFileSizeBytes ?? 5_000_000) / 1_000_000) },
                                            set: { preset.wrappedValue.audioTargetFileSizeBytes = $0 * 1_000_000 }
                                        ),
                                        in: 1...500,
                                        step: 1,
                                        unit: "MB"
                                    )
                                }
                            }
                        }
                    }
                }
    }

    private func outputSection(preset: Binding<ConversionPreset>) -> some View {
        Section("Saving") {
            SettingsRow(title: "Save converted files to") {
                Picker("", selection: outputPolicySelection(for: preset)) {
                    Text("Use General setting (\(Self.describe(generalDefaults.outputDirectoryPolicy)))").tag(OutputChoice.useGeneral)
                    Divider()
                    Text("Same folder as the original").tag(OutputChoice.sameAsSource)
                    Text("Downloads").tag(OutputChoice.downloads)
                    Text("A subfolder next to the original").tag(OutputChoice.subfolder)
                    Text("A folder I choose…").tag(OutputChoice.custom)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if !preset.wrappedValue.resolvedInheritance.outputLocation,
               case .sourceSubfolder = preset.wrappedValue.outputDirectoryPolicy {
                SettingsRow(title: "Subfolder name") {
                    TextField("Converted", text: $subfolderName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 160)
                        .onChange(of: subfolderName) { _, newName in
                            preset.wrappedValue.outputDirectoryPolicy = .sourceSubfolder(subfolderName: newName)
                            onDirtyChange(true)
                        }
                }
            }

            if !preset.wrappedValue.resolvedInheritance.outputLocation,
               case .customFolder(_, let displayPath) = preset.wrappedValue.outputDirectoryPolicy {
                let isAuthorized = preset.wrappedValue.outputDirectoryPolicy.isCustomFolderAuthorized

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: isAuthorized ? "folder.fill" : "folder.badge.gearshape")
                            .foregroundStyle(isAuthorized ? Color.accentColor : Color.orange)
                        Text(displayPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(isAuthorized ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }

                    if !isAuthorized {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Folder access not authorized on this Mac. Please select or re-authorize the folder.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                    }

                    HStack(spacing: 8) {
                        Button(isAuthorized ? "Choose Another Folder…" : "Select / Re-authorize Folder…") {
                            chooseCustomFolder(for: preset)
                        }
                        .controlSize(.small)

                        Button("Use General Setting") {
                            var inheritance = preset.wrappedValue.resolvedInheritance
                            inheritance.outputLocation = true
                            preset.wrappedValue.inheritance = inheritance
                            onDirtyChange(true)
                        }
                        .controlSize(.small)

                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            SettingsRow(
                title: "Filename",
                subtitle: inheritanceBinding(\.filenamePattern, of: preset).wrappedValue
                    ? "Uses the General pattern \(generalDefaults.filenamePattern)"
                    : "Tokens: {name}, {preset}, {date}, {time}"
            ) {
                HStack(spacing: 8) {
                    Toggle("Use General pattern", isOn: inheritanceBinding(\.filenamePattern, of: preset))
                        .toggleStyle(.checkbox)
                    if !inheritanceBinding(\.filenamePattern, of: preset).wrappedValue {
                        TextField("{name}", text: preset.filenamePattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 160)
                    }
                }
            }

            SettingsRow(title: "Example") {
                Text(filenamePreview(for: preset.wrappedValue))
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            SettingsRow(title: "If the file already exists") {
                Picker("", selection: collisionSelection(for: preset)) {
                    Text("Use General setting (\(generalDefaults.overwritePolicy.displayName))").tag(OverwritePolicy?.none)
                    Divider()
                    ForEach(OverwritePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(OverwritePolicy?.some(policy))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    private func metadataSection(preset: Binding<ConversionPreset>) -> some View {
        Section("File Details") {
            SettingsRow(
                title: "Preserve metadata and tags",
                subtitle: "Camera details, song tags, and author"
            ) {
                Toggle("", isOn: preset.preserveMetadata)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            SettingsRow(title: "Keep original creation date") {
                inheritedBoolPicker(
                    \.creationDate,
                    general: generalDefaults.preserveCreationDate,
                    value: preset.preserveCreationDate,
                    of: preset
                )
            }

            SettingsRow(
                title: "Keep original modification date",
                subtitle: "Off: new files show today's date and sort first in Finder"
            ) {
                inheritedBoolPicker(
                    \.modificationDate,
                    general: generalDefaults.preserveModificationDate,
                    value: Binding(
                        get: { preset.wrappedValue.preserveModificationDate ?? false },
                        set: { preset.wrappedValue.preserveModificationDate = $0 }
                    ),
                    of: preset
                )
            }

            SettingsRow(
                title: "Remove location",
                subtitle: "Removes GPS coordinates from photos and videos"
            ) {
                inheritedBoolPicker(
                    \.locationData,
                    general: generalDefaults.removeLocationData,
                    value: Binding(
                        get: { preset.wrappedValue.removeLocationData ?? true },
                        set: { preset.wrappedValue.removeLocationData = $0 }
                    ),
                    of: preset
                )
            }
        }
    }

    private func needsAttentionSection(errors: [String]) -> some View {
        Section {
            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Fix Before Saving")
        }
    }

    private var hasChanges: Bool {
        guard let draft, let baselinePreset else {
            return false
        }
        return draft != baselinePreset
    }

    private var hasFactoryChanges: Bool {
        draft.map(BuiltInPresetUpgrades.isModifiedFromFactory) ?? false
    }

    private func load() {
        savedIndicatorTask?.cancel()
        savedIndicatorTask = nil

        guard let stored = PresetStore.shared.preset(forID: presetID) else {
            draft = nil
            baselinePreset = nil
            onDirtyChange(false)
            return
        }

        baselinePreset = stored
        draft = stored
        let splitSeconds = stored.audioSplitDurationSeconds ?? 300
        partLengthText = AudioDurationParser.format(seconds: splitSeconds)
        partLengthValidationError = nil
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
                    subtitle: "Only .\(format.primaryExtension) files",
                    sourceFormats: [format.id]
                )
            }
    }

    private var selectedSourceChoice: SourceChoice? {
        if let common = commonSourceChoices.first(where: { $0.id == sourceSelection }) {
            return common
        }
        if let specific = specificSourceChoices.first(where: { $0.id == sourceSelection }) {
            return specific
        }
        if sourceSelection == "custom" {
            return SourceChoice(
                id: "custom",
                title: "Custom matching rule",
                subtitle: "Set under Matching below",
                sourceFormats: []
            )
        }
        return nil
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
                if newValue == "custom" {
                    sourceScope = .specific
                    return
                }
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
                let clean = newValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased()
                preset.wrappedValue.destinationFormat = clean
                handleDestinationFormatChange(to: clean, preset: preset)
            }
        )
    }

    private func destinationLabel(for format: FormatDefinition) -> String {
        format.primaryExtension.uppercased()
    }

    private func destinationFormatDescription(for preset: ConversionPreset) -> String {
        guard let format = resolvedFormat(for: preset) else {
            let extensionName = preset.destinationFormat.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return extensionName.isEmpty ? "Choose an output format" : "Unknown (.\(extensionName))"
        }
        return format.primaryExtension.uppercased()
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
        do {
            try PresetStore.shared.updatePreset(preset)
        } catch {
            savedIndicatorVisible = false
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
            return
        }
        guard PresetStore.shared.lastSaveSucceeded else {
            savedIndicatorVisible = false
            saveErrorMessage = PresetStore.shared.lastErrorDescription ?? "The preset could not be saved."
            showingSaveError = true
            return
        }
        onSaved()
        draft = PresetStore.shared.preset(forID: presetID) ?? preset
        baselinePreset = draft
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
                    partLengthValidationError = nil
                case .custom:
                    let seconds = preset.wrappedValue.audioSplitDurationSeconds ?? 5 * 60
                    preset.wrappedValue.audioSplitDurationSeconds = seconds
                    preset.wrappedValue.audioTargetFileSizeBytes = nil
                    preset.wrappedValue.sourceFormats = ["audio"]
                    sourceScope = .category
                    partLengthText = AudioDurationParser.format(seconds: seconds)
                    partLengthValidationError = nil
                default:
                    preset.wrappedValue.audioSplitDurationSeconds = choice.rawValue
                    preset.wrappedValue.audioTargetFileSizeBytes = nil
                    preset.wrappedValue.sourceFormats = ["audio"]
                    sourceScope = .category
                    partLengthText = AudioDurationParser.format(seconds: choice.rawValue)
                    partLengthValidationError = nil
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

    /// General settings as conversions will read them right now.
    private var generalDefaults: ConversionDefaults {
        ConversionDefaults.current
    }

    static func describe(_ policy: OutputDirectoryPolicy) -> String {
        switch policy {
        case .sameAsSource: return "same folder as source"
        case .downloads: return "Downloads"
        case .sourceSubfolder(let name): return "subfolder “\(name)”"
        case .customFolder(_, let path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func inheritanceBinding(
        _ keyPath: WritableKeyPath<PresetInheritance, Bool>,
        of preset: Binding<ConversionPreset>
    ) -> Binding<Bool> {
        Binding(
            get: { preset.wrappedValue.resolvedInheritance[keyPath: keyPath] },
            set: { newValue in
                var inheritance = preset.wrappedValue.resolvedInheritance
                inheritance[keyPath: keyPath] = newValue
                preset.wrappedValue.inheritance = inheritance
            }
        )
    }

    private enum InheritedBoolChoice: Hashable {
        case general, on, off
    }

    @ViewBuilder
    private func inheritedBoolPicker(
        _ keyPath: WritableKeyPath<PresetInheritance, Bool>,
        general: Bool,
        value: Binding<Bool>,
        of preset: Binding<ConversionPreset>
    ) -> some View {
        let inherit = inheritanceBinding(keyPath, of: preset)
        Picker("", selection: Binding<InheritedBoolChoice>(
            get: { inherit.wrappedValue ? .general : (value.wrappedValue ? .on : .off) },
            set: { choice in
                switch choice {
                case .general:
                    inherit.wrappedValue = true
                case .on:
                    value.wrappedValue = true
                    inherit.wrappedValue = false
                case .off:
                    value.wrappedValue = false
                    inherit.wrappedValue = false
                }
            }
        )) {
            Text("Use General setting (\(general ? "On" : "Off"))").tag(InheritedBoolChoice.general)
            Divider()
            Text("On").tag(InheritedBoolChoice.on)
            Text("Off").tag(InheritedBoolChoice.off)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private func collisionSelection(for preset: Binding<ConversionPreset>) -> Binding<OverwritePolicy?> {
        let inherit = inheritanceBinding(\.collisionPolicy, of: preset)
        return Binding(
            get: { inherit.wrappedValue ? nil : preset.wrappedValue.overwritePolicy },
            set: { newValue in
                if let newValue {
                    preset.wrappedValue.overwritePolicy = newValue
                    inherit.wrappedValue = false
                } else {
                    inherit.wrappedValue = true
                }
            }
        )
    }

    private func outputPolicySelection(for preset: Binding<ConversionPreset>) -> Binding<OutputChoice> {
        let inherit = inheritanceBinding(\.outputLocation, of: preset)
        return Binding(
            get: {
                if inherit.wrappedValue { return .useGeneral }
                switch preset.wrappedValue.outputDirectoryPolicy {
                case .sameAsSource: return .sameAsSource
                case .downloads: return .downloads
                case .sourceSubfolder: return .subfolder
                case .customFolder: return .custom
                }
            },
            set: { newChoice in
                if newChoice == .useGeneral {
                    inherit.wrappedValue = true
                    return
                }
                if newChoice != .custom {
                    inherit.wrappedValue = false
                }
                switch newChoice {
                case .useGeneral:
                    break
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
        var errors = PresetValidator.validationErrors(for: preset)
        if audioSplitChoice(for: Binding.constant(preset)).wrappedValue == .custom,
           let error = partLengthValidationError {
            errors.append(error)
        }
        if case .customFolder(_, let displayPath) = preset.outputDirectoryPolicy,
           !preset.outputDirectoryPolicy.isCustomFolderAuthorized {
            errors.append("Custom output folder '\(displayPath)' requires authorization on this Mac. Please select or re-authorize it.")
        }
        return errors
    }

    private let stateController = PresetEditorStateController()

    private func availableQualities(for preset: ConversionPreset) -> [QualitySetting] {
        stateController.availableQualities(for: preset)
    }

    private func isPCMFormat(_ preset: ConversionPreset) -> Bool {
        stateController.isPCMFormat(preset)
    }

    private func shouldShowAudioBitrate(for preset: ConversionPreset) -> Bool {
        stateController.shouldShowAudioBitrate(for: preset)
    }

    private func handleAudioCodecChange(to newCodec: AudioCodecType, preset: Binding<ConversionPreset>) {
        stateController.setAudioCodec(newCodec, in: &preset.wrappedValue)
    }

    private func handleDestinationFormatChange(to newFormat: String, preset: Binding<ConversionPreset>) {
        stateController.setDestinationFormat(newFormat, in: &preset.wrappedValue)
    }

    private func handlePartLengthChange(_ newText: String, preset: Binding<ConversionPreset>) {
        let prev = preset.wrappedValue.audioSplitDurationSeconds
        partLengthValidationError = stateController.setPartLengthText(newText, in: &preset.wrappedValue)
        if partLengthValidationError == nil && preset.wrappedValue.audioSplitDurationSeconds != prev {
            onDirtyChange(true)
        }
    }

    private func exportSinglePreset(_ preset: ConversionPreset) {
        let panel = NSSavePanel()
        let filename = preset.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        panel.nameFieldStringValue = "\(filename.isEmpty ? "preset" : filename).json"
        panel.allowedContentTypes = [.json]

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try PresetExchange.exportSingle(preset: preset)
                try data.write(to: url)
            } catch {
                Task { @MainActor in
                    saveErrorMessage = error.localizedDescription
                    showingSaveError = true
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func filenamePreview(for preset: ConversionPreset) -> String {
        let sampleName: String
        let defaultExt: String
        switch preset.category {
        case .image:
            sampleName = "Photo.png"
            defaultExt = "jpg"
        case .audio:
            sampleName = "Recording.wav"
            defaultExt = "mp3"
        case .document:
            sampleName = "Document.docx"
            defaultExt = "pdf"
        case .video, .custom:
            sampleName = "Example Clip.mov"
            defaultExt = "mp4"
        }
        let sourceURL = URL(fileURLWithPath: "/tmp/\(sampleName)")
        var previewPreset = preset

        if previewPreset.filenamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            previewPreset.filenamePattern = "{name}"
        }

        let targetExtension = previewPreset.destinationFormat.isEmpty
            ? defaultExt
            : previewPreset.destinationFormat

        return OutputNamingEngine.generateFormattedFilename(
            sourceURL: sourceURL,
            preset: previewPreset,
            targetExtension: targetExtension
        )
    }

    private func chooseCustomFolder(for preset: Binding<ConversionPreset>) {
        let previousPolicy = preset.wrappedValue.outputDirectoryPolicy
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Converted files for this preset will be saved here."

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                Task { @MainActor in
                    if case .customFolder = preset.wrappedValue.outputDirectoryPolicy {
                        // Maintain established custom folder
                    } else {
                        preset.wrappedValue.outputDirectoryPolicy = previousPolicy
                    }
                }
                return
            }

            do {
                let bookmarkData = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                Task { @MainActor in
                    var inheritance = preset.wrappedValue.resolvedInheritance
                    inheritance.outputLocation = false
                    preset.wrappedValue.inheritance = inheritance
                    preset.wrappedValue.outputDirectoryPolicy = .customFolder(
                        bookmarkData: bookmarkData,
                        displayPath: url.path
                    )
                    onDirtyChange(true)
                }
            } catch {
                Task { @MainActor in
                    preset.wrappedValue.outputDirectoryPolicy = previousPolicy
                    saveErrorMessage = "Could not create security bookmark for selected folder: \(error.localizedDescription)"
                    showingSaveError = true
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
