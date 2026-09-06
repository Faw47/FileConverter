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
        do {
            let values = try directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            // Some macOS volumes report zero for the "important usage"
            // estimate even when the regular available-capacity value is
            // valid. Treat non-positive estimates as unavailable and fall
            // through to the next source instead of rejecting conversions
            // with a false zero-byte capacity.
            if let important = values.volumeAvailableCapacityForImportantUsage,
               important > 0 {
                return important
            }
            if let available = values.volumeAvailableCapacity,
               available > 0 {
                return Int64(available)
            }
        } catch {
            AppLogger.fileAccess.error("Error querying volume space: \(error.localizedDescription)")
        }
        return Int64.max
    }

    public func preserveTimestamps(from sourceURL: URL, to destinationURL: URL) throws {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)

        var destAttributes: [FileAttributeKey: Any] = [:]
        if let modDate = sourceAttributes[.modificationDate] {
            destAttributes[.modificationDate] = modDate
        }
        if let creationDate = sourceAttributes[.creationDate] {
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
