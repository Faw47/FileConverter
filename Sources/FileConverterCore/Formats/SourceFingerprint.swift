import Foundation

/// A lightweight, durable fingerprint of a source file's identity and metadata.
/// Used to validate whether a file has changed before reusing cached detection results or probes.
public struct SourceFingerprint: Hashable, Sendable, Codable {
    public let url: URL
    public let standardizedPath: String
    public let exists: Bool
    public let isDirectory: Bool
    public let modificationDate: Date?
    public let fileSize: Int64?
    public let fileSystemNumber: UInt64?
    public let fileNumber: UInt64?

    public init(url: URL) {
        self.url = url
        let standardized = url.standardizedFileURL.path
        self.standardizedPath = standardized
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir),
           let attrs = try? FileManager.default.attributesOfItem(atPath: standardized) {
            self.exists = true
            self.isDirectory = isDir.boolValue
            self.modificationDate = attrs[.modificationDate] as? Date
            self.fileSize = (attrs[.size] as? NSNumber)?.int64Value
            self.fileSystemNumber = (attrs[.systemNumber] as? NSNumber)?.uint64Value
            self.fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        } else {
            self.exists = false
            self.isDirectory = false
            self.modificationDate = nil
            self.fileSize = nil
            self.fileSystemNumber = nil
            self.fileNumber = nil
        }
    }

    /// Checks if the file on disk still matches this recorded fingerprint.
    public func matchesCurrentState() -> Bool {
        SourceFingerprint(url: url) == self
    }
}

/// A cached snapshot of format detection anchored to a specific source fingerprint.
public struct DetectionSnapshot: Sendable {
    public let fingerprint: SourceFingerprint
    public let result: FormatDetectionResult
    public let timestamp: Date

    public init(fingerprint: SourceFingerprint, result: FormatDetectionResult, timestamp: Date = Date()) {
        self.fingerprint = fingerprint
        self.result = result
        self.timestamp = timestamp
    }

    /// Returns true only while the underlying source file still matches the captured fingerprint.
    public var isValid: Bool {
        fingerprint.matchesCurrentState()
    }
}
