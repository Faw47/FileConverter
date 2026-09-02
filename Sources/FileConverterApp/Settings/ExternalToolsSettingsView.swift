#if FILE_CONVERTER_EXTENDED
import SwiftUI
import FileConverterCore
import FileConverterExternalBackends

public struct ExternalToolsSettingsView: View {
    @State private var tools: [ToolInfo] = []
    @State private var isRefreshing = false

    public init() {}

    public var body: some View {
        Form {
            Section(
                header: Text("External Tool Dependencies").font(.headline),
                footer: Text("File Converter works out-of-the-box using native Apple frameworks (AVFoundation, ImageIO, PDFKit). External tools are optional enhancements for unsupported containers/codecs like MKV, WebM, AV1, or Office documents.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            ) {
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(tool.name)
                                .font(.system(size: 14, weight: .semibold))

                            Spacer()

                            if tool.isInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.green)
                            } else {
                                Label("Not Installed", systemImage: "xmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                        }

                        if let path = tool.executablePath {
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        if let ver = tool.version {
                            Text(ver)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        if !tool.isInstalled {
                            HStack {
                                Text("Install: ")
                                    .font(.system(size: 11, weight: .medium))

                                Text(tool.installCommand)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)

                                Spacer()

                                Button("Copy Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tool.installCommand, forType: .string)
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button(action: refreshTools) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Re-scan Installed Tools")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            refreshTools()
        }
    }

    private func refreshTools() {
        ExternalToolDiscovery.shared.refreshAllTools()
        tools = ExternalToolDiscovery.shared.allTools()
    }
}
#endif
