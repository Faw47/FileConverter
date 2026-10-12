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
    @State private var showingImportWarning = false
    @State private var importWarningMessage = ""
    @State private var replaceOnImport = false
    @State private var isEditorDirty = false
    @State private var showingUnsavedChangesConfirmation = false
    @State private var pendingEditorAction: PendingEditorAction?
    @State private var showingNewPresetWizard = false
    @State private var showingConflictResolution = false
    @State private var pendingImportData: Data?
    @State private var importConflicts: [PresetImportConflict] = []
    @State private var showingMutationError = false
    @State private var mutationErrorMessage = ""
    @State private var showingStartFreshConfirmation = false

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

                recoveryBanner

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
        .sheet(isPresented: $showingConflictResolution) {
            PresetConflictResolutionSheet(
                conflicts: importConflicts,
                onResolve: { resolutions in
                    showingConflictResolution = false
                    guard let data = pendingImportData else { return }
                    pendingImportData = nil
                    importConflicts = []
                    do {
                        try PresetStore.shared.importPresetsJSON(data, resolutions: resolutions)
                        reload()
                        if let warning = PresetStore.shared.lastImportWarning {
                            importWarningMessage = warning
                            showingImportWarning = true
                        }
                    } catch {
                        importErrorMessage = error.localizedDescription
                        showingImportError = true
                    }
                },
                onCancel: {
                    showingConflictResolution = false
                    pendingImportData = nil
                    importConflicts = []
                }
            )
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage.isEmpty ? "That file is not a valid presets export." : importErrorMessage)
        }
        .alert("Import Notice", isPresented: $showingImportWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importWarningMessage)
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
                do {
                    try PresetStore.shared.resetToDefaults()
                    selection = nil
                    reload()
                } catch {
                    mutationErrorMessage = error.localizedDescription
                    showingMutationError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Custom presets will be removed and built-in presets will return to their original settings.")
        }
        .confirmationDialog(
            "Start fresh with default presets?",
            isPresented: $showingStartFreshConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Fresh", role: .destructive) {
                do {
                    try PresetStore.shared.startFresh()
                    selection = nil
                    reload()
                } catch {
                    mutationErrorMessage = error.localizedDescription
                    showingMutationError = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your damaged presets will be preserved under a timestamped recovery file so no data is lost.")
        }
        .alert("Preset Storage Error", isPresented: $showingMutationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mutationErrorMessage)
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
                request(.delete(selection!))
            }
        }
    }

    private var presetSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search presets", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search presets")

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

            if let selected = selectedPreset, !filteredPresets.contains(where: { $0.id == selected.id }) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(Color.accentColor)
                    Text("Selected '\(selected.name)' is hidden by filter")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Clear") {
                        searchText = ""
                        categoryFilter = nil
                    }
                    .controlSize(.mini)
                    .accessibilityLabel("Clear filter to show selected preset")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }

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
                                Button("Export Preset...") {
                                    exportSinglePreset(preset)
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
                .accessibilityLabel("Duplicate selected preset")

                Button {
                    if let selectedPreset {
                        request(.delete(selectedPreset.id))
                    }
                } label: {
                    Image(systemName: selectedPreset?.isBuiltIn == true ? "eye.slash" : "trash")
                }
                .disabled(selectedPreset == nil)
                .help(selectedPreset?.isBuiltIn == true ? "Disable selected built-in preset" : "Delete selected preset")
                .accessibilityLabel(selectedPreset?.isBuiltIn == true ? "Disable selected built-in preset" : "Delete selected preset")

                Spacer()

                Menu {
                    Button("Import Presets...") {
                        request(.importPresets)
                    }
                    Button("Export All Presets...") {
                        exportPresets()
                    }
                    if let selected = selectedPreset {
                        Button("Export '\(selected.name)'...") {
                            exportSinglePreset(selected)
                        }
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
                .accessibilityLabel("More preset actions")
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
        do {
            try PresetStore.shared.updatePreset(updatedPreset)
            reload()
        } catch {
            mutationErrorMessage = error.localizedDescription
            showingMutationError = true
        }
    }

    private func addPreset(_ template: ConversionPreset) {
        var preset = template
        preset.id = UUID()
        preset.outputDirectoryPolicy = settings.defaultOutputPolicy
        preset.filenamePattern = settings.defaultFilenamePattern
        preset.overwritePolicy = settings.defaultOverwritePolicy
        preset.preserveCreationDate = settings.preserveTimestamps

        do {
            try PresetStore.shared.addPreset(preset)
            presets = PresetStore.shared.presets
            categoryFilter = nil
            searchText = ""
            selection = preset.id
        } catch {
            mutationErrorMessage = error.localizedDescription
            showingMutationError = true
        }
    }

    private func duplicate(_ preset: ConversionPreset) {
        do {
            guard let copy = try PresetStore.shared.duplicatePreset(withID: preset.id) else { return }
            presets = PresetStore.shared.presets
            categoryFilter = nil
            searchText = ""
            selection = copy.id
        } catch {
            mutationErrorMessage = error.localizedDescription
            showingMutationError = true
        }
    }

    private func deleteSelected() {
        guard let selection else { return }
        do {
            try PresetStore.shared.deletePreset(withID: selection)
            self.selection = nil
            reload()
        } catch {
            mutationErrorMessage = error.localizedDescription
            showingMutationError = true
        }
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

        let completion: (NSApplication.ModalResponse) -> Void = { response in
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

        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
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
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let data = try Data(contentsOf: url)
                let conflicts = try PresetStore.shared.detectImportConflicts(in: data)
                if conflicts.isEmpty {
                    try PresetStore.shared.importPresetsJSON(data, overwrite: replaceOnImport)
                    Task { @MainActor in
                        reload()
                        if let warning = PresetStore.shared.lastImportWarning {
                            importWarningMessage = warning
                            showingImportWarning = true
                        }
                    }
                } else {
                    Task { @MainActor in
                        pendingImportData = data
                        importConflicts = conflicts
                        showingConflictResolution = true
                    }
                }
            } catch {
                Task { @MainActor in
                    importErrorMessage = error.localizedDescription
                    showingImportError = true
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @ViewBuilder
    private var recoveryBanner: some View {
        if case .recoveryRequired(let context) = PresetStore.shared.state {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preset Storage Recovery Required")
                            .font(.headline)
                        Text("File Converter could not read your presets file (\(context.sourceFileURL.lastPathComponent)): \(context.errorDescription). Your original file has been preserved to prevent data loss.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Export Damaged File...") {
                        exportDamagedFile()
                    }
                    .controlSize(.small)

                    Button("Retry Loading") {
                        PresetStore.shared.loadPresets()
                        reload()
                    }
                    .controlSize(.small)
                }

                if !context.backupCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Available Backups:")
                            .font(.subheadline.weight(.semibold))

                        ForEach(context.backupCandidates) { candidate in
                            HStack {
                                Text("Backup \(candidate.backupNumber)")
                                    .font(.subheadline.weight(.medium))
                                if let date = candidate.modificationDate {
                                    Text(date, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(date, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if candidate.isValid {
                                    Text("(\(candidate.presetCount) preset\(candidate.presetCount == 1 ? "" : "s"))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Restore Backup \(candidate.backupNumber)") {
                                        do {
                                            try PresetStore.shared.restoreFromBackup(url: candidate.url)
                                            reload()
                                        } catch {
                                            mutationErrorMessage = error.localizedDescription
                                            showingMutationError = true
                                        }
                                    }
                                    .controlSize(.small)
                                } else {
                                    Text("(Damaged or incompatible)")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(6)
                }

                HStack {
                    Button("Start Fresh with Defaults...", role: .destructive) {
                        showingStartFreshConfirmation = true
                    }
                    .controlSize(.small)

                    Text("This preserves your damaged file under a timestamped recovery name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Color.yellow.opacity(0.12))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
    }

    private func exportDamagedFile() {
        do {
            let data = try PresetStore.shared.exportDamagedData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "damaged-presets.json"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            mutationErrorMessage = error.localizedDescription
            showingMutationError = true
        }
    }
}

private struct PresetConflictResolutionSheet: View {
    let conflicts: [PresetImportConflict]
    let onResolve: ([UUID: PresetConflictResolution]) -> Void
    let onCancel: () -> Void

    @State private var resolutions: [UUID: PresetConflictResolution] = [:]

    init(
        conflicts: [PresetImportConflict],
        onResolve: @escaping ([UUID: PresetConflictResolution]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.conflicts = conflicts
        self.onResolve = onResolve
        self.onCancel = onCancel
        var initial: [UUID: PresetConflictResolution] = [:]
        for c in conflicts {
            initial[c.id] = .replace
        }
        _resolutions = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Preset Conflicts Detected")
                        .font(.headline)
                    Text("The imported file contains \(conflicts.count) preset(s) that conflict with existing presets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                Text("Apply to All:")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Button("Replace All") {
                    for c in conflicts { resolutions[c.id] = .replace }
                }
                .controlSize(.small)

                Button("Import All as Copies") {
                    for c in conflicts { resolutions[c.id] = .copy }
                }
                .controlSize(.small)

                Button("Skip All") {
                    for c in conflicts { resolutions[c.id] = .skip }
                }
                .controlSize(.small)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(conflicts) { conflict in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: conflict.importedPreset.category.systemImage)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(conflict.importedPreset.name)
                                    .font(.body.weight(.medium))
                                Text(conflict.conflictReason.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: Binding(
                                get: { resolutions[conflict.id] ?? .replace },
                                set: { resolutions[conflict.id] = $0 }
                            )) {
                                ForEach(PresetConflictResolution.allCases, id: \.self) { res in
                                    Text(res.rawValue).tag(res)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 320)

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .controlSize(.regular)

                Spacer()

                Button("Import") {
                    onResolve(resolutions)
                }
                .glassActionProminent()
                .controlSize(.regular)
            }
            .padding(16)
        }
        .frame(width: 520)
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

            if !preset.outputDirectoryPolicy.isCustomFolderAuthorized {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.orange)
                    .help("Requires folder authorization")
            } else if !preset.isEnabled {
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
