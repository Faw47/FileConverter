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
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .clipShape(.rect(cornerRadius: 6))

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
                            .clipShape(.rect(cornerRadius: 3))

                        Image(systemName: "arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(job.targetFormat)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(.rect(cornerRadius: 3))
                    }
                }

                // Progress / State message
                HStack(spacing: 8) {
                    Text(statusDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)

                    if job.state.isActive, let eta = job.progress.formattedTimeRemaining {
                        Text("• ETA: \(eta)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let backend = job.resolvedBackend {
                        Text("• \(backend.displayName)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
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
                case .queued, .preparing, .awaitingCollision, .converting:
                    Button(action: {
                        ConversionQueue.shared.cancelJob(id: job.id)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel conversion")
                    .accessibilityLabel("Cancel conversion for \(job.filename)")

                case .finalizing:
                    EmptyView()

                case .completed, .completedWithWarnings:
                    let destinations = (job.outputURLs.isEmpty
                        ? (job.destinationURL.map { [$0] } ?? [])
                        : job.outputURLs)
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !destinations.isEmpty {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting(destinations)
                        }) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal converted file in Finder")
                    }

                case .failed(let err):
                    Button(action: {
                        showingErrorDetails = true
                    }) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Show error details")
                    .popover(isPresented: $showingErrorDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Conversion Failed")
                                .font(.headline)
                            Text(err.localizedDescription)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let rec = err.recoverySuggestion {
                                Text("Suggestion: \(rec)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                            ScrollView {
                                Text(err.technicalDetails)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 180)
                            Button("Copy Technical Details") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(err.technicalDetails, forType: .string)
                            }
                            .controlSize(.small)
                        }
                        .padding()
                        .frame(minWidth: 360, idealWidth: 480, maxWidth: 560)
                    }

                    Button(action: {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Retry conversion")
                    .accessibilityLabel("Retry conversion for \(job.filename)")

                case .cancelled, .skipped:
                    Button(action: {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Restart conversion")
                    .accessibilityLabel("Restart conversion for \(job.filename)")
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
            let candidateDestinations = job.outputURLs.isEmpty
                ? (job.destinationURL.map { [$0] } ?? [])
                : job.outputURLs
            let destinations: [URL] = {
                guard job.state == .completed || isCompletedWithWarnings else { return [] }
                return candidateDestinations.filter { FileManager.default.fileExists(atPath: $0.path) }
            }()
            if !destinations.isEmpty {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(destinations)
                }
                if let firstDestination = destinations.first {
                    Button("Open Converted File") {
                        NSWorkspace.shared.open(firstDestination)
                    }
                }
                Divider()
                Button("Copy Output Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(destinations.map(\.path).joined(separator: "\n"), forType: .string)
                }
            }

            Button("Copy Source Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.sourceURL.path, forType: .string)
            }

            Divider()

            if job.state.isCancellable {
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.filename), \(job.sourceFormat) to \(job.targetFormat)")
        .accessibilityValue(statusDescription)
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
        case .awaitingCollision: return "Waiting for overwrite decision"
        case .converting:
            if let fps = job.progress.currentFPS, fps > 0 {
                return String(format: "Encoding (%.1f fps)", fps)
            }
            return "Converting..."
        case .finalizing: return "Writing to destination..."
        case .completed: return "Converted successfully"
        case .completedWithWarnings(let warnings): return "Converted with \(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
        case .failed(let error): return error.localizedDescription
        case .skipped(let reason): return "Skipped: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .queued: return .secondary
        case .preparing, .converting, .finalizing, .awaitingCollision: return .primary
        case .completed: return .green
        case .completedWithWarnings: return .orange
        case .failed: return .red
        case .cancelled, .skipped: return .secondary
        }
    }

    private var isCompletedWithWarnings: Bool {
        if case .completedWithWarnings = job.state { return true }
        return false
    }
}
