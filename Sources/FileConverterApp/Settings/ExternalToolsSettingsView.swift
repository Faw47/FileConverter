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
        ScrollView {
            LiquidGlassContainer(spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    // Header
                    headerView

                    // Overview Hero Card
                    overviewSection

                    // Tool Cards
                    toolsListSection

                    // Homebrew Guide Card
                    homebrewGuideSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if tools.isEmpty {
                let cached = ExternalToolDiscovery.shared.allTools().sorted { $0.name < $1.name }
                if !cached.isEmpty {
                    tools = cached
                } else {
                    refresh()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ExternalToolDiscovery.didRefreshNotification)) { _ in
            tools = ExternalToolDiscovery.shared.allTools().sorted { $0.name < $1.name }
            lastChecked = Date()
            isScanning = false
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 14) {
            SettingsIconBadge(systemImage: "terminal.fill", color: .orange, size: .header)

            VStack(alignment: .leading, spacing: 2) {
                Text("External Tools")
                    .font(.title2.weight(.bold))

                Text("Manage command-line engines for video transcoding, image filters, and office formats.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Overview Hero Card

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Engine Status", accessory: lastCheckedText)

            SettingsCard {
                HStack(spacing: 16) {
                    // Visual Status Ring / Icon
                    ZStack {
                        Circle()
                            .fill(allInstalled ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))
                            .frame(width: 46, height: 46)

                        Image(systemName: allInstalled ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(allInstalled ? Color.green : Color.orange)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusSummaryTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(statusSummarySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        refresh()
                    } label: {
                        HStack(spacing: 6) {
                            if isScanning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(isScanning ? "Scanning..." : "Rescan")
                        }
                    }
                    .glassAction()
                    .controlSize(.small)
                    .disabled(isScanning)
                }
                .padding(14)
            }
        }
    }

    private var allInstalled: Bool {
        !tools.isEmpty && tools.allSatisfy(\.isInstalled)
    }

    private var installedCount: Int {
        tools.filter(\.isInstalled).count
    }

    private var statusSummaryTitle: String {
        if isScanning && tools.isEmpty {
            return "Searching for Installed Tools..."
        }
        if tools.isEmpty {
            return "No Tools Discovered"
        }
        return "\(installedCount) of \(tools.count) External Tools Available"
    }

    private var statusSummarySubtitle: String {
        if allInstalled {
            return "All optional conversion engines are detected and ready for high-performance conversions."
        }
        return "Missing tools do not prevent app usage, but presets requiring those engines will be unavailable."
    }

    private var lastCheckedText: String? {
        guard let lastChecked else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Checked \(formatter.localizedString(for: lastChecked, relativeTo: Date()))"
    }

    // MARK: - Tools List Section

    private var toolsListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Discovered Backends")

            if isScanning && tools.isEmpty {
                SettingsCard {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Querying system binaries in /opt/homebrew/bin and /usr/local/bin...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            } else if tools.isEmpty {
                SettingsCard {
                    VStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No external tools found")
                            .font(.headline)
                        Text("Run a scan or install Homebrew packages to enable extended backends.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 16) {
                    ForEach(tools) { tool in
                        toolCard(for: tool)
                    }
                }
            }
        }
    }

    private func toolCard(for tool: ToolInfo) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                // Header row: Icon, Name, Role, Badge
                HStack(alignment: .top, spacing: 12) {
                    SettingsIconBadge(
                        systemImage: toolIcon(for: tool.name),
                        color: tool.isInstalled ? .green : .orange,
                        size: .tool
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(toolDisplayName(for: tool.name))
                                .font(.body.weight(.semibold))

                            if let version = tool.version, !version.isEmpty {
                                Text("v\(cleanVersion(version))")
                                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(Color.secondary.opacity(0.12))
                                    )
                            }
                        }

                        Text(toolRoleDescription(for: tool.name))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusBadge(
                        tool.isInstalled ? "Installed" : "Missing",
                        style: tool.isInstalled ? .success : .warning
                    )
                }

                // Details / Actions
                if tool.isInstalled, let path = tool.executablePath, !path.isEmpty {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)

                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Copy binary path")
                    }
                } else if !tool.isInstalled {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Install via Homebrew Terminal:")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        CopyableCommandField(command: tool.installCommand)
                    }
                }
            }
            .padding(14)
        }
    }

    private func toolDisplayName(for name: String) -> String {
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

    private func toolIcon(for name: String) -> String {
        switch name {
        case "ffmpeg": return "film"
        case "ffprobe": return "waveform"
        case "magick": return "photo.artframe"
        case "gs": return "doc.richtext"
        case "soffice": return "doc.text.fill"
        case "ebook-convert": return "books.vertical.fill"
        default: return "terminal"
        }
    }

    private func toolRoleDescription(for name: String) -> String {
        switch name {
        case "ffmpeg":
            return "Advanced audio & video transcoding, WebM, MKV, AVI, and high-efficiency codecs."
        case "ffprobe":
            return "Media analysis required for audio splitting and fitting audio within a chosen file size."
        case "magick":
            return "Bitmap and vector graphics transformations, format conversions, and color profiles."
        case "gs":
            return "PostScript rendering, vector PDF rasterization, and document optimization."
        case "soffice":
            return "Headless office document conversion for DOCX, PPTX, XLSX, and ODF to PDF."
        case "ebook-convert":
            return "EPUB to PDF conversion with Calibre’s e-book layout engine."
        default:
            return "External processing backend."
        }
    }

    // MARK: - Homebrew Guide Section

    private var homebrewGuideSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Package Manager")

            SettingsCard {
                HStack(spacing: 14) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.brown)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Need Homebrew?")
                            .font(.body.weight(.medium))

                        Text("Homebrew is the standard package manager for macOS. It installs open-source conversion backends into standard system paths.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        if let url = URL(string: "https://brew.sh") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("brew.sh")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .glassAction()
                    .controlSize(.small)
                }
                .padding(14)
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        guard !isScanning else { return }
        isScanning = true

        Task.detached(priority: .userInitiated) {
            ExternalToolDiscovery.shared.refreshAllTools(force: true)
            let discovered = ExternalToolDiscovery.shared.allTools().sorted { $0.name < $1.name }

            await MainActor.run {
                tools = discovered
                lastChecked = Date()
                isScanning = false
            }
        }
    }

    private func cleanVersion(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        for (idx, part) in parts.enumerated() {
            let lower = part.lowercased()
            if (lower == "version" || lower == "ghostscript" || lower == "imagemagick") && idx + 1 < parts.count {
                let v = parts[idx + 1].trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}"))
                if !v.isEmpty { return v }
            }
        }
        for part in parts {
            if part.contains(".") && part.rangeOfCharacter(from: .decimalDigits) != nil {
                let clean = part.trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}"))
                if !clean.isEmpty { return clean }
            }
        }
        return raw.prefix(12).description
    }
}
