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
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let available = values.volumeAvailableCapacity {
                return Int64(available)
            }
        } catch {
            AppLogger.fileAccess.error("Error querying volume space: \(error.localizedDescription)")
        }
        return Int64.max
    }

    public func preserveTimestamps(from sourceURL: URL, to destinationURL: URL) {
        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else {
            return
        }

        var destAttributes: [FileAttributeKey: Any] = [:]
        if let modDate = sourceAttributes[.modificationDate] {
            destAttributes[.modificationDate] = modDate
        }
        if let creationDate = sourceAttributes[.creationDate] {
            destAttributes[.creationDate] = creationDate
        }

        if !destAttributes.isEmpty {
            try? FileManager.default.setAttributes(destAttributes, ofItemAtPath: destinationURL.path)
        }
    }

    public func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
