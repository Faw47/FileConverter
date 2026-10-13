import AppKit
import FileConverterCore
import FileConverterExternalBackends
import SwiftUI

/// Optional command-line tools that add formats. Each row shows whether the
/// tool was found, its version, and where; a tool installed somewhere
/// unusual can be pointed to by hand.
public struct ExternalToolsSettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var tools: [ToolInfo] = []
    @State private var pathError: String?

    public init() {}

    /// FFprobe ships with FFmpeg and is shown inside its row.
    private static let order = ["ffmpeg", "magick", "gs", "soffice", "ebook-convert"]

    private var installedCount: Int {
        Self.order.filter { name in tools.first { $0.name == name }?.isInstalled == true }.count
    }

    public var body: some View {
        Form {
            Section {
                ForEach(Self.order, id: \.self) { name in
                    if let tool = tools.first(where: { $0.name == name }) {
                        row(for: tool)
                    }
                }
            } header: {
                HStack {
                    Text("\(installedCount) of \(Self.order.count) tools found")
                    Spacer()
                    if appState.isDiscoveringBackends {
                        ProgressView().controlSize(.small)
                        Text(appState.discoveryStatus ?? "Checking…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Check Again") { rescan() }
                            .controlSize(.small)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These are optional. Without them, File Converter uses what macOS provides and hides presets that need a missing tool.")
                    HStack(spacing: 4) {
                        Text("Install them with Homebrew:")
                        Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadTools)
        .onReceive(NotificationCenter.default.publisher(for: ExternalToolDiscovery.didRefreshNotification)) { _ in
            Task { @MainActor in loadTools() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pick up tools installed while the app was in the background.
            if let last = ExternalToolDiscovery.shared.lastRefreshDate, Date().timeIntervalSince(last) > 60 {
                rescan()
            }
        }
        .alert("Cannot Use That File", isPresented: Binding(
            get: { pathError != nil },
            set: { if !$0 { pathError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pathError ?? "")
        }
    }

    @ViewBuilder
    private func row(for tool: ToolInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(displayName(tool.name))
                    .font(.body.weight(.medium))
                if let version = tool.version.map(cleanVersion) {
                    Text(version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if tool.isInstalled {
                    Label("Found", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Text("Not installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    if let path = tool.executablePath {
                        Button("Copy Path") { copy(path) }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    Button("Choose Location…") { chooseLocation(for: tool.name) }
                    if ExternalToolDiscovery.shared.pathOverride(for: tool.name) != nil {
                        Button("Find Automatically") {
                            ExternalToolDiscovery.shared.setPathOverride(nil, for: tool.name)
                            rescan()
                        }
                    }
                    if !tool.isInstalled {
                        Button("Copy Install Command") { copy(tool.installCommand) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Options for \(displayName(tool.name))")
            }
            Text(role(tool.name))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let path = tool.executablePath {
                Text(path + (ExternalToolDiscovery.shared.pathOverride(for: tool.name) != nil ? " (chosen by you)" : ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("To install: \(tool.installCommand)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if tool.name == "ffmpeg", let probe = tools.first(where: { $0.name == "ffprobe" }), !probe.isInstalled, tool.isInstalled {
                Text("FFprobe, which comes with FFmpeg, was not found; splitting audio and size targets need it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func loadTools() {
        tools = ExternalToolDiscovery.shared.allTools()
    }

    private func rescan() {
        guard !appState.isDiscoveringBackends else { return }
        appState.startBackendDiscovery(force: true)
    }

    private func chooseLocation(for name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(displayName(name)) program (\(name))."
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ExternalToolDiscovery.shared.setPathOverride(url.path, for: name) {
            rescan()
        } else {
            pathError = "“\(url.lastPathComponent)” is not a program File Converter can run."
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func displayName(_ name: String) -> String {
        switch name {
        case "ffmpeg": return "FFmpeg"
        case "ffprobe": return "FFprobe"
        case "magick": return "ImageMagick"
        case "gs": return "Ghostscript"
        case "soffice": return "LibreOffice"
        case "ebook-convert": return "Calibre"
        default: return name
        }
    }

    private func role(_ name: String) -> String {
        switch name {
        case "ffmpeg": return "More video and audio formats: MKV, WebM, AVI, MP3, Opus, AV1, splitting audio."
        case "magick": return "WebP output, SVG, PSD, and other image formats macOS cannot write."
        case "gs": return "Stronger PDF compression that keeps text sharp."
        case "soffice": return "Word, Excel, PowerPoint, and OpenDocument conversions."
        case "ebook-convert": return "EPUB to PDF."
        default: return ""
        }
    }

    private func cleanVersion(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        for (index, part) in parts.enumerated() {
            let lower = part.lowercased()
            if (lower == "version" || lower == "ghostscript" || lower == "imagemagick") && index + 1 < parts.count {
                let version = parts[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}"))
                if !version.isEmpty { return version }
            }
        }
        for part in parts where part.contains(".") && part.rangeOfCharacter(from: .decimalDigits) != nil {
            let clean = part.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}"))
            if !clean.isEmpty { return clean }
        }
        return String(raw.prefix(12))
    }
}
