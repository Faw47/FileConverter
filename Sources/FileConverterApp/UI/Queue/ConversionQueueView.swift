import AppKit
import FileConverterCore
import QuickLook
import SwiftUI

/// Batches of conversions in submission order.
struct QueueBatch: Identifiable {
    let id: UUID
    let jobs: [ConversionJob]

    var isActive: Bool { jobs.contains { !$0.state.isTerminal } }
    var completed: Int { jobs.filter { $0.state == .completed || { if case .completedWithWarnings = $0.state { return true }; return false }($0) }.count }
    var failed: Int { jobs.filter { if case .failed = $0.state { return true }; return false }.count }
    var date: Date { jobs.first?.batchCreatedAt ?? .distantPast }

    var summary: String {
        let formats = Set(jobs.map(\.targetFormat))
        let target = formats.count == 1 ? " to \(formats.first ?? "")" : ""
        var parts = ["\(completed) of \(jobs.count) converted\(target)"]
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }

    static func group(_ jobs: [ConversionJob]) -> [QueueBatch] {
        var order: [UUID] = []
        var members: [UUID: [ConversionJob]] = [:]
        for job in jobs {
            if members[job.batchID] == nil { order.append(job.batchID) }
            members[job.batchID, default: []].append(job)
        }
        return order.map { QueueBatch(id: $0, jobs: members[$0] ?? []) }
    }
}

/// The queue's batches and counts, worked out once per change to the job list
/// rather than several times per redraw (progress redraws up to 10 times a second).
final class QueueLayoutCache {
    struct Layout {
        var batches: [QueueBatch] = []
        var current: [QueueBatch] = []
        var earlier: [QueueBatch] = []
    }

    /// Kept so the queue's next change copies the array, giving it new storage.
    private var jobs: [ConversionJob] = []
    private var storage: UnsafeRawPointer?
    private var cached = Layout()

    func layout(for jobs: [ConversionJob]) -> Layout {
        let address = jobs.withUnsafeBufferPointer { $0.baseAddress.map(UnsafeRawPointer.init) }
        if address == storage, jobs.count == self.jobs.count, address != nil { return cached }
        self.jobs = jobs
        storage = address
        let all = QueueBatch.group(jobs)
        let active = all.filter(\.isActive)
        let current = active.isEmpty ? (all.last.map { [$0] } ?? []) : active
        let currentIDs = Set(current.map(\.id))
        cached = Layout(batches: all, current: current, earlier: all.filter { !currentIDs.contains($0.id) }.reversed())
        return cached
    }
}

public struct ConversionQueueView: View {
    @ObservedObject var queue = ConversionQueue.shared
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var appState: AppState

    @State private var selection = Set<UUID>()
    @State private var expandedBatches = Set<UUID>()
    @State private var quickLookURL: URL?
    @State private var showingCancelConfirmation = false
    /// Conversions Esc asked to cancel; empty when nothing is being asked.
    @State private var escapeCancelIDs = Set<UUID>()
    @State private var revealErrorMessage: String?
    @State private var layoutCache = QueueLayoutCache()

    public init() {}

    // MARK: - Grouping

    private var batches: [QueueBatch] { layoutCache.layout(for: queue.jobs).batches }

    /// Batches with work left; when everything is done, the newest batch.
    private var currentBatches: [QueueBatch] { layoutCache.layout(for: queue.jobs).current }

    private var earlierBatches: [QueueBatch] { layoutCache.layout(for: queue.jobs).earlier }

    private var currentJobs: [ConversionJob] { currentBatches.flatMap(\.jobs) }

    private func job(_ id: UUID) -> ConversionJob? { queue.jobs.first { $0.id == id } }

    // MARK: - Body

    public var body: some View {
        list
            .navigationSubtitle(statusText)
            .toolbar { queueToolbar }
        .confirmationDialog(
            "Cancel \(queue.cancelableCount) conversions?",
            isPresented: $showingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel Conversions", role: .destructive) { queue.cancelAll() }
            Button("Keep Converting", role: .cancel) {}
        } message: {
            Text("Files already converted are kept.")
        }
        .alert("Cannot Show File", isPresented: Binding(
            get: { revealErrorMessage != nil },
            set: { if !$0 { revealErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(revealErrorMessage ?? "")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if !currentJobs.isEmpty {
                Section {
                    ForEach(currentJobs) { job in
                        JobRowView(job: job).tag(job.id)
                    }
                    .onMove(perform: moveCurrent)
                }
            }
            if !earlierBatches.isEmpty {
                Section("Earlier") {
                    ForEach(earlierBatches) { batch in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedBatches.contains(batch.id) },
                            set: { if $0 { expandedBatches.insert(batch.id) } else { expandedBatches.remove(batch.id) } }
                        )) {
                            ForEach(batch.jobs) { job in
                                JobRowView(job: job).tag(job.id)
                            }
                        } label: {
                            HStack {
                                Text(batch.summary)
                                Spacer()
                                Text(batch.date, style: .relative)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            open(ids)
        }
        .onDeleteCommand { removeFinished(selection) }
        .onKeyPress(.space) {
            guard quickLookURL != nil || !quickLookItems.isEmpty else { return .ignored }
            toggleQuickLook()
            return .handled
        }
        // As in Finder: ⌘↓ opens, ⌘R shows the file in Finder.
        .onKeyPress(keys: [.downArrow], phases: .down) { press in
            guard press.modifiers.contains(.command), !outputs(of: selection).isEmpty else { return .ignored }
            open(selection)
            return .handled
        }
        .onKeyPress(characters: ["r"]) { press in
            guard press.modifiers == .command, !selection.isEmpty else { return .ignored }
            reveal(selection)
            return .handled
        }
        .onKeyPress(.escape) {
            let cancellable = selection.filter { job($0)?.state.isCancellable == true }
            guard !cancellable.isEmpty else { return .ignored }
            escapeCancelIDs = cancellable
            return .handled
        }
        .confirmationDialog(
            escapeCancelTitle,
            isPresented: Binding(
                get: { !escapeCancelIDs.isEmpty },
                set: { if !$0 { escapeCancelIDs.removeAll() } }
            ),
            titleVisibility: .visible
        ) {
            let ids = escapeCancelIDs
            Button(ids.count == 1 ? "Cancel Conversion" : "Cancel Conversions", role: .destructive) {
                for id in ids where job(id)?.state.isCancellable == true {
                    queue.cancelJob(id: id)
                }
            }
            Button("Keep Converting", role: .cancel) {}
        } message: {
            Text("Files already converted are kept.")
        }
        .quickLookPreview($quickLookURL, in: quickLookItems)
    }

    private var escapeCancelTitle: String {
        if escapeCancelIDs.count == 1, let only = escapeCancelIDs.first.flatMap(job) {
            return "Cancel converting “\(only.filename)”?"
        }
        return Inflect.string("Cancel ^[\(escapeCancelIDs.count) conversion](inflect: true)?")
    }

    // MARK: - Status and toolbar

    private struct Counts {
        var converting = 0, waiting = 0, completed = 0, failed = 0, total = 0
    }

    private var counts: Counts {
        let jobs = currentBatches.flatMap(\.jobs)
        return Counts(
            converting: jobs.filter { $0.state.isActive }.count,
            waiting: jobs.filter { $0.state == .queued || $0.state == .awaitingCollision }.count,
            completed: currentBatches.reduce(0) { $0 + $1.completed },
            failed: currentBatches.reduce(0) { $0 + $1.failed },
            total: jobs.count
        )
    }

    /// Shown under the window title, like Finder's item count.
    private var statusText: String {
        let c = counts
        var text = headerTitle(converting: c.converting, waiting: c.waiting, completed: c.completed, failed: c.failed, total: c.total)
        if let progress = ConversionQueue.activeBatchProgress(queue.jobs), c.converting + c.waiting > 0 {
            text += " · \(Int(progress.fraction * 100))%"
        }
        if settings.enableNotifications && settings.notificationAuthorizationState == .denied {
            text += " · Notifications are off in System Settings"
        }
        return text
    }

    private var hasRetryableFailures: Bool {
        queue.jobs.contains { if case .failed = $0.state { return !$0.isFromHistory }; return false }
    }

    /// Always the same buttons in the same places, dimmed when they don't
    /// apply, so nothing shifts as conversions start and finish. Groups
    /// become separate glass capsules on macOS 26 and later.
    @ToolbarContentBuilder
    private var queueToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                if queue.isPaused { queue.resume() } else { queue.pause() }
            } label: {
                Label(queue.isPaused ? "Resume" : "Pause", systemImage: queue.isPaused ? "play.fill" : "pause.fill")
            }
            .help(queue.isPaused ? "Start the waiting conversions (⌥⌘P)" : "Finish the current files, then wait (⌥⌘P)")
            .disabled(!queue.isPaused && counts.waiting == 0)

            Button {
                if queue.cancelableCount > 1 { showingCancelConfirmation = true } else { queue.cancelAll() }
            } label: {
                Label("Cancel All", systemImage: "stop.fill")
            }
            .help("Stop every conversion that hasn't finished (⌘.)")
            .disabled(queue.cancelableCount == 0)
        }
        toolbarGap
        ToolbarItemGroup {
            Button(action: retryAllFailed) {
                Label("Retry Failed", systemImage: "arrow.clockwise")
            }
            .help("Try every failed conversion again (⇧⌘R)")
            .disabled(!hasRetryableFailures)

            Button {
                reveal(Set(currentBatches.flatMap(\.jobs).map(\.id)))
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show this batch's converted files in Finder")
            .disabled(counts.completed == 0)

            Button {
                queue.clearCompleted()
                selection.removeAll()
            } label: {
                Label("Clear Finished", systemImage: "checklist.checked")
            }
            .help("Remove finished conversions from the list (⌘K)")
            .disabled(!queue.hasClearableJobs)
        }
        toolbarGap
        ToolbarItem { AddFilesButton() }
    }

    @ToolbarContentBuilder
    private var toolbarGap: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
        }
    }

    private func headerTitle(converting: Int, waiting: Int, completed: Int, failed: Int, total: Int) -> String {
        if queue.isPaused && waiting > 0 { return "Paused · \(waiting) waiting" }
        if converting > 0 || waiting > 0 {
            var parts: [String] = []
            if converting > 0 { parts.append("Converting \(converting)") }
            if waiting > 0 { parts.append("\(waiting) waiting") }
            parts.append("\(completed) of \(total) done")
            return parts.joined(separator: " · ")
        }
        if failed > 0 { return "\(completed) converted, \(failed) failed" }
        return total == 1 ? (completed == 1 ? "Converted" : "Finished") : "\(completed) of \(total) converted"
    }

    // MARK: - Actions

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let jobs = ids.compactMap(job)
        let outputs = outputs(of: ids)
        if !outputs.isEmpty {
            Button("Show in Finder") { reveal(ids) }
            Button(outputs.count == 1 ? "Open" : "Open \(outputs.count) Files") { open(ids) }
            Button("Quick Look") { quickLookURL = outputs.first }
            Button("Copy Output Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(outputs.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
        }
        Button("Show Original in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(jobs.map(\.sourceURL).filter { FileManager.default.fileExists(atPath: $0.path) })
        }
        if jobs.contains(where: \.state.isCancellable) {
            Button("Cancel") { jobs.filter(\.state.isCancellable).forEach { queue.cancelJob(id: $0.id) } }
        }
        let retryable = jobs.filter(\.canConvertAgain)
        if !retryable.isEmpty {
            Button("Convert Again") { queue.retryJobs(ids: retryable.map(\.id)) }
        }
        // Older history rows don't know the preset they used.
        let needPreset = jobs.filter { $0.isFromHistory && !$0.canConvertAgain && $0.state.isTerminal && $0.state != .completed }
        if !needPreset.isEmpty {
            Button("Convert Again With…") {
                WorkflowPresentationCoordinator.shared.enqueue(.batch(urls: needPreset.map(\.sourceURL), excludedCount: 0))
            }
        }
        if jobs.contains(where: \.state.isTerminal) {
            Divider()
            Button("Remove from List") { removeFinished(ids) }
        }
    }

    private func outputs(of ids: Set<UUID>) -> [URL] {
        ids.compactMap(job)
            .filter { $0.state == .completed || { if case .completedWithWarnings = $0.state { return true }; return false }($0) }
            .flatMap { $0.outputURLs.isEmpty ? ($0.destinationURL.map { [$0] } ?? []) : $0.outputURLs }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var quickLookItems: [URL] { outputs(of: selection) }

    private func toggleQuickLook() {
        quickLookURL = quickLookURL == nil ? quickLookItems.first : nil
    }

    private func reveal(_ ids: Set<UUID>) {
        let urls = outputs(of: ids)
        guard !urls.isEmpty else {
            if !ids.isEmpty { revealErrorMessage = "The converted file was moved or deleted." }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func open(_ ids: Set<UUID>) {
        for url in outputs(of: ids) {
            NSWorkspace.shared.open(url)
        }
    }

    private func removeFinished(_ ids: Set<UUID>) {
        for id in ids where job(id)?.state.isTerminal == true {
            queue.removeJob(id: id)
        }
        selection.subtract(ids)
    }

    private func retryAllFailed() {
        for job in queue.jobs where !job.isFromHistory {
            if case .failed = job.state { queue.retryJob(id: job.id) }
        }
    }

    private func moveCurrent(from source: IndexSet, to destination: Int) {
        let rows = currentJobs
        let moving = source.map { rows[$0] }.filter { $0.state == .queued }
        let before = destination < rows.count ? rows[destination].id : nil
        for job in moving {
            queue.moveQueuedJob(id: job.id, before: before)
        }
    }
}
