import Foundation

public struct ConversionSourceDescriptor: Identifiable, Codable, Sendable {
    public let id: UUID
    public let bookmarkData: Data
    public let displayName: String
    public let lastKnownPath: String

    public init(
        id: UUID = UUID(),
        bookmarkData: Data,
        displayName: String,
        lastKnownPath: String
    ) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.lastKnownPath = lastKnownPath
    }
}

public struct ConversionRequest: Identifiable, Codable, Sendable {
    public static let currentProtocolVersion = 1

    public let id: UUID
    public let protocolVersion: Int
    public let edition: ProductEdition
    public let presetID: UUID
    public let sources: [ConversionSourceDescriptor]
    public let requestedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        protocolVersion: Int = ConversionRequest.currentProtocolVersion,
        edition: ProductEdition,
        presetID: UUID,
        sources: [ConversionSourceDescriptor],
        requestedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.edition = edition
        self.presetID = presetID
        self.sources = sources
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt ?? requestedAt.addingTimeInterval(5 * 60)
    }

    public func validate(
        expectedEdition: ProductEdition,
        now: Date = Date(),
        limits: ConversionRequestLimits = .production
    ) throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ConversionRequestValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        guard edition == expectedEdition else {
            throw ConversionRequestValidationError.wrongEdition
        }
        guard requestedAt <= now.addingTimeInterval(limits.allowedClockSkew) else {
            throw ConversionRequestValidationError.requestFromFuture
        }
        guard expiresAt >= now, expiresAt.timeIntervalSince(requestedAt) <= limits.maximumLifetime else {
            throw ConversionRequestValidationError.expired
        }
        guard !sources.isEmpty, sources.count <= limits.maximumSourceCount else {
            throw ConversionRequestValidationError.invalidSourceCount
        }
        guard sources.allSatisfy({
            !$0.bookmarkData.isEmpty &&
            $0.bookmarkData.count <= limits.maximumBookmarkSize &&
            !$0.displayName.isEmpty
        }) else {
            throw ConversionRequestValidationError.invalidSource
        }
    }
}

public struct ConversionRequestLimits: Equatable, Sendable {
    public static let production = ConversionRequestLimits(
        maximumSourceCount: 100,
        maximumBookmarkSize: 1_048_576,
        maximumEnvelopeSize: 4_194_304,
        maximumLifetime: 5 * 60,
        allowedClockSkew: 60
    )

    public let maximumSourceCount: Int
    public let maximumBookmarkSize: Int
    public let maximumEnvelopeSize: Int
    public let maximumLifetime: TimeInterval
    public let allowedClockSkew: TimeInterval

    public init(
        maximumSourceCount: Int,
        maximumBookmarkSize: Int,
        maximumEnvelopeSize: Int,
        maximumLifetime: TimeInterval,
        allowedClockSkew: TimeInterval
    ) {
        self.maximumSourceCount = maximumSourceCount
        self.maximumBookmarkSize = maximumBookmarkSize
        self.maximumEnvelopeSize = maximumEnvelopeSize
        self.maximumLifetime = maximumLifetime
        self.allowedClockSkew = allowedClockSkew
    }
}

public enum ConversionRequestValidationError: LocalizedError, Sendable, Equatable {
    case unsupportedProtocolVersion(Int)
    case wrongEdition
    case requestFromFuture
    case expired
    case invalidSourceCount
    case invalidSource

    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocolVersion(let version):
            return "Unsupported conversion request version \(version)."
        case .wrongEdition:
            return "The conversion request targets a different File Converter edition."
        case .requestFromFuture:
            return "The conversion request timestamp is invalid."
        case .expired:
            return "The conversion request has expired."
        case .invalidSourceCount:
            return "The conversion request contains an invalid number of files."
        case .invalidSource:
            return "The conversion request contains an invalid file authorization."
        }
    }
}
