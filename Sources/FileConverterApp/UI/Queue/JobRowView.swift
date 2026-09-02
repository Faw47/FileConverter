import SwiftUI
import FileConverterCore
import AppKit

public struct JobRowView: View {
    public let job: ConversionJob
    @State private var isHovered = false
    @State private var showingErrorDetails = false

    public init(job: ConversionJob) {
        self.job = job
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Category Icon
            Image(systemName: job.preset.category.systemImage)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .cornerRadius(6)

            // File & Conversion Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.filename)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 2) {
                        Text(job.sourceFormat)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.secondary)

                        Text(job.targetFormat)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(3)
                    }
                }

                // Progress / State message
                HStack(spacing: 8) {
                    Text(statusDescription)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)

                    if job.state.isActive, let eta = job.progress.formattedTimeRemaining {
                        Text("• ETA: \(eta)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if let backend = job.resolvedBackend {
                        Text("• \(backend.displayName)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Progress Bar / Status Indicator
            if job.state.isActive {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(job.progress.percentageString)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))

                    ProgressView(value: job.progress.fractionCompleted)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                }
            }

            // Action Buttons
            HStack(spacing: 4) {
                switch job.state {
                case .queued, .preparing, .converting, .finalizing:
                    Button(action: {
                        ConversionQueue.shared.cancelJob(id: job.id)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel conversion")

                case .completed:
                    if let dest = job.destinationURL {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([dest])
                        }) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }

                case .failed(let err):
                    Button(action: {
                        showingErrorDetails = true
                    }) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Show error details")
                    .popover(isPresented: $showingErrorDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Conversion Failed")
                                .font(.headline)
                            Text(err.localizedDescription)
                                .font(.subheadline)
                            if let rec = err.recoverySuggestion {
                                Text("Suggestion: \(rec)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Button("Copy Technical Details") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(err.technicalDetails, forType: .string)
                            }
                            .controlSize(.small)
                        }
                        .padding()
                        .frame(width: 320)
                    }

                    Button(action: {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Retry conversion")

                case .cancelled:
                    Button(action: {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Restart conversion")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            if let dest = job.destinationURL, FileManager.default.fileExists(atPath: dest.path) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
                Button("Open Converted File") {
                    NSWorkspace.shared.open(dest)
                }
                Divider()
                Button("Copy Output Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dest.path, forType: .string)
                }
            }

            Button("Copy Source Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.sourceURL.path, forType: .string)
            }

            Divider()

            if job.state.isActive || job.state == .queued {
                Button("Cancel Conversion") {
                    ConversionQueue.shared.cancelJob(id: job.id)
                }
            }

            if case .failed = job.state {
                Button("Retry Conversion") {
                    ConversionQueue.shared.retryJob(id: job.id)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.filename), converting from \(job.sourceFormat) to \(job.targetFormat), status: \(statusDescription)")
    }

    private var iconColor: Color {
        switch job.preset.category {
        case .video: return .purple
        case .audio: return .orange
        case .image: return .blue
        case .document: return .green
        case .custom: return .pink
        }
    }

    private var statusDescription: String {
        switch job.state {
        case .queued: return "Queued in line"
        case .preparing: return "Preparing..."
        case .converting:
            if let fps = job.progress.currentFPS, fps > 0 {
                return String(format: "Encoding (%.1f fps)", fps)
            }
            return "Converting..."
        case .finalizing: return "Writing to destination..."
        case .completed: return "Converted successfully"
        case .failed(let error): return error.localizedDescription
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .queued: return .secondary
        case .preparing, .converting, .finalizing: return .primary
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
