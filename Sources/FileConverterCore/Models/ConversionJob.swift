import Foundation

public enum JobState: Sendable, Codable, Equatable {
    case queued
    case preparing
    case awaitingCollision
    case converting
    case finalizing
    case completed
    case completedWithWarnings([String])
    case failed(ConversionError)
    case skipped(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .completedWithWarnings, .failed, .skipped, .cancelled:
            return true
        default:
            return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .converting, .finalizing:
            return true
        default:
            return false
        }
    }

    /// Finalization is intentionally excluded: at that point the backend has
    /// produced output and the queue is committing it atomically.
    public var isCancellable: Bool {
        switch self {
        case .queued, .preparing, .awaitingCollision, .converting:
            return true
        default:
            return false
        }
    }

    public var displayText: String {
        switch self {
        case .queued: return "Queued"
        case .preparing: return "Preparing..."
        case .awaitingCollision: return "Waiting for overwrite decision"
        case .converting: return "Converting..."
        case .finalizing: return "Finalizing..."
        case .completed: return "Completed"
        case .completedWithWarnings: return "Completed with warnings"
        case .failed(let error): return "Failed: \(error.localizedDescription)"
        case .skipped(let reason): return "Skipped: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct ConversionJob: Identifiable, Sendable {
    public let id: UUID
    public var batchID: UUID
    public var sourceURL: URL
    public let sourceBookmarkData: Data?
    public var sourceAccessLease: SecurityScopedLease?
    public var destinationURL: URL?
    public var temporaryOutputURL: URL?
    public var preset: ConversionPreset
    public var state: JobState
    public var progress: ConversionProgress
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var resolvedBackend: BackendType?
    public var plannedOutputs: [PlannedConversionOutput]
    public var outputURLs: [URL]
    public var warnings: [String]

    public init(
        id: UUID = UUID(),
        batchID: UUID = UUID(),
        sourceURL: URL,
        sourceBookmarkData: Data? = nil,
        sourceAccessLease: SecurityScopedLease? = nil,
        destinationURL: URL? = nil,
        temporaryOutputURL: URL? = nil,
        preset: ConversionPreset,
        state: JobState = .queued,
        progress: ConversionProgress = ConversionProgress(),
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        resolvedBackend: BackendType? = nil,
        plannedOutputs: [PlannedConversionOutput] = [],
        outputURLs: [URL] = [],
        warnings: [String] = []
    ) {
        self.id = id
        self.batchID = batchID
        self.sourceURL = sourceURL
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceAccessLease = sourceAccessLease
        self.destinationURL = destinationURL
        self.temporaryOutputURL = temporaryOutputURL
        self.preset = preset
        self.state = state
        self.progress = progress
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resolvedBackend = resolvedBackend
        self.plannedOutputs = plannedOutputs
        self.outputURLs = outputURLs
        self.warnings = warnings
    }

    public var filename: String {
        sourceURL.lastPathComponent
    }

    public var sourceFormat: String {
        FormatDetector.detect(url: sourceURL).format?.primaryExtension.uppercased()
            ?? sourceURL.pathExtension.uppercased()
    }

    public var targetFormat: String {
        preset.destinationFormat.uppercased()
    }

    public var totalElapsedTime: TimeInterval {
        if let start = startedAt {
            let end = finishedAt ?? Date()
            return end.timeIntervalSince(start)
        }
        return 0
    }
}
