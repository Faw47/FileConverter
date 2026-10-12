import XCTest
import Darwin
@testable import FileConverterContracts
@testable import FileConverterCore

final class ConversionRequestContractTests: XCTestCase {
    private let key = Data(repeating: 0xA5, count: 32)

    func testAuthenticatedRequestRoundTrip() throws {
        let request = makeRequest()
        let envelope = try ConversionRequestAuthenticator.authenticate(request, keyData: key)
        let data = try ConversionRequestAuthenticator.encoder().encode(envelope)
        let decoded = try ConversionRequestAuthenticator.decoder().decode(
            AuthenticatedConversionRequest.self,
            from: data
        )

        XCTAssertTrue(try ConversionRequestAuthenticator.verify(decoded, keyData: key))
        XCTAssertEqual(decoded.request.id, request.id)
        XCTAssertEqual(decoded.request.sources.first?.lastKnownPath, "/tmp/example.png")
    }

    func testAuthenticationRejectsDifferentKey() throws {
        let envelope = try ConversionRequestAuthenticator.authenticate(makeRequest(), keyData: key)
        let otherKey = Data(repeating: 0x5A, count: 32)

        XCTAssertFalse(try ConversionRequestAuthenticator.verify(envelope, keyData: otherKey))
    }

    func testValidationRejectsExpiredRequest() {
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        let request = makeRequest(
            requestedAt: requestedAt,
            expiresAt: requestedAt.addingTimeInterval(60)
        )

        XCTAssertThrowsError(
            try request.validate(
                expectedEdition: .native,
                now: requestedAt.addingTimeInterval(61)
            )
        ) { error in
            XCTAssertEqual(error as? ConversionRequestValidationError, .expired)
        }
    }

    func testValidationRejectsWrongEdition() {
        let request = makeRequest()

        XCTAssertThrowsError(try request.validate(expectedEdition: .extended)) { error in
            XCTAssertEqual(error as? ConversionRequestValidationError, .wrongEdition)
        }
    }

    func testLocalSharedContainerPathIsResolvedRelativeToHome() throws {
        let configuration = makeConfiguration(
            localSharedContainerPath: "/Library/Application Support/FileConverter/LocalIPC/native/"
        )
        let userRecord = try XCTUnwrap(getpwuid(getuid()))
        let homePath = try XCTUnwrap(userRecord.pointee.pw_dir)
        let expected = URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
            .appendingPathComponent("Library/Application Support/FileConverter/LocalIPC/native", isDirectory: true)

        XCTAssertEqual(
            configuration.sharedContainerURL(
                fileManager: StubContainerFileManager(
                    containerURL: URL(fileURLWithPath: "/tmp/file-converter-app-group", isDirectory: true)
                )
            )?.standardizedFileURL,
            expected.standardizedFileURL
        )
    }

    func testLocalSharedContainerPathRejectsTraversal() {
        let configuration = makeConfiguration(
            localSharedContainerPath: "/Library/Application Support/../Secrets/"
        )

        XCTAssertNil(configuration.sharedContainerURL(fileManager: StubContainerFileManager(containerURL: nil)))
    }

    func testAppGroupContainerIsUsedWhenNoLocalPathIsConfigured() {
        let appGroupURL = URL(fileURLWithPath: "/tmp/file-converter-app-group", isDirectory: true)
        let configuration = makeConfiguration()

        XCTAssertEqual(
            configuration.sharedContainerURL(
                fileManager: StubContainerFileManager(containerURL: appGroupURL)
            ),
            appGroupURL
        )
    }

    func testAuthenticationKeyIsMaterializedInLocalSharedContainer() throws {
        let suffix = UUID().uuidString
        let configuration = makeConfiguration(
            localSharedContainerPath: "/Library/Caches/FileConverterIPCKeyStoreTests-\(suffix)/"
        )
        let container = try XCTUnwrap(configuration.sharedContainerURL())
        defer { try? FileManager.default.removeItem(at: container) }

        let ensured = try IPCAuthenticationKeyStore.ensureKey(configuration: configuration)
        let keyURL = container
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent("IPC", isDirectory: true)
            .appendingPathComponent("authentication-native.key")

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
        XCTAssertEqual(try IPCAuthenticationKeyStore.loadKey(configuration: configuration), ensured)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testSecurityScopedFinderBookmarkCanBeConsumedByHost() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pdf")
        try Data("%PDF-1.4".utf8).write(to: sourceURL)
        let bookmark = try sourceURL.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let lease = try SecurityScopedLease(bookmarkData: bookmark)
        XCTAssertEqual(lease.url.standardizedFileURL, sourceURL.standardizedFileURL)
        lease.release()
    }

    private func makeRequest(
        requestedAt: Date = Date(),
        expiresAt: Date? = nil
    ) -> ConversionRequest {
        ConversionRequest(
            edition: .native,
            presetID: UUID(),
            sources: [
                ConversionSourceDescriptor(
                    bookmarkData: Data([1, 2, 3]),
                    displayName: "example.png",
                    lastKnownPath: "/tmp/example.png"
                )
            ],
            requestedAt: requestedAt,
            expiresAt: expiresAt
        )
    }

    private func makeConfiguration(localSharedContainerPath: String? = nil) -> IPCConfiguration {
        IPCConfiguration(
            appGroupID: "group.io.fileconverter.shared",
            edition: .native,
            hostBundleIdentifier: "io.fileconverter.app",
            keychainAccessGroup: "TESTTEAM.io.fileconverter.ipc",
            urlScheme: "fileconverter",
            localSharedContainerPath: localSharedContainerPath
        )
    }
}

private final class StubContainerFileManager: FileManager, @unchecked Sendable {
    private let stubbedContainerURL: URL?

    init(containerURL: URL?) {
        self.stubbedContainerURL = containerURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        stubbedContainerURL
    }
}
