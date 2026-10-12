import SwiftUI
import FileConverterCore
import AppKit

public struct ConversionQueueView: View {
    @ObservedObject var queue = ConversionQueue.shared
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var appState: AppState

    @State private var selectedJobID: UUID? = nil
    @State private var showingCancelConfirmation = false
    @State private var showingRevealError = false
    @State private var revealErrorMessage = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Overall Header Bar
            if !queue.jobs.isEmpty {
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                Divider()
            }

            if queue.jobs.isEmpty {
                emptyQueueView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.jobs) { job in
                            JobRowView(
                                job: job,
                                isSelected: job.id == selectedJobID,
                                onSelect: { selectedJobID = job.id }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
        .focusable(!queue.jobs.isEmpty)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            selectPrevious()
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectNext()
            return .handled
        }
        .onKeyPress(.return) {
            revealSelected()
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelectedTerminal()
            return .handled
        }
        .onKeyPress(.escape) {
            cancelSelectedActive()
            return .handled
        }
        .onChange(of: queue.jobs.map(\.id)) { _, ids in
            if let current = selectedJobID, !ids.contains(current) {
                selectedJobID = ids.first
            } else if selectedJobID == nil {
                selectedJobID = ids.first
            }
        }
        .confirmationDialog(
            "Cancel All Active Conversions?",
            isPresented: $showingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel \(queue.cancelableCount) Conversions", role: .destructive) {
                queue.cancelAll()
            }
            Button("Keep Converting", role: .cancel) {}
        } message: {
            Text("This will interrupt \(queue.cancelableCount) active conversions. Partial progress will be discarded.")
        }
        .alert("Reveal in Finder Failed", isPresented: $showingRevealError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(revealErrorMessage)
        }
    }

    private var batchSummaryText: String {
        let total = queue.jobs.count
        guard total > 0 else { return "" }
        let terminal = queue.completedCount + queue.failedCount + queue.cancelledCount + queue.skippedCount
        let allTerminal = (terminal == total)

        if allTerminal {
            if queue.completedCount == total {
                return "100% Completed (\(total) of \(total))"
            } else {
                return "Batch Finished: \(queue.completedCount) of \(total) succeeded"
            }
        } else {
            return "\(queue.completedCount) of \(total) complete"
        }
    }

    private var activeJobInfo: (index: Int, total: Int, job: ConversionJob)? {
        guard let activeIndex = queue.jobs.firstIndex(where: { $0.state.isActive }) else { return nil }
        return (index: activeIndex + 1, total: queue.jobs.count, job: queue.jobs[activeIndex])
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(batchSummaryText)
                        .font(.system(size: 13, weight: .semibold))

                    if queue.failedCount > 0 {
                        Text("(\(queue.failedCount) failed)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    if queue.cancelledCount > 0 {
                        Text("(\(queue.cancelledCount) cancelled)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if queue.skippedCount > 0 {
                        Text("(\(queue.skippedCount) skipped)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if let current = activeJobInfo {
                    HStack(spacing: 6) {
                        Text("Item \(current.index) of \(current.total): \(current.job.filename)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text("(\(current.job.progress.percentageString))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    ProgressView(value: queue.completionProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                        .accessibilityLabel("Overall batch progress")
                        .accessibilityValue(batchSummaryText)

                    if settings.enableNotifications && settings.notificationAuthorizationState == .denied {
                        HStack(spacing: 4) {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text("Notifications blocked")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .help("System notifications are disabled in macOS Settings. Open Settings to enable.")
                    }
                }
            }

            Spacer()

            if queue.completedCount > 0 {
                Button("Reveal Batch") {
                    revealBatch()
                }
                .controlSize(.small)
                .help("Reveal all completed output files in Finder")
                .accessibilityLabel("Reveal all completed output files in Finder")
            }

            if queue.cancelableCount > 0 {
                Button("Cancel All Active") {
                    if queue.cancelableCount > 1 {
                        showingCancelConfirmation = true
                    } else {
                        queue.cancelAll()
                    }
                }
                .controlSize(.small)
                .help("Cancel all active conversions")
                .accessibilityLabel("Cancel all active conversions")
            }

            if queue.failedCount > 0 {
                Button("Retry Failed (\(queue.failedCount))") {
                    retrySelectedOrFailed()
                }
                .controlSize(.small)
                .help("Retry failed conversions (⌘R)")
                .accessibilityLabel("Retry failed conversions")
            }

            if queue.hasClearableJobs {
                Button("Clear Finished") {
                    queue.clearCompleted()
                    selectedJobID = queue.jobs.first?.id
                }
                .controlSize(.small)
                .help("Clear finished jobs (⌘K)")
                .accessibilityLabel("Clear finished jobs")
            }
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.6))
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("No Conversions in Progress")
                    .font(.system(size: 15, weight: .semibold))

                Text("Right-click any file in Finder and select **File Converter**, or drop files here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No Conversions in Progress. Drag and drop files here to begin.")
    }

    // MARK: - Keyboard Actions

    private func selectPrevious() {
        guard let current = selectedJobID, let index = queue.jobs.firstIndex(where: { $0.id == current }) else {
            selectedJobID = queue.jobs.last?.id
            return
        }
        if index > 0 {
            selectedJobID = queue.jobs[index - 1].id
        }
    }

    private func selectNext() {
        guard let current = selectedJobID, let index = queue.jobs.firstIndex(where: { $0.id == current }) else {
            selectedJobID = queue.jobs.first?.id
            return
        }
        if index < queue.jobs.count - 1 {
            selectedJobID = queue.jobs[index + 1].id
        }
    }

    private func revealSelected() {
        guard let current = selectedJobID,
              let job = queue.jobs.first(where: { $0.id == current }) else { return }
        let outputs = job.outputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !outputs.isEmpty else {
            revealErrorMessage = "Output file for \(job.filename) could not be found."
            showingRevealError = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    private func revealBatch() {
        let allOutputs = queue.jobs
            .filter { $0.state.isTerminal }
            .flatMap(\.outputURLs)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !allOutputs.isEmpty else {
            revealErrorMessage = "No completed output files could be located in Finder."
            showingRevealError = true
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(allOutputs)
    }

    private func retrySelectedOrFailed() {
        if let current = selectedJobID,
           let job = queue.jobs.first(where: { $0.id == current }),
           case .failed = job.state {
            queue.retryJob(id: job.id)
            return
        }
        let failedJobs = queue.jobs.filter {
            if case .failed = $0.state { return true }; return false
        }
        for job in failedJobs {
            queue.retryJob(id: job.id)
        }
    }

    private func deleteSelectedTerminal() {
        guard let current = selectedJobID,
              let job = queue.jobs.first(where: { $0.id == current }),
              job.state.isTerminal else { return }
        queue.removeJob(id: current)
        selectedJobID = queue.jobs.first?.id
    }

    /// Esc cancels only the selected conversion. "Cancel All" keeps its
    /// own confirmation.
    private func cancelSelectedActive() {
        guard let current = selectedJobID,
              let job = queue.jobs.first(where: { $0.id == current }),
              job.state.isCancellable else { return }
        queue.cancelJob(id: current)
    }
}
