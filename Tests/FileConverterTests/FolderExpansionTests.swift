import XCTest
@testable import FileConverterCore

final class FolderExpansionTests: XCTestCase {
    func testFindsConvertibleFilesInSubfoldersAndSkipsTheRest() throws {
        let root = try BackendHarness.makeTempDirectory("FolderExpansion")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Trip/Day 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let top = try TestFixtures.copy("same_name/photo.png", to: root, as: "cover.png")
        let deep = try TestFixtures.copy("same_name/photo.png", to: nested, as: "beach.png")
        try Data("not a format".utf8).write(to: root.appendingPathComponent("notes.unknownext"))
        try Data().write(to: root.appendingPathComponent("empty.png"))
        _ = try TestFixtures.copy("same_name/photo.png", to: root, as: ".hidden.png")

        XCTAssertTrue(FolderExpansion.isPlainFolder(root))
        XCTAssertFalse(FolderExpansion.isPlainFolder(top))

        let result = FolderExpansion.convertibleFiles(in: [root])
        XCTAssertEqual(Set(result.files.map { $0.resolvingSymlinksInPath().path }),
                       Set([top, deep].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertFalse(result.wasTruncated)

        let limited = FolderExpansion.convertibleFiles(in: [root], limit: 1)
        XCTAssertEqual(limited.files.count, 1)
        XCTAssertTrue(limited.wasTruncated)
    }
}
