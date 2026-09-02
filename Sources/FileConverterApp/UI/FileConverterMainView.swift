import SwiftUI
import FileConverterCore
import UniformTypeIdentifiers

public struct ConversionBatchSelection: Identifiable {
    public let id = UUID()
    public let urls: [URL]

    public init(urls: [URL]) {
        self.urls = urls
    }
}

public struct FileConverterMainView: View {
    @Environment(\.openSettings) private var openSettings
    @StateObject private var appState = AppState.shared
    @ObservedObject private var queue = ConversionQueue.shared
    @State private var batchSelection: ConversionBatchSelection? = nil
    @State private var conversionErrorDescription: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            ConversionQueueView()
                .environmentObject(appState)

            Divider()

            DropZoneView(onSelectFiles: openFilesDialog)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380, idealHeight: 460)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenFileConverterOpenPanel"))) { _ in
            openFilesDialog()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedProviders(providers)
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: openFilesDialog) {
                    Label("Add Files...", systemImage: "plus.circle")
                }
                .help("Select files to convert (⌘O)")
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityLabel("Add Files to Convert")

                if queue.completedCount > 0 || queue.failedCount > 0 || queue.cancelledCount > 0 {
                    Button(action: { queue.clearCompleted() }) {
                        Label("Clear", systemImage: "trash")
                    }
                    .help("Clear completed jobs (⌘K)")
                    .keyboardShortcut("k", modifiers: .command)
                    .accessibilityLabel("Clear Completed Conversions")
                }

                Button(action: {
                    appState.showSettings = true
                }) {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Preferences (⌘,)")
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Open Settings")
            }
        }
        .sheet(item: $batchSelection) { batch in
            presetSelectionSheet(for: batch.urls)
        }
        .onChange(of: appState.showSettings) { _, shouldShow in
            guard shouldShow else { return }
            openSettings()
            appState.showSettings = false
        }
        .alert(
            "Unable to Start Conversion",
            isPresented: Binding(
                get: { conversionErrorDescription != nil },
                set: { if !$0 { conversionErrorDescription = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversionErrorDescription ?? "The selected conversion is unavailable.")
        }
    }

    private func presetSelectionSheet(for urls: [URL]) -> some View {
        let count = urls.count
        let compatible = PresetValidator.compatiblePresets(forURLs: urls)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Convert \(count) File\(count != 1 ? "s" : "")")
                        .font(.headline)
                    Text("Choose an output format preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    batchSelection = nil
                }
                .keyboardShortcut(.cancelAction)
            }

            if count == 0 {
                Text("No files selected.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical)
            } else if compatible.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No compatible presets found for:", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    ForEach(urls, id: \.self) { url in
                        Text("• \(url.lastPathComponent)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            } else {
                let grouped = PresetValidator.groupPresetsByCategory(compatible)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(grouped.keys.sorted(), id: \.self) { cat in
                            if let presets = grouped[cat], !presets.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(cat.displayName, systemImage: cat.systemImage)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)

                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                                        ForEach(presets) { preset in
                                            Button(action: {
                                                enqueueSelected(urls: urls, preset: preset)
                                            }) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    HStack {
                                                        Text(preset.menuName)
                                                            .font(.system(size: 13, weight: .semibold))
                                                        Spacer()
                                                        Text(preset.destinationFormat.uppercased())
                                                            .font(.system(size: 9, weight: .bold))
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 1)
                                                            .background(Color.accentColor.opacity(0.12))
                                                            .foregroundStyle(Color.accentColor)
                                                            .clipShape(.rect(cornerRadius: 3))
                                                    }

                                                    Text(preset.name)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color(nsColor: .controlBackgroundColor))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        let collector = DropURLCollector()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    if let url = url {
                        collector.store(url, at: index)
                    }
                }
            } else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let url = item as? URL {
                        collector.store(url, at: index)
                    } else if let nsURL = item as? NSURL {
                        collector.store(nsURL as URL, at: index)
                    } else if let data = item as? Data {
                        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           let url = URL(string: str), url.isFileURL {
                            collector.store(url, at: index)
                        } else if let url = URL(dataRepresentation: data, relativeTo: nil) {
                            collector.store(url, at: index)
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            let valid = collector.orderedURLs().filter { !$0.path.isEmpty }
            guard !valid.isEmpty else { return }
            self.batchSelection = ConversionBatchSelection(urls: valid)
        }
    }

    private func openFilesDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK && !panel.urls.isEmpty {
                self.batchSelection = ConversionBatchSelection(urls: panel.urls)
            }
        }
    }

    private func enqueueSelected(urls: [URL], preset: ConversionPreset) {
        Task {
            do {
                try await ConversionCoordinator.shared.convertFiles(urls: urls, preset: preset)
                batchSelection = nil
            } catch {
                conversionErrorDescription = error.localizedDescription
            }
        }
    }
}
