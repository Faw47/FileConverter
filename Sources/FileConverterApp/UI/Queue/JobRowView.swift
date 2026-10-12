import SwiftUI
import FileConverterCore
import AppKit

public struct JobRowView: View {
    public let job: ConversionJob
    public var isSelected: Bool = false
    public var onSelect: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var showingErrorDetails = false
    @State private var showingWarningDetails = false
    @State private var verifiedDestinations: [URL] = []

    public init(job: ConversionJob, isSelected: Bool = false, onSelect: (() -> Void)? = nil) {
        self.job = job
        self.isSelected = isSelected
        self.onSelect = onSelect
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
                    ProgressView()
                        .controlSize(.small)
                        .help("Finalizing conversion")
                        .accessibilityLabel("Finalizing conversion for \(job.filename)")

                case .completed:
                    if !verifiedDestinations.isEmpty {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting(verifiedDestinations)
                        }) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal converted file in Finder")
                    } else if hasExpectedDestinations {
                        Label("Output unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("The conversion completed, but the expected output file is no longer available.")
                            .accessibilityLabel("Converted output unavailable for \(job.filename)")
                    }

                case .completedWithWarnings:
                    if !job.warnings.isEmpty {
                        Button(action: {
                            showingWarningDetails = true
                        }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Show warnings")
                        .accessibilityLabel("Show conversion warnings")
                        .popover(isPresented: $showingWarningDetails) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Conversion Warnings")
                                    .font(.headline)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(job.warnings.enumerated()), id: \.offset) { _, warning in
                                            HStack(alignment: .top, spacing: 6) {
                                                Text("•")
                                                Text(warning)
                                                    .font(.subheadline)
                                            }
                                        }
                                    }
                                }
                                .frame(maxHeight: 220)
                            }
                            .padding()
                            .frame(minWidth: 280, idealWidth: 360)
                        }
                    }

                    if !verifiedDestinations.isEmpty {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting(verifiedDestinations)
                        }) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal converted file in Finder")
                    } else if hasExpectedDestinations {
                        Label("Output unavailable", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("The conversion completed, but the expected output file is no longer available.")
                            .accessibilityLabel("Converted output unavailable for \(job.filename)")
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

                if job.state.isTerminal {
                    Button(action: {
                        ConversionQueue.shared.removeJob(id: job.id)
                    }) {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove \(job.filename) from queue")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : (isHovered ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12)), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .onHover { isHovered = $0 }
        .onAppear {
            updateVerifiedDestinations()
        }
        .onChange(of: job.state) { _, _ in
            updateVerifiedDestinations()
        }
        .contextMenu {
            if !verifiedDestinations.isEmpty {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(verifiedDestinations)
                }
                if let firstDestination = verifiedDestinations.first {
                    Button("Open Converted File") {
                        NSWorkspace.shared.open(firstDestination)
                    }
                }
                Divider()
                Button("Copy Output Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(verifiedDestinations.map(\.path).joined(separator: "\n"), forType: .string)
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
            } else if job.state == .cancelled || { if case .skipped = job.state { return true }; return false }() {
                Button("Restart Conversion") {
                    ConversionQueue.shared.retryJob(id: job.id)
                }
            }

            if job.state.isTerminal {
                Divider()
                Button("Remove from Queue") {
                    ConversionQueue.shared.removeJob(id: job.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.filename), \(job.sourceFormat) to \(job.targetFormat)")
        .accessibilityValue(statusDescription)
    }

    private func updateVerifiedDestinations() {
        guard job.state == .completed || isCompletedWithWarnings else {
            verifiedDestinations = []
            return
        }
        let candidates = job.outputURLs.isEmpty
            ? (job.destinationURL.map { [$0] } ?? [])
            : job.outputURLs
        if verifiedDestinations.isEmpty && !candidates.isEmpty {
            verifiedDestinations = candidates
        }
        Task.detached(priority: .utility) {
            let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
            await MainActor.run {
                self.verifiedDestinations = existing
            }
        }
    }

    private var hasExpectedDestinations: Bool {
        !job.outputURLs.isEmpty || job.destinationURL != nil
    }

    private var iconColor: Color {
        job.preset.category.color
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
        case .preparing, .converting, .finalizing: return .primary
        case .awaitingCollision: return .orange
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
