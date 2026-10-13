import FileConverterCore
import FileConverterExternalBackends
import XCTest

/// Test runs must never write into the user's real Application Support
/// folder; earlier runs left hundreds of fake "interrupted" conversions.
final class AppDataIsolationTests: XCTestCase {
    func testStoresUseTemporaryFolderUnderTests() throws {
        XCTAssertTrue(AppDataLocation.isRunningTests)
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let urls = [
            AppDataLocation.directory,
            AppDataLocation.file("conversion_journal.json"),
            QueueHistoryStore.defaultURL,
            ExternalToolDiscovery.defaultCapabilitiesCacheURL,
        ]
        for url in urls {
            let path = try XCTUnwrap(url).standardizedFileURL.path
            XCTAssertTrue(path.hasPrefix(temp), "\(path) is outside the temporary folder")
            XCTAssertFalse(path.contains("Library/Application Support"))
        }
    }
}
