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

    private var lastOutputs: [URL] {
        guard let job = queue.jobs.last(where: { $0.state == .completed || { if case .completedWithWarnings = $0.state { return true }; return false }($0) }) else {
            return []
        }
        return job.outputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        if activeJobs.isEmpty {
            Text("No conversions running")
        } else {
            ForEach(activeJobs.prefix(8)) { job in
                Text("\(job.filename) — \(job.state == .queued ? "Waiting" : job.progress.percentageString)")
            }
            if activeJobs.count > 8 {
                Text("and \(activeJobs.count - 8) more")
            }
        }
        Divider()
        Button("Show Last Converted File") {
            NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
        }
        .disabled(lastOutputs.isEmpty)
        if queue.isPaused || !activeJobs.isEmpty {
            Button(queue.isPaused ? "Resume Queue" : "Pause Queue") {
                if queue.isPaused { queue.resume() } else { queue.pause() }
            }
        }
        Divider()
        Button("Open File Converter") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
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
