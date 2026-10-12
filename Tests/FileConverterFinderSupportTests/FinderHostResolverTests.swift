import XCTest
@testable import FileConverterFinderSupport

final class FinderHostResolverTests: XCTestCase {

    func testEnclosingAppResolutionFromNestedAppex() {
        let fakeAppexURL = URL(fileURLWithPath: "/Applications/File Converter.app/Contents/PlugIns/FileConverterFinderExtension.appex")
        let expectedAppURL = URL(fileURLWithPath: "/Applications/File Converter.app")
        let expectedID = "com.fileconverter.app"

        let result = FinderHostResolver.resolveContainingHostAppWithDiagnostic(
            bundleURL: fakeAppexURL,
            expectedBundleIdentifier: expectedID,
            bundleIdentifierProvider: { url in
                url.path == expectedAppURL.path ? expectedID : nil
            },
            installedAppsProvider: { _ in [] }
        )

        XCTAssertEqual(result, .enclosingApp(expectedAppURL))
        XCTAssertEqual(result.appURL, expectedAppURL)
    }

    func testMismatchedEnclosingAppFallsBackToInstalledProvider() {
        let fakeAppexURL = URL(fileURLWithPath: "/Applications/OtherApp.app/Contents/PlugIns/FileConverterFinderExtension.appex")
        let realAppURL = URL(fileURLWithPath: "/Applications/File Converter.app")
        let expectedID = "com.fileconverter.app"

        let result = FinderHostResolver.resolveContainingHostAppWithDiagnostic(
            bundleURL: fakeAppexURL,
            expectedBundleIdentifier: expectedID,
            bundleIdentifierProvider: { url in
                if url.path.contains("OtherApp.app") {
                    return "com.other.app"
                }
                return nil
            },
            installedAppsProvider: { id in
                id == expectedID ? [realAppURL] : []
            }
        )

        XCTAssertEqual(result, .singleInstalledApp(realAppURL))
        XCTAssertEqual(result.appURL, realAppURL)
    }

    func testAmbiguousInstalledApplicationsDetected() {
        let fakeBundleURL = URL(fileURLWithPath: "/tmp/test.bundle")
        let app1 = URL(fileURLWithPath: "/Applications/File Converter.app")
        let app2 = URL(fileURLWithPath: "/Users/user/Applications/File Converter.app")
        let expectedID = "com.fileconverter.app"

        let result = FinderHostResolver.resolveContainingHostAppWithDiagnostic(
            bundleURL: fakeBundleURL,
            expectedBundleIdentifier: expectedID,
            bundleIdentifierProvider: { _ in nil },
            installedAppsProvider: { id in
                id == expectedID ? [app1, app2] : []
            }
        )

        switch result {
        case .ambiguousInstalledApps(let selected, let candidates):
            XCTAssertTrue(candidates.contains(app1))
            XCTAssertTrue(candidates.contains(app2))
            XCTAssertTrue(selected == app1 || selected == app2)
        default:
            XCTFail("Expected .ambiguousInstalledApps, got \(result)")
        }
    }

    func testHostAppNotFoundWhenNoCandidatesExist() {
        let fakeBundleURL = URL(fileURLWithPath: "/tmp/nonexistent.bundle")
        let expectedID = "com.nonexistent.app"

        let result = FinderHostResolver.resolveContainingHostAppWithDiagnostic(
            bundleURL: fakeBundleURL,
            expectedBundleIdentifier: expectedID,
            bundleIdentifierProvider: { _ in nil },
            installedAppsProvider: { _ in [] }
        )

        // If system has no app for com.nonexistent.app:
        XCTAssertEqual(result, .notFound)
        XCTAssertNil(result.appURL)
    }
}
