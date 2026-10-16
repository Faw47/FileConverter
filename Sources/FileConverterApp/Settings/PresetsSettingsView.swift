import AppKit
import FileConverterCore
import SwiftUI
import UniformTypeIdentifiers

public struct PresetsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.undoManager) private var undoManager

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
        Group {
            VStack(spacing: 0) {
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
            Text("You can undo this with Edit › Undo (⌘Z) while Settings is open.")
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
            "Discard changes that couldn't be saved?",
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
            Text("This preset has a problem, so its latest changes aren’t saved yet. Fix it, or discard those changes.")
        }
        .onDeleteCommand {
            if let selection, selectedPreset?.isBuiltIn == false {
                request(.delete(selection))
            }
        }
    }

    private var presetSidebar: some View {
        sidebarList
            .edgeBar(.top, floats: false) { sidebarFilterBar }
            .edgeBar(.bottom, floats: false) { sidebarActions }
    }

    private var sidebarFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SearchField(prompt: "Search presets", text: $searchText)

                Menu {
                    Picker("Category", selection: $categoryFilter) {
                        Text("All Categories").tag(nil as FormatCategory?)
                        Divider()
                        ForEach(FormatCategory.allCases) { category in
                            Text(category.displayName).tag(category as FormatCategory?)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(
                        categoryFilter?.displayName ?? "All Categories",
                        systemImage: categoryFilter == nil
                            ? "line.3.horizontal.decrease"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .sidebarMenuStyle()
                .help(categoryFilter.map { "Showing \($0.displayName) presets" } ?? "Show one category")
                .accessibilityLabel("Category filter")
                .accessibilityValue(categoryFilter?.displayName ?? "All Categories")
            }

            if let selected = selectedPreset, !filteredPresets.contains(where: { $0.id == selected.id }) {
                HStack(spacing: 6) {
                    Text("“\(selected.menuName)” is hidden by the search")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show All") {
                        searchText = ""
                        categoryFilter = nil
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Clear filter to show selected preset")
                }
            }
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        if filteredPresets.isEmpty {
            ContentUnavailableView(
                "No Matching Presets",
                systemImage: "magnifyingglass",
                description: Text("Change the search or category filter.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: guardedSelection) {
                ForEach(FormatCategory.allCases) { category in
                    let members = filteredPresets.filter { $0.category == category }
                    if !members.isEmpty {
                        Section(category.displayName) {
                            ForEach(members) { preset in
                                PresetSidebarRow(preset: preset)
                                    .tag(preset.id)
                                    .contextMenu {
                                        Button(preset.isEnabled ? "Hide from Menus" : "Show in Menus") {
                                            request(.toggle(preset.id))
                                        }
                                        Button("Duplicate") {
                                            request(.duplicate(preset.id))
                                        }
                                        Button("Export…") {
                                            exportSinglePreset(preset)
                                        }
                                        if preset.isBuiltIn {
                                            if isModifiedBuiltIn(preset) {
                                                Divider()
                                                Button("Restore Factory Settings") {
                                                    restoreFactory(preset)
                                                }
                                            }
                                        } else {
                                            Divider()
                                            Button("Delete…", role: .destructive) {
                                                request(.delete(preset.id))
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var sidebarActions: some View {
        HStack(spacing: 6) {
            // One capsule for add, duplicate, and remove, like the +/−
            // controls in System Settings.
            HStack(spacing: 0) {
                Button {
                    request(.add)
                } label: {
                    Label("New Preset", systemImage: "plus")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .help("New preset")
                .accessibilityLabel("Create preset")

                Button {
                    if let selectedPreset {
                        request(.duplicate(selectedPreset.id))
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(selectedPreset == nil)
                .help("Duplicate selected preset")
                .accessibilityLabel("Duplicate selected preset")

                Button {
                    if let selectedPreset {
                        request(.delete(selectedPreset.id))
                    }
                } label: {
                    Label("Delete", systemImage: "minus")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .disabled(selectedPreset == nil || selectedPreset?.isBuiltIn == true)
                .help(selectedPreset?.isBuiltIn == true ? "Built-in presets can be hidden but not deleted" : "Delete selected preset")
                .accessibilityLabel("Delete selected preset")
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .controlGroupCapsule()

            Spacer()

            Menu {
                Button("Import Presets…") {
                    request(.importPresets)
                }
                Button("Export All Presets…") {
                    exportPresets()
                }
                if let selected = selectedPreset {
                    Button("Export “\(selected.name)”…") {
                        exportSinglePreset(selected)
                    }
                }
                Divider()
                Button("Reset All Presets…", role: .destructive) {
                    request(.resetAll)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .sidebarMenuStyle()
            .help("More preset actions")
            .accessibilityLabel("More preset actions")
        }
        .labelStyle(.iconOnly)
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

    private func isModifiedBuiltIn(_ preset: ConversionPreset) -> Bool {
        BuiltInPresetUpgrades.isModifiedFromFactory(preset)
    }

    private func restoreFactory(_ preset: ConversionPreset) {
        do {
            try PresetStore.shared.restoreBuiltIn(withID: preset.id)
            reload()
        } catch {
            mutationErrorMessage = error.localizedDescription
            showingMutationError = true
        }
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
        // New presets follow General settings until the user overrides a
        // value in the editor; nothing is copied, so later General changes
        // still apply.
        preset.inheritance = .inheritAll

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
        let deleted = PresetStore.shared.preset(forID: selection)
        do {
            try PresetStore.shared.deletePreset(withID: selection)
            self.selection = nil
            reload()
            // Edit › Undo Delete Preset (⌘Z) puts it back as it was.
            if let deleted {
                let restore = { (id: UUID) in
                    self.reload()
                    self.selection = id
                }
                undoManager?.registerUndo(withTarget: PresetStore.shared) { store in
                    try? store.addPreset(deleted)
                    restore(deleted.id)
                }
                undoManager?.setActionName("Delete Preset")
            }
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
                    try PresetStore.shared.importPresetsJSON(data)
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
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("“\(context.sourceFileURL.lastPathComponent)” could not be read: \(context.errorDescription). The file is kept unchanged.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(context.backupCandidates) { candidate in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                if let date = candidate.modificationDate {
                                    Text("Backup from \(date.formatted(date: .abbreviated, time: .shortened))")
                                } else {
                                    Text("Backup \(candidate.backupNumber)")
                                }
                                Text(candidate.isValid
                                     ? Inflect.string("^[\(candidate.presetCount) preset](inflect: true)")
                                     : "Damaged; can’t be used")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if candidate.isValid {
                                Button("Restore") {
                                    do {
                                        try PresetStore.shared.restoreFromBackup(url: candidate.url)
                                        reload()
                                    } catch {
                                        mutationErrorMessage = error.localizedDescription
                                        showingMutationError = true
                                    }
                                }
                                .accessibilityLabel("Restore backup \(candidate.backupNumber)")
                            }
                        }
                    }

                    HStack {
                        Button("Try Again") {
                            PresetStore.shared.loadPresets()
                            reload()
                        }
                        Button("Save Damaged File…") {
                            exportDamagedFile()
                        }
                        Spacer()
                        Button("Start Over with Built-in Presets…", role: .destructive) {
                            showingStartFreshConfirmation = true
                        }
                    }
                    .controlSize(.small)
                }
                .padding(4)
            } label: {
                Label("Your presets couldn’t be read", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
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
        // Keeping both never loses a preset; replacing is a deliberate choice.
        _resolutions = State(initialValue: Dictionary(uniqueKeysWithValues: conflicts.map { ($0.id, .copy) }))
    }

    private static func title(_ resolution: PresetConflictResolution) -> String {
        switch resolution {
        case .replace: return "Replace mine"
        case .copy: return "Keep both"
        case .skip: return "Don’t import"
        }
    }

    private static func reason(_ conflict: PresetImportConflict) -> String {
        switch conflict.conflictReason {
        case .sameName: return "You already have a preset with this name."
        case .sameID, .sameIDAndName: return "You already have this preset."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflicts.count == 1
                     ? "“\(conflicts[0].importedPreset.name)” Is Already in Your Presets"
                     : Inflect.string("^[\(conflicts.count) preset](inflect: true) Are Already in Your Presets"))
                    .font(.title3.weight(.semibold))
                Text("Choose what to do with each one. Other presets in the file are imported as they are.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section {
                    ForEach(conflicts) { conflict in
                        Picker(selection: Binding(
                            get: { resolutions[conflict.id] ?? .copy },
                            set: { resolutions[conflict.id] = $0 }
                        )) {
                            ForEach(PresetConflictResolution.allCases, id: \.self) { resolution in
                                Text(Self.title(resolution)).tag(resolution)
                            }
                        } label: {
                            Text(conflict.importedPreset.name)
                            Text(Self.reason(conflict))
                        }
                    }
                } footer: {
                    if conflicts.count > 1 {
                        HStack {
                            Spacer()
                            Menu("Set All") {
                                ForEach(PresetConflictResolution.allCases, id: \.self) { resolution in
                                    Button(Self.title(resolution)) {
                                        for conflict in conflicts { resolutions[conflict.id] = resolution }
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .edgeBar(.bottom, style: .sheet) {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                        .edgeBarButtonStyle()
                    Button("Import") { onResolve(resolutions) }
                        .keyboardShortcut(.defaultAction)
                        .edgeBarButtonStyle(prominent: true)
                }
            }
        }
        .frame(width: 520)
        .frame(minHeight: 300, maxHeight: 560)
    }
}

private struct PresetSidebarRow: View {
    let preset: ConversionPreset

    var body: some View {
        HStack(spacing: 6) {
            Text(preset.menuName)
                .lineLimit(1)
                .foregroundStyle(preset.isEnabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if !preset.outputDirectoryPolicy.isCustomFolderAuthorized {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(.orange)
                    .help("The folder this preset saves to needs to be chosen again")
            } else if !preset.isEnabled {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help("Hidden from menus")
            } else if !BackendResolver.shared.supportsAnySource(for: preset) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs a tool that is not installed")
            }
            // Which files a single-format preset is for, unless the name says
            // so ("WAV → MP3"); otherwise two "MP4 – Fast" rows look the same.
            if let sources = specificSources {
                Text("from \(sources)")
                    .foregroundStyle(.secondary)
            } else if !preset.menuName.localizedCaseInsensitiveContains(preset.destinationFormat) {
                // The output format, unless the name already says it ("MP4 – 720p").
                Text(preset.destinationFormat.uppercased())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(preset.isEnabled ? "" : "Hidden from menus")
    }

    /// "MOV" for a preset written for specific formats, when its name
    /// doesn't already mention them; nil for kinds like "any video".
    private var specificSources: String? {
        let specific = preset.sourceFormats.filter { spec in
            let normalized = spec.lowercased()
            return normalized != "*" && FormatCategory(rawValue: normalized) == nil
        }
        guard !specific.isEmpty, specific.count == preset.sourceFormats.count,
              !specific.contains(where: { preset.menuName.localizedCaseInsensitiveContains($0) }) else { return nil }
        return specific.map { $0.uppercased() }.joined(separator: ", ")
    }
}

/// What a new preset converts. Each starts blank for that kind of file;
/// to start from an existing recipe, select it and click Duplicate.
private enum PresetTemplate: String, CaseIterable, Identifiable, Hashable {
    case image
    case video
    case audio
    case document
    case anything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Photos and images"
        case .video: return "Video"
        case .audio: return "Audio, or the sound from a video"
        case .document: return "Documents"
        case .anything: return "Any file"
        }
    }

    var subtitle: String {
        switch self {
        case .image: return "Starts as JPEG; pick the format and size next"
        case .video: return "Starts as MP4 (H.264)"
        case .audio: return "Starts as MP3"
        case .document: return "Starts as PDF"
        case .anything: return "You choose every detail"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .anything: return "slider.horizontal.3"
        }
    }

    func makePreset() -> ConversionPreset {
        switch self {
        case .image:
            return ConversionPreset(
                name: "New Image Preset", menuName: "New Image Preset", category: .image,
                sourceFormats: ["image"], destinationFormat: "jpg", backend: .auto, quality: .high
            )
        case .video:
            return ConversionPreset(
                name: "New Video Preset", menuName: "New Video Preset", category: .video,
                sourceFormats: ["video"], destinationFormat: "mp4", backend: .auto,
                videoCodec: .h264, audioCodec: .aac, quality: .high
            )
        case .audio:
            return ConversionPreset(
                name: "New Audio Preset", menuName: "New Audio Preset", category: .audio,
                sourceFormats: ["audio", "video"], destinationFormat: "mp3", backend: .auto,
                audioCodec: .mp3, quality: .high
            )
        case .document:
            return ConversionPreset(
                name: "New Document Preset", menuName: "New Document Preset", category: .document,
                sourceFormats: ["document"], destinationFormat: "pdf", backend: .auto, quality: .high
            )
        case .anything:
            return ConversionPreset(
                name: "New Preset", menuName: "New Preset", category: .custom,
                sourceFormats: ["*"], destinationFormat: "jpg", backend: .auto, quality: .high
            )
        }
    }
}

struct NewPresetWizardView: View {
    let onCreate: (ConversionPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate: PresetTemplate? = .image

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Preset")
                    .font(.title3.weight(.semibold))
                Text("What will it convert? To start from an existing preset instead, select it and click Duplicate.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            List(PresetTemplate.allCases, selection: $selectedTemplate) { template in
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title)
                    Text(template.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(template)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: PresetTemplate.self) { _ in
                EmptyView()
            } primaryAction: { templates in
                if let template = templates.first { create(template) }
            }

            .edgeBar(.bottom, style: .sheet) {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .edgeBarButtonStyle()
                    Button("Create") {
                        if let selectedTemplate { create(selectedTemplate) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .edgeBarButtonStyle(prominent: true)
                    .disabled(selectedTemplate == nil)
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 440, idealHeight: 500)
    }

    private func create(_ template: PresetTemplate) {
        onCreate(template.makePreset())
        dismiss()
    }
}

private extension View {
    /// Round glass buttons in the sidebar's floating bar on macOS 26 and
    /// later; plain borderless icons in the older bottom strip.
    /// A row of plain icon buttons drawn as one capsule: glass on macOS 26
    /// and later, a bordered segment look before that.
    @ViewBuilder
    func controlGroupCapsule() -> some View {
        if #available(macOS 26, *) {
            padding(.horizontal, 4)
                .padding(.vertical, 2)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    @ViewBuilder
    func sidebarButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    func sidebarMenuStyle() -> some View {
        if #available(macOS 26, *) {
            menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .menuIndicator(.hidden)
                .fixedSize()
        } else {
            menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }
}
