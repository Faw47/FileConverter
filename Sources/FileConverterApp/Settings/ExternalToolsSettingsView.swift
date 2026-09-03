import AppKit
import FileConverterCore
import FileConverterExternalBackends
import SwiftUI

public struct ExternalToolsSettingsView: View {
    @State private var tools: [ToolInfo] = []
    @State private var isScanning = false
    @State private var lastChecked: Date?

    public init() {}

    public var body: some View {
        SettingsPage(
            title: "External Tools",
            subtitle: "Check the command-line tools used by optional conversion backends.",
            systemImage: "wrench.and.screwdriver"
        ) {
            Form {
                Section {
                    if isScanning && tools.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning installed tools...")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if tools.isEmpty {
                        ContentUnavailableView(
                            "No tools found",
                            systemImage: "terminal",
                            description: Text("Run a scan to check supported external tools.")
                        )
                    } else {
                        ForEach(tools) { tool in
                            ToolStatusRow(tool: tool)
                        }
                    }
                } header: {
                    HStack {
                        Text(summaryTitle)
                        Spacer()
                        if isScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Missing tools do not hide presets. They only prevent conversions that depend on that backend.")
                        if let lastChecked {
                            Text("Last checked \(lastChecked.formatted(date: .omitted, time: .shortened)).")
                        }
                    }
                }

                Section {
                    Button {
                        refresh()
                    } label: {
                        Label(isScanning ? "Scanning..." : "Scan Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(isScanning)

                    Button("Open Homebrew Website...") {
                        guard let url = URL(string: "https://brew.sh") else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .onAppear {
            if tools.isEmpty {
                refresh()
            }
        }
    }

    private var summaryTitle: String {
        guard !tools.isEmpty else { return "Tool Status" }
        let installedCount = tools.filter(\.isInstalled).count
        return "Tool Status (\(installedCount) of \(tools.count) installed)"
    }

    private func refresh() {
        guard !isScanning else { return }
        isScanning = true

        Task.detached(priority: .userInitiated) {
            ExternalToolDiscovery.shared.refreshAllTools()
            let discovered = ExternalToolDiscovery.shared.allTools().sorted { $0.name < $1.name }

            await MainActor.run {
                tools = discovered
                lastChecked = Date()
                isScanning = false
            }
        }
    }
}

private struct ToolStatusRow: View {
    let tool: ToolInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body.weight(.medium))
                    if let version = tool.version, !version.isEmpty {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Label(tool.isInstalled ? "Installed" : "Missing", systemImage: tool.isInstalled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tool.isInstalled ? Color.green : Color.orange)
            }

            if let path = tool.executablePath, !path.isEmpty {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !tool.isInstalled {
                HStack(spacing: 8) {
                    Text(tool.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tool.installCommand, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private var displayName: String {
        switch tool.name {
        case "ffmpeg": return "FFmpeg"
        case "ffprobe": return "FFprobe"
        case "magick": return "ImageMagick"
        case "gs": return "Ghostscript"
        case "soffice": return "LibreOffice"
        default: return tool.name
        }
    }
}
