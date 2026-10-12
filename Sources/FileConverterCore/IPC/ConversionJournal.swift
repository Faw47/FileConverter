import Foundation

/// Explicit lifecycle states for conversion jobs in the durable admission journal.
public enum JournalJobState: String, Codable, Sendable {
    /// Job has been durably journaled and admitted into the queue.
    case admitted
    /// Job is actively being processed by a conversion backend.
    case running
    /// Backend completed; outputs are undergoing atomic coordinated commit.
    case committing
    /// Final outputs committed durably and successfully.
    case finished
    /// Job was cancelled before or during processing.
    case cancelled
    /// Job failed with an error.
    case failed
}

/// A recorded entry in the durable admission journal.
public struct JournalEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID // Job ID
    public let requestID: UUID
    public let sourceURLPath: String
    public let sourceBookmarkData: Data?
    public let presetID: UUID
    public let presetName: String
    public var state: JournalJobState
    public var committedOutputPaths: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        requestID: UUID,
        sourceURLPath: String,
        sourceBookmarkData: Data? = nil,
        presetID: UUID,
        presetName: String,
        state: JournalJobState = .admitted,
        committedOutputPaths: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.sourceURLPath = sourceURLPath
        self.sourceBookmarkData = sourceBookmarkData
        self.presetID = presetID
        self.presetName = presetName
        self.state = state
        self.committedOutputPaths = committedOutputPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A versioned durable journal for tracking conversion admissions, state transitions,
/// and restart recovery without duplicating work or losing track of inflight jobs.
public final class ConversionJournal: @unchecked Sendable {
    public static let shared = ConversionJournal()

    private let storageURLOverride: URL?
    private let lock = NSLock()
    private var entriesByID: [UUID: JournalEntry] = [:]
    private let fileManager: FileManager
    public static let maxEntriesLimit = 1000

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.storageURLOverride = storageURL
        self.fileManager = fileManager
        loadJournal()
    }

    private func journalFileURL() throws -> URL {
        if let override = storageURLOverride {
            return override
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appDir = appSupport.appendingPathComponent("FileConverter", isDirectory: true)
        if !fileManager.fileExists(atPath: appDir.path) {
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir.appendingPathComponent("conversion_journal.json")
    }

    private func loadJournal() {
        lock.lock()
        defer { lock.unlock() }

        guard let url = try? journalFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data) else {
            entriesByID = [:]
            return
        }
        entriesByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func saveJournal() {
        guard let url = try? journalFileURL() else { return }
        do {
            let entriesList = Array(entriesByID.values)
            let data = try JSONEncoder().encode(entriesList)
            let tempURL = url.deletingLastPathComponent().appendingPathComponent(".journal.tmp-\(UUID().uuidString)")
            try data.write(to: tempURL, options: .atomic)
            _ = try? fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
        } catch {
            // Best effort persistence
        }
    }

    public func recordAdmission(
        jobID: UUID,
        requestID: UUID,
        sourceURL: URL,
        bookmarkData: Data?,
        presetID: UUID,
        presetName: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Prune if limit exceeded
        if entriesByID.count >= Self.maxEntriesLimit {
            pruneOldEntriesLocked()
        }

        let entry = JournalEntry(
            id: jobID,
            requestID: requestID,
            sourceURLPath: sourceURL.path,
            sourceBookmarkData: bookmarkData,
            presetID: presetID,
            presetName: presetName,
            state: .admitted
        )
        entriesByID[jobID] = entry
        saveJournal()
    }

    public func transitionState(
        jobID: UUID,
        to newState: JournalJobState,
        outputPaths: [String] = []
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = entriesByID[jobID] else { return }
        entry.state = newState
        entry.updatedAt = Date()
        if !outputPaths.isEmpty {
            entry.committedOutputPaths = outputPaths
        }
        entriesByID[jobID] = entry
        saveJournal()
    }

    public func entry(for jobID: UUID) -> JournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByID[jobID]
    }

    public func allEntries() -> [JournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entriesByID.values)
    }

    /// Identifies jobs from a prior session that require recovery.
    /// In-flight jobs (`admitted`, `running`, `committing`) are flagged for recovery review.
    public func uncompletedEntries() -> [JournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entriesByID.values.filter {
            $0.state == .admitted || $0.state == .running || $0.state == .committing
        }
    }

    private func pruneOldEntriesLocked() {
        // Keep the 500 newest entries
        let sorted = entriesByID.values.sorted { $0.updatedAt > $1.updatedAt }
        let retained = sorted.prefix(Self.maxEntriesLimit / 2)
        entriesByID = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
    }

    public func prune(olderThan interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-interval)
        entriesByID = entriesByID.filter { _, entry in
            entry.updatedAt > cutoff || entry.state == .admitted || entry.state == .running || entry.state == .committing
        }
        saveJournal()
    }
}
