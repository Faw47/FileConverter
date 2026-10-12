import XCTest

/// Help.md names buttons, settings, and menu items in bold. Each must still
/// exist in the app's source so the help never describes UI that is gone.
final class HelpContentTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Names that are not in the app's own source.
    private let external: Set<String> = [
        "System Settings › General › Login Items & Extensions",
        "Space", "Return", "Delete", "Esc", "+", "From Finder:", "From the window:",
        "Open With, Services, and the Dock icon:", "File Converter",
    ]

    func testBoldNamesExistInApp() throws {
        let help = try String(contentsOf: root.appendingPathComponent("Sources/FileConverterApp/Resources/Help.md"), encoding: .utf8)
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources/FileConverterApp"), includingPropertiesForKeys: nil)
        let source = try (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        let pattern = try NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
        let names = pattern.matches(in: help, range: NSRange(help.startIndex..., in: help)).compactMap {
            Range($0.range(at: 1), in: help).map { String(help[$0]) }
        }
        XCTAssertFalse(names.isEmpty)
        for name in names where !external.contains(name) {
            // "Settings › General › Saving" → each part after "Settings".
            let parts = name.components(separatedBy: " › ").filter { $0 != "Settings" && $0 != "Conversion" }
            for part in parts {
                XCTAssertTrue(source.contains("\"\(part)") || source.contains("case \(part.lowercased())"),
                              "Help.md mentions “\(part)” but the app has no such label")
            }
        }
    }
}
