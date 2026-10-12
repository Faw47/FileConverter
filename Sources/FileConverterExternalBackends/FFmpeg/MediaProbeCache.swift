import Foundation
import FileConverterCore

/// Cached media probe observations (duration, codecs, dimensions, etc.)
public struct MediaProbeMetadata: Sendable, Equatable {
    public var duration: Double?
    public var audioCodec: String?
    public var videoCodec: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var streamCount: Int?
    public var sourceInfo: SourceMediaInfo?

    public init(
        duration: Double? = nil,
        audioCodec: String? = nil,
        videoCodec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        streamCount: Int? = nil
    ) {
        self.duration = duration
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.streamCount = streamCount
    }
}

/// Actor-isolated media probe cache keyed by source URL and verified against source fingerprints.
/// Evicts stale entries on file mutation, job completion/cancellation, or LRU capacity limit.
public actor MediaProbeCache {
    public static let shared = MediaProbeCache()

    private struct Entry {
        let fingerprint: SourceFingerprint
        var metadata: MediaProbeMetadata
        var lastAccessed: Date
    }

    private var cache: [URL: Entry] = [:]
    private let maxEntries = 100

    public init() {}

    /// Retrieves cached metadata if the file has not been modified since the probe was cached.
    public func metadata(for url: URL) -> MediaProbeMetadata? {
        guard let entry = cache[url] else { return nil }
        guard entry.fingerprint.matchesCurrentState() else {
            cache.removeValue(forKey: url)
            return nil
        }
        cache[url]?.lastAccessed = Date()
        return entry.metadata
    }

    /// Updates or inserts metadata for a URL with the file's current fingerprint.
    public func update(for url: URL, mutate: (inout MediaProbeMetadata) -> Void) {
        let currentFingerprint = SourceFingerprint(url: url)
        var metadata = cache[url]?.fingerprint.matchesCurrentState() == true
            ? (cache[url]?.metadata ?? MediaProbeMetadata())
            : MediaProbeMetadata()
        mutate(&metadata)

        if cache.count >= maxEntries, cache[url] == nil {
            if let oldest = cache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed })?.key {
                cache.removeValue(forKey: oldest)
            }
        }

        cache[url] = Entry(
            fingerprint: currentFingerprint,
            metadata: metadata,
            lastAccessed: Date()
        )
    }

    /// Evicts cached probe data for the specified URL upon completion or cancellation.
    public func evict(for url: URL) {
        cache.removeValue(forKey: url)
    }

    /// Clears the entire probe cache.
    public func clear() {
        cache.removeAll()
    }
}
