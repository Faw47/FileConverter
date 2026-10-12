import AppKit
import Combine
import FileConverterCore

/// Shows conversion progress on the Dock icon, so Finder conversions are
/// visible even when no window is open: a badge with the number of files
/// still to convert, a progress bar while converting, and "!" when something
/// failed since the app was last brought forward.
@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    private var cancellables = Set<AnyCancellable>()
    private var failedSinceActivation = false
    private var lastFailedCount = 0
    private let progressView = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    func start() {
        let queue = ConversionQueue.shared
        queue.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] jobs in self?.update(jobs) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.failedSinceActivation = false
                self?.update(ConversionQueue.shared.jobs)
            }
            .store(in: &cancellables)
    }

    private func update(_ jobs: [ConversionJob]) {
        let failed = jobs.filter { if case .failed = $0.state { return true }; return false }.count
        if failed > lastFailedCount, !NSApp.isActive {
            failedSinceActivation = true
        }
        lastFailedCount = failed

        let tile = NSApp.dockTile
        if let progress = ConversionQueue.activeBatchProgress(jobs) {
            tile.badgeLabel = "\(progress.remaining)"
            progressView.fraction = progress.fraction
            tile.contentView = progressView
        } else {
            tile.badgeLabel = failedSinceActivation ? "!" : nil
            tile.contentView = nil
        }
        tile.display()
    }
}

/// App icon with a progress bar along the bottom.
private final class DockProgressView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let bar = NSRect(x: bounds.width * 0.1, y: bounds.height * 0.08, width: bounds.width * 0.8, height: bounds.height * 0.1)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        let inset = bar.insetBy(dx: 2, dy: 2)
        var filled = inset
        filled.size.width = inset.width * CGFloat(max(0, min(1, fraction)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: filled.height / 2, yRadius: filled.height / 2).fill()
    }
}
