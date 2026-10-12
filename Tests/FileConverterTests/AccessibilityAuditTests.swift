import XCTest
import Foundation

final class AccessibilityAuditTests: XCTestCase {

    private func sourceFileContents(relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/FileConverterTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let targetFile = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: targetFile),
              let content = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read source file at \(targetFile.path)")
            return ""
        }
        return content
    }

    func testPDFCompressDialogHasComprehensiveAccessibility() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/Dialogs/PDFCompressDialogView.swift")
        XCTAssertFalse(content.isEmpty)

        // Profiles
        XCTAssertTrue(content.contains(".accessibilityLabel(\"\\(profile.rawValue) profile\")"))
        XCTAssertTrue(content.contains(".accessibilityHint(profile.subtitle)"))

        // Custom options
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Color Mode\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Target Resolution in DPI\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"JPEG Image Quality\")"))

        // Document cleanup toggles
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Remove metadata\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Remove annotations\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Remove embedded page thumbnails\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Linearize for fast web view\")"))

        // Output destination & actions
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Filename suffix\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Cancel compression\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Start PDF compression\")"))
    }

    func testPDFSplitDialogHasComprehensiveAccessibility() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/Dialogs/PDFSplitDialogView.swift")
        XCTAssertFalse(content.isEmpty)

        // Custom range input per-file
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Custom range for \\(item.url.lastPathComponent)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Remove \\(item.url.lastPathComponent)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(mode.rawValue)"))
    }

    func testCollisionResolutionHasAccessibilityAndKeyShortcuts() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/FileConverterMainView.swift")
        XCTAssertFalse(content.isEmpty)

        XCTAssertTrue(content.contains(".accessibilityLabel(\"Conflict for \\(conflict.sourceFilename)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Cancel collision resolution\")"))
        XCTAssertTrue(content.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(content.contains(".accessibilityLabel(applyToAll ? \"Skip all conflicting files\" : \"Skip this conflicting file\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(applyToAll ? \"Keep both files for all conflicts\" : \"Keep both files\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(applyToAll ? \"Replace all existing files\" : \"Replace existing file\")"))
    }

    func testGeneralSettingsHasAccessibilityLabels() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/Settings/GeneralSettingsView.swift")
        XCTAssertFalse(content.isEmpty)

        XCTAssertTrue(content.contains(".accessibilityLabel(\"Choose custom output folder\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Default collision policy when output already exists\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Filename pattern template\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Reset filename pattern to default\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Preserve creation and modification dates\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Show macOS notification banner\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Reveal completed files in Finder\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Reset general settings to defaults\")"))
    }

    func testInterruptedRecoveryBannerAccessibility() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/FileConverterMainView.swift")
        XCTAssertFalse(content.isEmpty)

        XCTAssertTrue(content.contains(".accessibilityLabel(\"Dismiss interrupted conversion alerts\")"))
    }
}
