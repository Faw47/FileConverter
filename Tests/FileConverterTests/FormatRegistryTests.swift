import XCTest
import UniformTypeIdentifiers
@testable import FileConverterCore

final class FormatRegistryTests: XCTestCase {
    func testRegistryContainsStandardFormats() {
        let registry = FormatRegistry.shared

        // Video
        XCTAssertNotNil(registry.format(forID: "mp4"))
        XCTAssertNotNil(registry.format(forID: "mov"))
        XCTAssertNotNil(registry.format(forID: "mkv"))
        XCTAssertNotNil(registry.format(forID: "webm"))

        // Audio
        XCTAssertNotNil(registry.format(forID: "mp3"))
        XCTAssertNotNil(registry.format(forID: "aac"))
        XCTAssertNotNil(registry.format(forID: "m4a"))
        XCTAssertNotNil(registry.format(forID: "flac"))
        XCTAssertNotNil(registry.format(forID: "wav"))
        XCTAssertNotNil(registry.format(forID: "opus"))
        XCTAssertNotNil(registry.format(forID: "qta"))

        // Image
        XCTAssertNotNil(registry.format(forID: "png"))
        XCTAssertNotNil(registry.format(forID: "jpeg"))
        XCTAssertNotNil(registry.format(forID: "heic"))
        XCTAssertNotNil(registry.format(forID: "webp"))
        XCTAssertNotNil(registry.format(forID: "avif"))
        XCTAssertNotNil(registry.format(forID: "tiff"))
        XCTAssertNotNil(registry.format(forID: "gif"))

        // Document
        XCTAssertNotNil(registry.format(forID: "pdf"))
        XCTAssertNotNil(registry.format(forID: "docx"))
        XCTAssertNotNil(registry.format(forID: "txt"))
    }

    func testExtensionLookup() {
        let registry = FormatRegistry.shared
        XCTAssertEqual(registry.format(forExtension: "mp4")?.id, "mp4")
        XCTAssertEqual(registry.format(forExtension: "mov")?.id, "mov")
        XCTAssertEqual(registry.format(forExtension: "mkv")?.id, "mkv")
        XCTAssertEqual(registry.format(forExtension: "mp3")?.id, "mp3")
        XCTAssertEqual(registry.format(forExtension: "qta")?.id, "qta")
        XCTAssertEqual(registry.format(forExtension: "png")?.id, "png")
        XCTAssertEqual(registry.format(forExtension: "jpg")?.id, "jpeg")
        XCTAssertEqual(registry.format(forExtension: "jpeg")?.id, "jpeg")
        XCTAssertEqual(registry.format(forExtension: "pdf")?.id, "pdf")
        XCTAssertEqual(registry.format(forExtension: "pages")?.id, "pages")
        XCTAssertEqual(registry.format(forExtension: "ods")?.id, "ods")
        XCTAssertEqual(registry.format(forExtension: "key")?.id, "key")
    }

    func testUTTypeLookup() {
        let registry = FormatRegistry.shared
        XCTAssertEqual(registry.format(forUTType: UTType.png)?.id, "png")
        XCTAssertEqual(registry.format(forUTType: UTType.pdf)?.id, "pdf")
        XCTAssertEqual(registry.format(forUTType: UTType.mp3)?.id, "mp3")
    }

    func testContainerAliasesHaveCanonicalOwners() {
        let registry = FormatRegistry.shared

        XCTAssertEqual(registry.format(forExtension: "m4a")?.id, "m4a")
        XCTAssertNil(registry.format(forID: "alac"), "ALAC is a codec, not a container format")
        XCTAssertEqual(registry.format(forUTType: .quickTimeMovie)?.id, "mov")
        XCTAssertEqual(
            registry.format(forUTType: UTType(importedAs: "com.apple.quicktime-audio"))?.id,
            "qta"
        )
    }

    func testDuplicateExtensionRegistrationIsRejectedAtomically() {
        let registry = FormatRegistry()
        let duplicate = makeFormat(
            id: "duplicate-mp4",
            extension: "mp4",
            utType: "io.fileconverter.test.duplicate-mp4"
        )

        XCTAssertThrowsError(try registry.registerFormat(duplicate)) { error in
            XCTAssertEqual(
                error as? FormatRegistrationError,
                .duplicateExtension(alias: "mp4", existingFormatID: "mp4")
            )
        }
        XCTAssertNil(registry.format(forID: duplicate.id))
    }

    func testDuplicateUTTypeRegistrationIsRejectedAtomically() {
        let registry = FormatRegistry()
        let duplicate = makeFormat(
            id: "duplicate-quicktime",
            extension: "duplicate-quicktime",
            utType: UTType.quickTimeMovie.identifier
        )

        XCTAssertThrowsError(try registry.registerFormat(duplicate)) { error in
            XCTAssertEqual(
                error as? FormatRegistrationError,
                .duplicateUTType(
                    alias: UTType.quickTimeMovie.identifier,
                    existingFormatID: "mov"
                )
            )
        }
        XCTAssertNil(registry.format(forID: duplicate.id))
    }

    private func makeFormat(id: String, extension ext: String, utType: String) -> FormatDefinition {
        FormatDefinition(
            id: id,
            name: id,
            primaryExtension: ext,
            extensions: [ext],
            utTypeIdentifiers: [utType],
            category: .video,
            supportedInput: true,
            supportedOutput: true
        )
    }
}
