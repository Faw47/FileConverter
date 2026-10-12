import XCTest

/// Guards against UI text that cannot be translated correctly.
final class LocalizationTests: XCTestCase {
    private var appSources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileConverterApp")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    func testNoPluralsBuiltByConcatenation() throws {
        let pattern = try NSRegularExpression(pattern: #"== 1 \? "[a-z ]*" : "[a-z ]*""#)
        for file in appSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            let matches = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(matches, 0, "Use Inflect.string(\"^[\\(n) item](inflect: true)\") in \(file.lastPathComponent)")
        }
    }

    func testDirectionalArrowsFlipForRightToLeft() throws {
        for file in appSources {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("\"arrow.right"), "Use arrow.forward so it flips in right-to-left languages: \(file.lastPathComponent)")
        }
    }

    func testProjectExtractsStrings() throws {
        let project = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("SWIFT_EMIT_LOC_STRINGS: YES"))
    }
}
