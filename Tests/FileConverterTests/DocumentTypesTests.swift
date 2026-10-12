import XCTest
@testable import FileConverterCore

/// The app registers only for files it can convert, so it appears in
/// "Open With" and Services for those files and nothing else.
final class DocumentTypesTests: XCTestCase {
    static var supportedInputTypes: [String] {
        Array(Set(FormatRegistry.shared.allFormats()
            .filter(\.supportedInput)
            .flatMap(\.utTypeIdentifiers)))
            .sorted()
    }

    private func plist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileConverterApp/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testDocumentTypesMatchSupportedInputs() throws {
        let types = try XCTUnwrap((try plist()["CFBundleDocumentTypes"] as? [[String: Any]])?.first?["LSItemContentTypes"] as? [String])
        XCTAssertFalse(types.contains("public.item"))
        XCTAssertFalse(types.contains("public.data"))
        XCTAssertFalse(types.contains("public.content"))
        XCTAssertEqual(types.sorted(), Self.supportedInputTypes,
                       "Update Info.plist LSItemContentTypes to:\n" + Self.supportedInputTypes.map { "<string>\($0)</string>" }.joined(separator: "\n"))
    }

    func testServiceIsNamedAndScopedToSupportedInputs() throws {
        let service = try XCTUnwrap((try plist()["NSServices"] as? [[String: Any]])?.first)
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Convert with File Converter…")
        let types = try XCTUnwrap(service["NSSendFileTypes"] as? [String])
        XCTAssertEqual(types.sorted(), Self.supportedInputTypes)
    }
}
