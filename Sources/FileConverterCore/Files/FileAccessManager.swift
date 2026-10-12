import Foundation

public final class FileAccessManager: @unchecked Sendable {
    public static let shared = FileAccessManager()

    private var activeSecurityScopedURLs: Set<URL> = []
    private let lock = NSLock()

    public init() {}

    public func startAccessing(url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.insert(url)
            return true
        }
        return false
    }

    public func stopAccessing(url: URL) {
        lock.lock()
        defer { lock.unlock() }

        if activeSecurityScopedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(url)
        }
    }

    public func stopAccessingAll() {
        lock.lock()
        defer { lock.unlock() }

        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    public func checkAvailableDiskSpace(at directoryURL: URL) -> Int64 {
        switch diskSpaceState(at: directoryURL) {
        case .available(let bytes):
            return bytes
        case .unavailable, .queryFailed:
            return Int64.max
        }
    }

    public enum DiskSpaceState: Sendable, Equatable {
        case available(Int64)
        case unavailable
        case queryFailed
    }

    /// Explicit disk-space state. `queryFailed` must be surfaced as a warning
    /// rather than treated as infinite capacity without telling the user.
    public func diskSpaceState(at directoryURL: URL) -> DiskSpaceState {
        do {
            let values = try directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            // Some macOS volumes report zero for the "important usage"
            // estimate even when the regular available-capacity value is
            // valid. Treat non-positive estimates as unavailable and fall
            // through to the next source instead of rejecting conversions
            // with a false zero-byte capacity.
            if let important = values.volumeAvailableCapacityForImportantUsage,
               important > 0 {
                return .available(important)
            }
            if let available = values.volumeAvailableCapacity,
               available > 0 {
                return .available(Int64(available))
            }
            if values.volumeAvailableCapacityForImportantUsage != nil || values.volumeAvailableCapacity != nil {
                return .unavailable
            }
        } catch {
            AppLogger.fileAccess.error("Error querying volume space: \(error.localizedDescription)")
        }
        return .queryFailed
    }

    /// Standardized, symlink-resolved identity check. Rejects same-file
    /// conversion before temporary output creation or commit.
    public func reservationKey(for url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.isFileURL else {
            return standardizedURL
        }

        // Foundation does not consistently resolve a symlinked parent when
        // the final path component does not exist. Resolve every existing
        // component first, then append the remaining path suffix.
        var resolvedURL = URL(fileURLWithPath: "/")
        for component in standardizedURL.pathComponents.dropFirst() {
            let nextURL = resolvedURL.appendingPathComponent(component)
            if FileManager.default.fileExists(atPath: nextURL.path) {
                resolvedURL = nextURL.resolvingSymlinksInPath().standardizedFileURL
            } else {
                resolvedURL = nextURL
            }
        }
        return resolvedURL.standardizedFileURL
    }

    public func urlsReferToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = reservationKey(for: lhs)
        let right = reservationKey(for: rhs)
        if left.path == right.path { return true }
        // Filesystem identity where available (inode + device).
        if let lAttrs = try? FileManager.default.attributesOfItem(atPath: left.path),
           let rAttrs = try? FileManager.default.attributesOfItem(atPath: right.path),
           let lID = (lAttrs[.systemFileNumber] as? NSNumber)?.uint64Value,
           let rID = (rAttrs[.systemFileNumber] as? NSNumber)?.uint64Value,
           lID == rID {
            let lDev = (lAttrs[.systemNumber] as? NSNumber)?.uint64Value
            let rDev = (rAttrs[.systemNumber] as? NSNumber)?.uint64Value
            if lDev == rDev { return true }
        }
        return false
    }

    public func preserveTimestamps(
        from sourceURL: URL,
        to destinationURL: URL,
        creation: Bool = true,
        modification: Bool = true
    ) throws {
        guard creation || modification else { return }
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)

        var destAttributes: [FileAttributeKey: Any] = [:]
        if modification, let modDate = sourceAttributes[.modificationDate] {
            destAttributes[.modificationDate] = modDate
        }
        if creation, let creationDate = sourceAttributes[.creationDate] {
            destAttributes[.creationDate] = creationDate
        }

        if !destAttributes.isEmpty {
            try FileManager.default.setAttributes(destAttributes, ofItemAtPath: destinationURL.path)
        }
    }

    public func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
