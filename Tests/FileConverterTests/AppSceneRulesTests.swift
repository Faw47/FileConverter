import XCTest

/// Scene-level mistakes that only show up in the running app.
final class AppSceneRulesTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// MenuBarExtra writes `isInserted` on every update. Bound straight to a
    /// stored property, each write triggered another update and the app sat
    /// at 100% CPU with a frozen main thread.
    func testMenuBarExtraIsNotBoundDirectlyToStorage() throws {
        let app = try source("Sources/FileConverterApp/AppMain.swift")
        XCTAssertFalse(app.contains("MenuBarExtra(isInserted: $"), "bind isInserted through a guard that ignores unchanged values")
    }
}
