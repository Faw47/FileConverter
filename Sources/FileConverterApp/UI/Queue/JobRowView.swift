import AppKit
import FileConverterCore
import SwiftUI

/// One conversion in the queue. Selection, keyboard handling, and the
/// context menu belong to the enclosing list.
public struct JobRowView: View {
    public let job: ConversionJob
    @State private var isHovered = false
    @State private var showingErrorDetails = false
    @State private var showingWarningDetails = false
    @State private var existingOutputs: [URL] = []
    @State private var sizeSummary: String?

    public init(job: ConversionJob) {
        self.job = job
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.sourceURL.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.filename)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("→ \(job.targetFormat)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                statusLine
            }

            Spacer(minLength: 8)

            if job.state.isActive {
                ProgressView(value: job.progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .accessibilityLabel("Progress")
                    .accessibilityValue(job.progress.percentageString)
            }

            actions
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: job.state) { await refreshOutputs() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.filename), \(job.sourceFormat) to \(job.targetFormat)")
        .accessibilityValue(statusDescription)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            Text(statusDescription)
                .foregroundStyle(statusColor)
                .lineLimit(2)
            if job.state.isActive, let eta = job.progress.formattedTimeRemaining {
                Text("· \(eta) left")
                    .foregroundStyle(.secondary)
            }
            if isFinishedSuccessfully, let sizeSummary {
                Text("· \(sizeSummary)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.caption)
    }

    private var isFinishedSuccessfully: Bool {
        switch job.state {
        case .completed, .completedWithWarnings: return true
        default: return false
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .queued, .preparing, .awaitingCollision, .converting:
                iconButton("xmark.circle.fill", help: "Cancel", label: "Cancel converting \(job.filename)") {
                    ConversionQueue.shared.cancelJob(id: job.id)
                }
            case .finalizing:
                ProgressView().controlSize(.small)
            case .completed, .completedWithWarnings:
                if case .completedWithWarnings(let warnings) = job.state {
                    iconButton("exclamationmark.triangle.fill", tint: .orange, help: "Show warnings", label: "Show warnings for \(job.filename)") {
                        showingWarningDetails = true
                    }
                    .popover(isPresented: $showingWarningDetails) {
                        detailsPopover(title: "Converted with Warnings", body: warnings.map { "• \($0)" }.joined(separator: "\n"), technical: nil)
                    }
                }
                if !existingOutputs.isEmpty {
                    iconButton("magnifyingglass.circle.fill", tint: .accentColor, help: "Show in Finder", label: "Show \(job.filename) in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(existingOutputs)
                    }
                } else if !job.outputURLs.isEmpty {
                    Text("File moved or deleted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                Button("Details") { showingErrorDetails = true }
                    .controlSize(.small)
                    .accessibilityLabel("Show why \(job.filename) failed")
                    .popover(isPresented: $showingErrorDetails) {
                        detailsPopover(title: "Conversion Failed", body: error.localizedDescription + (error.recoverySuggestion.map { "\n\n\($0)" } ?? ""), technical: error.technicalDetails)
                    }
                if !job.isFromHistory {
                    iconButton("arrow.clockwise.circle.fill", help: "Try again", label: "Try converting \(job.filename) again") {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }
                }
            case .cancelled, .skipped:
                if !job.isFromHistory {
                    iconButton("arrow.clockwise.circle.fill", help: "Convert again", label: "Convert \(job.filename) again") {
                        ConversionQueue.shared.retryJob(id: job.id)
                    }
                }
            }

            if job.state.isTerminal {
                // Shown on hover only, so it is not confused with Cancel.
                iconButton("xmark", help: "Remove from list", label: "Remove \(job.filename) from the list") {
                    ConversionQueue.shared.removeJob(id: job.id)
                }
                .opacity(isHovered ? 1 : 0)
            }
        }
    }

    private func iconButton(
        _ systemImage: String,
        tint: Color = .secondary,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }

    private func detailsPopover(title: String, body: String, technical: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let technical, technical != body {
                Divider()
                ScrollView {
                    Text(technical)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(technical, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding()
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 520)
    }

    // MARK: - Outputs

    private func refreshOutputs() async {
        guard isFinishedSuccessfully else {
            existingOutputs = []
            sizeSummary = nil
            return
        }
        let candidates = job.outputURLs.isEmpty ? (job.destinationURL.map { [$0] } ?? []) : job.outputURLs
        let source = job.sourceURL
        let started = job.startedAt
        let finished = job.finishedAt
        let result = await Task.detached(priority: .utility) { () -> ([URL], String?) in
            let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
            return (existing, Self.sizeSummary(source: source, outputs: existing, started: started, finished: finished))
        }.value
        existingOutputs = result.0
        sizeSummary = result.1
    }

    /// "2.1 MB → 640 KB (−70%) · 4 s"
    nonisolated static func sizeSummary(source: URL, outputs: [URL], started: Date?, finished: Date?) -> String? {
        func size(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let sourceSize = size(source)
        let outputSize = outputs.reduce(Int64(0)) { $0 + size($1) }
        var parts: [String] = []
        if outputSize > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var text = outputs.count > 1 ? "\(outputs.count) files, \(formatter.string(fromByteCount: outputSize))" : formatter.string(fromByteCount: outputSize)
            if sourceSize > 0 {
                text = "\(formatter.string(fromByteCount: sourceSize)) → \(text)"
                let change = Int((Double(outputSize) / Double(sourceSize) - 1) * 100)
                if change != 0 { text += " (\(change > 0 ? "+" : "−")\(abs(change))%)" }
            }
            parts.append(text)
        }
        if let started, let finished {
            let seconds = max(0, finished.timeIntervalSince(started))
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
            if let elapsed = formatter.string(from: max(1, seconds)) { parts.append(elapsed) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Text

    private var statusDescription: String {
        switch job.state {
        case .queued:
            return job.waitingForDestinationKey != nil ? "Waiting for another file with the same name" : "Waiting"
        case .preparing:
            return BackendReadinessGate.shared.ready || ConversionCoordinator.isGuaranteedNative(job.preset)
                ? "Preparing…"
                : "Waiting for tool check…"
        case .awaitingCollision: return "A file with this name already exists — choose what to do"
        case .converting:
            if let fps = job.progress.currentFPS, fps > 0 {
                return String(format: "Converting (%.0f fps)", fps)
            }
            return "Converting…"
        case .finalizing: return "Saving…"
        case .completed: return "Converted"
        case .completedWithWarnings(let warnings): return Inflect.string("Converted with ^[\(warnings.count) warning](inflect: true)")
        case .failed(let error): return error.localizedDescription
        case .skipped(let reason): return "Skipped: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .queued, .cancelled, .skipped: return .secondary
        case .preparing, .converting, .finalizing: return .primary
        case .awaitingCollision, .completedWithWarnings: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}
