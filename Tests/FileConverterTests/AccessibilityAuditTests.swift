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
        for label in [
            "Compression level", "Turn pages into images", "Convert to grayscale",
            "Image resolution in dots per inch", "JPEG image quality", "Remove document details",
            "Remove comments and highlights", "Optimize for fast web viewing", "Filename ending",
            "Change output folder", "Cancel compression", "Start PDF compression"
        ] {
            XCTAssertTrue(content.contains(".accessibilityLabel(\"\(label)\")"), label)
        }
        XCTAssertFalse(content.contains("lossless vector"), "native compression is not lossless")
        XCTAssertTrue(content.contains("inheritance.filenamePattern = false"), "dialog values must not be overridden by General")
    }

    func testPDFSplitDialogHasComprehensiveAccessibility() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/Dialogs/PDFSplitDialogView.swift")
        XCTAssertFalse(content.isEmpty)

        // Native controls are announced by their titles: the per-file page
        // field is titled with the file name, the mode is a titled picker.
        XCTAssertTrue(content.contains("\"Pages for \\(item.url.lastPathComponent)\""))
        XCTAssertTrue(content.contains(".accessibilityLabel(\"Remove \\(item.url.lastPathComponent)\")"))
        XCTAssertTrue(content.contains("Picker(\"Split into\""))
        XCTAssertFalse(content.contains("Picker(\"\""), "every picker needs a title")
    }

    func testCollisionResolutionHasAccessibilityAndKeyShortcuts() {
        let content = sourceFileContents(relativePath: "Sources/FileConverterApp/UI/Dialogs/CollisionResolutionView.swift")
        XCTAssertFalse(content.isEmpty)

        XCTAssertTrue(content.contains(".accessibilityLabel(\"Conflict for \\(conflict.sourceFilename)\")"))
        // The button's own title says what it does; VoiceOver reads it as is.
        XCTAssertTrue(content.contains("\"Cancel Conversion\" : \"Cancel Conversions\""))
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
