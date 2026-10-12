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
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/Dialogs/CollisionResolutionView.swift")
        XCTAssertFalse(content.isEmpty)

        XCTAssertTrue(content.contains(".accessibilityLabel(\"Conflict for \\(conflict.sourceFilename)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Cancel collision resolution\")"))
        XCTAssertTrue(content.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Skip \\(conflict.sourceFilename)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Keep both files for \\(conflict.sourceFilename)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Replace the existing file for \\(conflict.sourceFilename)\")"))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Replace all existing files\")"))
        // A destructive bulk action must not be reachable with Return alone.
        XCTAssertFalse(content.contains(".keyboardShortcut(.defaultAction)"))
    }

    func testGeneralSettingsControlsAllHaveVisibleLabels() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/Settings/GeneralSettingsView.swift")
        XCTAssertFalse(content.isEmpty)

        // Native Form controls are announced by their titles, so no control
        // may hide or omit its title.
        XCTAssertFalse(content.contains("Toggle(\"\""), "every toggle needs a title")
        XCTAssertFalse(content.contains("Picker(\"\""), "every picker needs a title")
        XCTAssertFalse(content.contains(".labelsHidden()"), "titles must stay visible to VoiceOver")
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Choose output folder\")"))
        XCTAssertTrue(content.contains(".formStyle(.grouped)"))
    }

    func testInterruptedRecoveryBannerAccessibility() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/FileConverterMainView.swift")
        XCTAssertFalse(content.isEmpty)

        XCTAssertTrue(content.contains(".accessibilityLabel(\"Dismiss interrupted conversion alerts\")"))
    }
}
