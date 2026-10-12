import Foundation

/// A canonical, normalized destination identifier that resolves parent symlinks
/// and standardizes path representation across volumes.
public struct CanonicalDestinationKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let standardizedPath: String

    public init(url: URL) {
        self.standardizedPath = FileAccessManager.shared.reservationKey(for: url).path
    }

    public init(path: String) {
        self.standardizedPath = FileAccessManager.shared.reservationKey(for: URL(fileURLWithPath: path)).path
    }

    public var description: String {
        standardizedPath
    }
}

/// A captured snapshot of a destination's existence and metadata at decision time.
/// Used to detect TOCTOU races between user approval and commit.
public struct DestinationFingerprint: Hashable, Sendable, Codable {
    public let canonicalKey: CanonicalDestinationKey
    public let exists: Bool
    public let modificationDate: Date?
    public let fileSize: Int64?
    public let fileSystemNumber: UInt64?
    public let fileNumber: UInt64?

    public init(url: URL) {
        let key = CanonicalDestinationKey(url: url)
        self.canonicalKey = key
        let path = key.standardizedPath
        if FileManager.default.fileExists(atPath: path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            self.exists = true
            self.modificationDate = attrs[.modificationDate] as? Date
            self.fileSize = (attrs[.size] as? NSNumber)?.int64Value
            self.fileSystemNumber = (attrs[.systemNumber] as? NSNumber)?.uint64Value
            self.fileNumber = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        } else {
            self.exists = false
            self.modificationDate = nil
            self.fileSize = nil
            self.fileSystemNumber = nil
            self.fileNumber = nil
        }
    }

    public func matchesCurrentState(of url: URL) -> Bool {
        let current = DestinationFingerprint(url: url)
        return self == current
    }
}

/// A destination-keyed authorization plan that explicitly maps canonical destination keys
/// to approved user decisions. Eliminates job-wide blanket overwrite escalation.
public struct CollisionResolutionPlan: Sendable, Equatable {
    public enum ResolutionDecision: Sendable, Equatable {
        case replace(approvedFingerprint: DestinationFingerprint)
        case keepBoth
        case skip
    }

    public private(set) var decisions: [CanonicalDestinationKey: ResolutionDecision]

    public init(decisions: [CanonicalDestinationKey: ResolutionDecision] = [:]) {
        self.decisions = decisions
    }

    public mutating func setDecision(_ decision: ResolutionDecision, for key: CanonicalDestinationKey) {
        decisions[key] = decision
    }

    public func decision(for key: CanonicalDestinationKey) -> ResolutionDecision? {
        decisions[key]
    }

    public func decision(for url: URL) -> ResolutionDecision? {
        decisions[CanonicalDestinationKey(url: url)]
    }

    public var isEmpty: Bool {
        decisions.isEmpty
    }
}
