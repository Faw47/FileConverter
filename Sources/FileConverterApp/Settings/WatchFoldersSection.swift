import AppKit
import FileConverterCore
import SwiftUI

/// General › Watched Folders: folders whose new files convert on their own.
struct WatchFoldersSection: View {
    @ObservedObject private var watcher = FolderWatcher.shared

    /// Presets a folder can use: not the PDF dialogs, which need choices.
    private var presets: [ConversionPreset] {
        PresetStore.shared.enabledPresets.filter { !$0.isInteractiveWorkflow }
    }

    var body: some View {
        Section {
            if watcher.folders.isEmpty {
                Text("No folders yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(watcher.folders) { folder in
                row(folder)
            }
            HStack {
                Spacer()
                Button("Add Folder…", action: addFolder)
            }
        } header: {
            Text("Watched Folders")
        } footer: {
            FooterText("New files in a watched folder convert on their own with its preset, into a “\(WatchFolder.outputSubfolderName)” folder inside it. Files already there, and files in its subfolders, are left alone. File Converter must be open.")
        }
    }

    private func row(_ folder: WatchFolder) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { folder.isEnabled },
                set: { var changed = folder; changed.isEnabled = $0; watcher.update(changed) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.url.lastPathComponent)
                    Text((folder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            .help(folder.isEnabled ? "Watching" : "Paused")

            Spacer()

            Picker("Preset for \(folder.url.lastPathComponent)", selection: Binding(
                get: { folder.presetID },
                set: { var changed = folder; changed.presetID = $0; watcher.update(changed) }
            )) {
                if !presets.contains(where: { $0.id == folder.presetID }) {
                    Text("Choose a Preset").tag(folder.presetID)
                }
                ForEach(FormatCategory.allCases) { category in
                    let members = presets.filter { $0.category == category }
                    if !members.isEmpty {
                        Section(category.displayName) {
                            ForEach(members) { Text($0.menuName).tag($0.id) }
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()

            Button {
                watcher.remove(id: folder.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop watching this folder")
            .accessibilityLabel("Stop watching \(folder.url.lastPathComponent)")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder. New files in it will convert on their own."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let preferred = PresetUsageStore.recentPresetIDs().first { id in presets.contains { $0.id == id } }
        guard let presetID = preferred ?? presets.first?.id else { return }
        watcher.add(folderURL: url, presetID: presetID)
    }
}
