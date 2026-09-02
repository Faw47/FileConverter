import SwiftUI
import FileConverterCore
import FileConverterExternalBackends

public struct ExternalToolsSettingsView: View {
    @State private var tools: [ToolInfo] = []
    @State private var isLoading = false
    @State private var lastChecked: Date?

    public init() {}

    public var body: some View {
        Form {
            Section {
                if isLoading && tools.isEmpty {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning for tools…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .accessibilityLabel("Scanning for external tools")
                } else {
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(displayName(for: tool))
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                if tool.isInstalled {
                                    Label("Installed", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("\(displayName(for: tool)) installed")
                                } else {
                                    Label("Missing", systemImage: "xmark.circle")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("\(displayName(for: tool)) not installed")
                                }
                            }

                            if let path = tool.executablePath {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if let version = tool.version {
                                Text(version)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            if !tool.isInstalled {
                                HStack {
                                    Text(tool.installCommand)
                                        .font(.system(size: 11, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.1))
                                        .clipShape(.rect(cornerRadius: 4))
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(tool.installCommand, forType: .string)
                                    }
                                    .controlSize(.small)
                                    .accessibilityLabel("Copy install command for \(displayName(for: tool))")
                                }
                                .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
            } header: {
                Text(summaryText).font(.headline)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every preset stays visible. Missing tools only matter at convert time — for example MP3 needs FFmpeg, Office docs need LibreOffice.")
                    if let lastChecked {
                        Text("Last checked \(lastChecked.formatted(date: .omitted, time: .shortened)).")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    refresh()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isLoading ? "Scanning…" : "Re-scan Installed Tools")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel("Re-scan installed tools")

                Button("How to Install Homebrew...") {
                    if let url = URL(string: "https://brew.sh") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityLabel("Open Homebrew website")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("External Tools")
        .onAppear { refresh() }
    }

    private var summaryText: String {
        guard !tools.isEmpty else { return "External Tools" }
        let installed = tools.filter(\.isInstalled).count
        return "External Tools — \(installed) of \(tools.count) installed"
    }

    private func displayName(for tool: ToolInfo) -> String {
        switch tool.name {
        case "ffmpeg": return "FFmpeg (video & audio)"
        case "ffprobe": return "FFprobe (media analysis)"
        case "magick": return "ImageMagick (images)"
        case "gs": return "Ghostscript (PDF)"
        case "soffice": return "LibreOffice (documents)"
        default: return tool.name
        }
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            ExternalToolDiscovery.shared.refreshAllTools()
            let found = ExternalToolDiscovery.shared.allTools().sorted { $0.name < $1.name }
            await MainActor.run {
                self.tools = found
                self.lastChecked = Date()
                self.isLoading = false
            }
        }
    }
}
