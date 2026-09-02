import Foundation

public enum JobState: Sendable, Codable, Equatable {
    case queued
    case preparing
    case converting
    case finalizing
    case completed
    case failed(ConversionError)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
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

    public var displayText: String {
        switch self {
        case .queued: return "Queued"
        case .preparing: return "Preparing..."
        case .converting: return "Converting..."
        case .finalizing: return "Finalizing..."
        case .completed: return "Completed"
        case .failed(let error): return "Failed: \(error.localizedDescription)"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct ConversionJob: Identifiable, Sendable {
    public let id: UUID
    public var sourceURL: URL
    public let sourceBookmarkData: Data?
    public var sourceAccessLease: SecurityScopedLease?
    public var destinationURL: URL?
    public var temporaryOutputURL: URL?
    public let preset: ConversionPreset
    public var state: JobState
    public var progress: ConversionProgress
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var resolvedBackend: BackendType?

    public init(
        id: UUID = UUID(),
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
        resolvedBackend: BackendType? = nil
    ) {
        self.id = id
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
    }

    public var filename: String {
        sourceURL.lastPathComponent
    }

    public var sourceFormat: String {
        sourceURL.pathExtension.uppercased()
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
