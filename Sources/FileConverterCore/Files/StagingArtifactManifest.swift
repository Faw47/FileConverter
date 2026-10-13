import Foundation

/// Represents the kind of staging artifact owned by a conversion job.
public enum StagingArtifactKind: String, Codable, Sendable {
    case temporaryFile
    case stagingDirectory
    case intermediateOutput
}

/// A recorded staging artifact entry stored in the manifest.
public struct StagingArtifactEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var jobID: UUID
    public var sessionID: UUID
    public var path: String
    public var kind: StagingArtifactKind
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        jobID: UUID,
        sessionID: UUID,
        path: String,
        kind: StagingArtifactKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.sessionID = sessionID
        self.path = path
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// A persistent manifest tracking all active staging artifacts across sessions.
/// Enables deterministic startup cleanup and crash recovery without sweeping
/// unrelated files or arbitrary temp directories.
public final class StagingArtifactManifest: @unchecked Sendable {
    public static let shared = StagingArtifactManifest()

    public let sessionID: UUID
    private let storageURLOverride: URL?
    private let lock = NSLock()
    private var entries: [StagingArtifactEntry] = []
    private let fileManager: FileManager

    public init(
        sessionID: UUID = UUID(),
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.sessionID = sessionID
        self.storageURLOverride = storageURL
        self.fileManager = fileManager
        loadManifest()
    }

    private func manifestFileURL() throws -> URL {
        if let override = storageURLOverride {
            return override
        }
        return AppDataLocation.file("staging_manifest.json")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("staging_manifest.json")
    }

    private func loadManifest() {
        lock.lock()
        defer { lock.unlock() }

        guard let url = try? manifestFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([StagingArtifactEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func saveManifest() {
        guard let url = try? manifestFileURL() else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            let tempURL = url.deletingLastPathComponent().appendingPathComponent(".staging_manifest.tmp-\(UUID().uuidString)")
            try data.write(to: tempURL, options: .atomic)
            _ = try? fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
        } catch {
            // Best effort persistence
        }
    }

    public func registerArtifact(
        path: String,
        jobID: UUID,
        kind: StagingArtifactKind
    ) {
        lock.lock()
        defer { lock.unlock() }

        // Standardize path
        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !entries.contains(where: { $0.path == stdPath }) else { return }

        let entry = StagingArtifactEntry(
            jobID: jobID,
            sessionID: sessionID,
            path: stdPath,
            kind: kind
        )
        entries.append(entry)
        saveManifest()
    }

    public func unregisterArtifact(path: String) {
        lock.lock()
        defer { lock.unlock() }

        let stdPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let initialCount = entries.count
        entries.removeAll { $0.path == stdPath }
        if entries.count != initialCount {
            saveManifest()
        }
    }

    public func unregisterArtifacts(for jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        let initialCount = entries.count
        entries.removeAll { $0.jobID == jobID }
        if entries.count != initialCount {
            saveManifest()
        }
    }

    public var allEntries: [StagingArtifactEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func entries(for jobID: UUID) -> [StagingArtifactEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.jobID == jobID }
    }

    /// Conservatively sweeps orphaned staging artifacts from prior dead sessions.
    /// Only deletes artifacts that are explicitly listed in the manifest AND match
    /// FileConverter ownership markers.
    @discardableResult
    public func sweepOrphanedArtifacts() -> [URL] {
        lock.lock()
        let priorEntries = entries.filter { $0.sessionID != sessionID }
        lock.unlock()

        var deletedURLs: [URL] = []
        var pathsToRemoveFromManifest: Set<String> = []

        for entry in priorEntries {
            let url = URL(fileURLWithPath: entry.path)
            let path = url.path

            guard isSafeToSweep(path: path) else {
                // Ambiguous or dangerous path; do not delete, just retain or quarantine
                continue
            }

            if fileManager.fileExists(atPath: path) {
                do {
                    try fileManager.removeItem(at: url)
                    deletedURLs.append(url)
                    pathsToRemoveFromManifest.insert(entry.path)
                } catch {
                    // Retain entry if deletion failed
                }
            } else {
                // Already gone
                pathsToRemoveFromManifest.insert(entry.path)
            }
        }

        if !pathsToRemoveFromManifest.isEmpty {
            lock.lock()
            entries.removeAll { pathsToRemoveFromManifest.contains($0.path) }
            saveManifest()
            lock.unlock()
        }

        return deletedURLs
    }

    /// Verifies that a path contains recognizable FileConverter staging markers
    /// and does not point to user data or system roots.
    private func isSafeToSweep(path: String) -> Bool {
        let filename = URL(fileURLWithPath: path).lastPathComponent

        // Must contain one of our explicit staging markers
        let hasMarker = filename.contains(".fileconverter-tmp-")
            || filename.contains("FileConverter-LibreOffice-")
            || filename.contains(".FileConverter-AudioSplit-")
            || filename.contains(".fileconverter-original-")

        guard hasMarker else { return false }

        // Must not be root or parent directory
        guard path != "/" && !filename.isEmpty && filename != "." && filename != ".." else {
            return false
        }

        return true
    }
}
