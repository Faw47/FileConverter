import Foundation
import Combine

/// Represents a distinct modal workflow presented to the user.
public enum WorkflowPresentationItem: Identifiable, Equatable, Sendable {
    case batch(id: UUID = UUID(), urls: [URL], excludedCount: Int)
    case pdfCompress(id: UUID = UUID(), urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?)
    case pdfSplit(id: UUID = UUID(), urls: [URL], preset: ConversionPreset, leases: [SecurityScopedLease]?)
    case conflictResolution(id: UUID = UUID(), conflicts: [ConversionQueue.CollisionConflict])

    public var id: UUID {
        switch self {
        case .batch(let id, _, _): return id
        case .pdfCompress(let id, _, _, _): return id
        case .pdfSplit(let id, _, _, _): return id
        case .conflictResolution(let id, _): return id
        }
    }

    public static func == (lhs: WorkflowPresentationItem, rhs: WorkflowPresentationItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Central FIFO presentation coordinator for all modal workflows, sheets, and dialogs.
/// Enforces FIFO presentation so concurrent drag/drop, Finder IPC, and PDF workflows
/// never replace an active sheet or lose queued batches.
@MainActor
public final class WorkflowPresentationCoordinator: ObservableObject {
    public static let shared = WorkflowPresentationCoordinator()

    @Published public private(set) var currentPresentation: WorkflowPresentationItem?
    @Published public private(set) var pendingQueue: [WorkflowPresentationItem] = []
    @Published public var isOpenPanelPresented = false
    @Published public var isAddFilesQueued = false

    public init() {}

    public var isPresenting: Bool {
        currentPresentation != nil || isOpenPanelPresented
    }

    public var pendingCount: Int {
        pendingQueue.count
    }

    public func enqueue(_ item: WorkflowPresentationItem) {
        if currentPresentation == nil && !isOpenPanelPresented {
            currentPresentation = item
        } else {
            pendingQueue.append(item)
        }
    }

    public func dismissCurrent() {
        currentPresentation = nil
        advanceQueue()
    }

    public func queueAddFiles() {
        guard isPresenting else { return }
        isAddFilesQueued = true
    }

    public func advanceQueue() {
        guard currentPresentation == nil, !isOpenPanelPresented else { return }
        if !pendingQueue.isEmpty {
            currentPresentation = pendingQueue.removeFirst()
        } else if isAddFilesQueued {
            isAddFilesQueued = false
            NotificationCenter.default.post(
                name: NSNotification.Name("OpenFileConverterOpenPanel"),
                object: nil
            )
        }
    }

    public func clearAll() {
        currentPresentation = nil
        pendingQueue.removeAll()
        isAddFilesQueued = false
    }
}
