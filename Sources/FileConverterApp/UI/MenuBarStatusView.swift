import AppKit
import FileConverterCore
import SwiftUI

/// Menu bar menu: what is converting right now, and quick actions.
struct MenuBarStatusView: View {
    @ObservedObject var queue: ConversionQueue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var activeJobs: [ConversionJob] {
        queue.jobs.filter { !$0.state.isTerminal }
    }

    /// The newest finished job's outputs. Whether they still exist is checked
    /// when the button is used, not on every redraw.
    private var lastOutputs: [URL] {
        guard let job = queue.jobs.last(where: { $0.state == .completed || { if case .completedWithWarnings = $0.state { return true }; return false }($0) }) else {
            return []
        }
        let candidates = job.outputURLs.isEmpty ? (job.destinationURL.map { [$0] } ?? []) : job.outputURLs
        return candidates
    }

    /// "Converting 3 files · 42% done" for everything running or waiting.
    private var overallStatus: String? {
        guard let progress = ConversionQueue.activeBatchProgress(queue.jobs) else { return nil }
        let unfinished = activeJobs.count
        let verb = queue.isPaused ? "Paused" : "Converting"
        return Inflect.string("\(verb) ^[\(unfinished) file](inflect: true) · \(Int(progress.fraction * 100))% done")
    }

    var body: some View {
        if activeJobs.isEmpty {
            Text("No conversions running")
        } else {
            if let overallStatus {
                Text(overallStatus)
                Divider()
            }
            ForEach(activeJobs.prefix(8)) { job in
                Text("\(job.filename) — \(job.state == .queued ? "Waiting" : job.progress.percentageString)")
            }
            if activeJobs.count > 8 {
                Text("and \(activeJobs.count - 8) more")
            }
        }
        Divider()
        Button("Show Last Converted File") {
            let existing = lastOutputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
        }
        .disabled(lastOutputs.isEmpty)
        if queue.isPaused || !activeJobs.isEmpty {
            Button(queue.isPaused ? "Resume Queue" : "Pause Queue") {
                if queue.isPaused { queue.resume() } else { queue.pause() }
            }
        }
        Divider()
        Button("Open File Converter") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        // Goes through applicationShouldTerminate, which asks first when
        // conversions are unfinished.
        Button("Quit File Converter") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
