import FileConverterContracts
import Foundation

public struct ClaimedConversionRequest: Sendable {
    public let request: ConversionRequest
    fileprivate let receiptURL: URL
    fileprivate let rejectedDirectoryURL: URL
}

public enum IPCChannels {
    public static let requestsDirectoryName = "Requests"
    static let processingClaimLeaseDuration: TimeInterval = 60

    public static func prepareHost() throws {
        let configuration = try IPCConfiguration.current()
        _ = try IPCKeyStore.ensureKey(configuration: configuration)
        _ = try requestDirectories(configuration: configuration)
    }

    public static func isReady() -> Bool {
        do {
            let configuration = try IPCConfiguration.current()
            guard try IPCKeyStore.loadKey(configuration: configuration) != nil,
                  configuration.sharedContainerURL() != nil else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    public static func notificationName(configuration: IPCConfiguration) -> String {
        configuration.conversionRequestNotificationName
    }

    public static func sendRequest(_ request: ConversionRequest) throws {
        let configuration = try IPCConfiguration.current()
        try request.validate(expectedEdition: configuration.edition)
        guard let key = try IPCKeyStore.loadKey(configuration: configuration) else {
            throw IPCChannelError.hostSetupRequired
        }

        let envelope = try ConversionRequestAuthenticator.authenticate(request, keyData: key)
        let data = try ConversionRequestAuthenticator.encoder().encode(envelope)
        guard data.count <= ConversionRequestLimits.production.maximumEnvelopeSize else {
            throw IPCChannelError.requestTooLarge
        }

        let directories = try requestDirectories(configuration: configuration)
        let timestamp = Int(request.requestedAt.timeIntervalSince1970 * 1_000)
        let requestFile = directories.pending.appendingPathComponent(
            "\(timestamp)-\(request.id.uuidString).json"
        )
        try data.write(to: requestFile, options: [.atomic, .completeFileProtection])

        let notification = notificationName(configuration: configuration) as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification),
            nil,
            nil,
            true
        )
    }

    public static func claimPendingRequests() throws -> [ClaimedConversionRequest] {
        let configuration = try IPCConfiguration.current()
        guard let key = try IPCKeyStore.loadKey(configuration: configuration) else {
            throw IPCChannelError.hostSetupRequired
        }
        let directories = try requestDirectories(configuration: configuration)
        let store = IPCRequestStore(
            directories: directories,
            keyData: key,
            expectedEdition: configuration.edition,
            processingClaimLeaseDuration: processingClaimLeaseDuration
        )
        return try store.claimPendingRequests()
    }

    public static func acknowledge(_ claim: ClaimedConversionRequest) throws {
        try FileManager.default.removeItem(at: claim.receiptURL)
    }

    public static func reject(_ claim: ClaimedConversionRequest) throws {
        try IPCRequestStore.reject(claim)
    }

    private static func requestDirectories(configuration: IPCConfiguration) throws -> RequestDirectories {
        guard let container = configuration.sharedContainerURL() else {
            throw IPCChannelError.appGroupUnavailable(configuration.appGroupID)
        }

        let root = container.appendingPathComponent(requestsDirectoryName, isDirectory: true)
        let directories = RequestDirectories(root: root)
        for directory in directories.all {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directories
    }
}

struct IPCRequestStore: Sendable {
    private let directories: RequestDirectories
    private let keyData: Data
    private let expectedEdition: ProductEdition
    private let processingClaimLeaseDuration: TimeInterval

    init(
        requestsRootURL: URL,
        keyData: Data,
        expectedEdition: ProductEdition,
        processingClaimLeaseDuration: TimeInterval = IPCChannels.processingClaimLeaseDuration
    ) {
        self.init(
            directories: RequestDirectories(root: requestsRootURL),
            keyData: keyData,
            expectedEdition: expectedEdition,
            processingClaimLeaseDuration: processingClaimLeaseDuration
        )
    }

    fileprivate init(
        directories: RequestDirectories,
        keyData: Data,
        expectedEdition: ProductEdition,
        processingClaimLeaseDuration: TimeInterval
    ) {
        precondition(processingClaimLeaseDuration >= 0)
        self.directories = directories
        self.keyData = keyData
        self.expectedEdition = expectedEdition
        self.processingClaimLeaseDuration = processingClaimLeaseDuration
    }

    func prepareDirectories() throws {
        for directory in directories.all {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func claimPendingRequests(now: Date = Date()) throws -> [ClaimedConversionRequest] {
        try prepareDirectories()
        try recoverAbandonedClaims(now: now)

        let fileManager = FileManager.default
        let pendingFiles = try requestFiles(in: directories.pending)
        var newlyClaimedFiles: [URL] = []

        for pendingFile in pendingFiles {
            let claimedFile = directories.processing.appendingPathComponent(pendingFile.lastPathComponent)
            do {
                try fileManager.moveItem(at: pendingFile, to: claimedFile)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch CocoaError.fileWriteFileExists {
                try quarantineIfPresent(pendingFile)
                continue
            }

            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: claimedFile.path
            )
            newlyClaimedFiles.append(claimedFile)
        }

        var requestIDs = Set<UUID>()
        var claims: [ClaimedConversionRequest] = []
        for file in newlyClaimedFiles {
            do {
                let claim = try decodeClaim(at: file, now: now)
                guard requestIDs.insert(claim.request.id).inserted else {
                    try quarantineIfPresent(file)
                    continue
                }
                claims.append(claim)
            } catch {
                try quarantineIfPresent(file)
            }
        }
        return claims
    }

    fileprivate static func reject(_ claim: ClaimedConversionRequest) throws {
        try moveToRejected(
            claim.receiptURL,
            rejectedDirectory: claim.rejectedDirectoryURL
        )
    }

    private func recoverAbandonedClaims(now: Date) throws {
        let fileManager = FileManager.default
        for file in try requestFiles(in: directories.processing) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modificationDate = values.contentModificationDate,
                  now.timeIntervalSince(modificationDate) >= processingClaimLeaseDuration else {
                continue
            }

            let recoveredFile = directories.pending.appendingPathComponent(
                "recovered-\(UUID().uuidString).json"
            )
            do {
                try fileManager.moveItem(at: file, to: recoveredFile)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    private func decodeClaim(at file: URL, now: Date) throws -> ClaimedConversionRequest {
        let values = try file.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= ConversionRequestLimits.production.maximumEnvelopeSize else {
            throw IPCChannelError.requestTooLarge
        }

        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let envelope = try ConversionRequestAuthenticator.decoder().decode(
            AuthenticatedConversionRequest.self,
            from: data
        )
        guard try ConversionRequestAuthenticator.verify(envelope, keyData: keyData) else {
            throw IPCChannelError.authenticationFailed
        }
        try envelope.request.validate(expectedEdition: expectedEdition, now: now)
        return ClaimedConversionRequest(
            request: envelope.request,
            receiptURL: file,
            rejectedDirectoryURL: directories.rejected
        )
    }

    private func requestFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func quarantineIfPresent(_ file: URL) throws {
        do {
            try Self.moveToRejected(file, rejectedDirectory: directories.rejected)
        } catch CocoaError.fileNoSuchFile {
            // Another claimant already moved the same receipt.
        }
    }

    private static func moveToRejected(_ file: URL, rejectedDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rejectedDirectory, withIntermediateDirectories: true)
        var destination = rejectedDirectory.appendingPathComponent(file.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = rejectedDirectory.appendingPathComponent(
                "rejected-\(UUID().uuidString).json"
            )
        }

        do {
            try fileManager.moveItem(at: file, to: destination)
        } catch CocoaError.fileWriteFileExists {
            let uniqueDestination = rejectedDirectory.appendingPathComponent(
                "rejected-\(UUID().uuidString).json"
            )
            try fileManager.moveItem(at: file, to: uniqueDestination)
        }
    }
}

fileprivate struct RequestDirectories: Sendable {
    let pending: URL
    let processing: URL
    let rejected: URL

    init(root: URL) {
        pending = root.appendingPathComponent("Pending", isDirectory: true)
        processing = root.appendingPathComponent("Processing", isDirectory: true)
        rejected = root.appendingPathComponent("Rejected", isDirectory: true)
    }

    var all: [URL] {
        [pending, processing, rejected]
    }
}

public enum IPCChannelError: LocalizedError, Sendable {
    case appGroupUnavailable(String)
    case hostSetupRequired
    case requestTooLarge
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "The shared container \(identifier) is unavailable."
        case .hostSetupRequired:
            return "Open File Converter once to finish Finder integration setup."
        case .requestTooLarge:
            return "The Finder conversion request is too large."
        case .authenticationFailed:
            return "The Finder conversion request could not be authenticated."
        }
    }
}
