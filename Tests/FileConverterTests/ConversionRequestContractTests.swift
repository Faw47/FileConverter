import XCTest
import Darwin
@testable import FileConverterContracts

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

        XCTAssertEqual(configuration.sharedContainerURL()?.standardizedFileURL, expected.standardizedFileURL)
    }

    func testLocalSharedContainerPathRejectsTraversal() {
        let configuration = makeConfiguration(
            localSharedContainerPath: "/Library/Application Support/../Secrets/"
        )

        XCTAssertNil(configuration.sharedContainerURL())
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

    private func makeConfiguration(localSharedContainerPath: String?) -> IPCConfiguration {
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
