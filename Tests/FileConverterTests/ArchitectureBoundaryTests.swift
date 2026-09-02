import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testPackageManifestPreservesEditionAndFinderBoundaries() throws {
        let manifest = try read("Package.swift")
        let finderSupport = try section(
            in: manifest,
            from: "        .target(\n            name: \"FileConverterFinderSupport\"",
            to: "        .executableTarget("
        )
        let nativeApp = try section(
            in: manifest,
            from: "        .executableTarget(\n            name: \"FileConverterApp\"",
            to: "        .executableTarget(\n            name: \"FileConverterFinderSync\""
        )
        let finderExecutable = try section(
            in: manifest,
            from: "        .executableTarget(\n            name: \"FileConverterFinderSync\"",
            to: "        .testTarget("
        )

        assertFinderDependencies(finderSupport)
        assertFinderDependencies(finderExecutable)
        XCTAssertTrue(nativeApp.contains("\"FileConverterNativeBackends\""))
        XCTAssertFalse(nativeApp.contains("\"FileConverterExternalBackends\""))
        XCTAssertTrue(nativeApp.contains("\"Settings/ExternalToolsSettingsView.swift\""))
    }

    func testXcodeGenConfigurationPreservesEditionAndFinderBoundaries() throws {
        let project = try read("project.yml")
        let nativeApp = try section(
            in: project,
            from: "  FileConverterNative:\n",
            to: "  FileConverterNativeFinderExtension:\n"
        )
        let nativeFinder = try section(
            in: project,
            from: "  FileConverterNativeFinderExtension:\n",
            to: "  FileConverterExtended:\n"
        )
        let extendedApp = try section(
            in: project,
            from: "  FileConverterExtended:\n",
            to: "  FileConverterExtendedFinderExtension:\n"
        )
        let extendedFinder = try section(
            in: project,
            from: "  FileConverterExtendedFinderExtension:\n",
            to: "schemes:\n"
        )

        XCTAssertTrue(nativeApp.contains("product: FileConverterNativeBackends"))
        XCTAssertFalse(nativeApp.contains("product: FileConverterExternalBackends"))
        XCTAssertTrue(nativeApp.contains("Settings/ExternalToolsSettingsView.swift"))
        XCTAssertTrue(extendedApp.contains("product: FileConverterNativeBackends"))
        XCTAssertTrue(extendedApp.contains("product: FileConverterExternalBackends"))
        assertFinderDependencies(nativeFinder)
        assertFinderDependencies(extendedFinder)
    }

    func testFinderSourcesImportOnlyLeastPrivilegeModules() throws {
        for directory in ["Sources/FileConverterFinderSync", "Sources/FileConverterFinderSupport"] {
            for fileURL in try swiftFiles(in: directory) {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                XCTAssertFalse(source.contains("import FileConverterCore"), "Forbidden Core import in \(fileURL.path)")
                XCTAssertFalse(
                    source.contains("import FileConverterNativeBackends"),
                    "Forbidden NativeBackends import in \(fileURL.path)"
                )
                XCTAssertFalse(
                    source.contains("import FileConverterExternalBackends"),
                    "Forbidden ExternalBackends import in \(fileURL.path)"
                )
            }
        }
    }

    func testCoreContainsNoConcreteExternalBackendImplementation() throws {
        let forbidden = [
            "final class FFmpegBackend",
            "final class ImageMagickBackend",
            "final class LibreOfficeBackend",
            "final class GhostscriptBackend",
            "Process()"
        ]

        for fileURL in try swiftFiles(in: "Sources/FileConverterCore") {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "Forbidden implementation '\(token)' in \(fileURL.path)")
            }
        }
    }

    private func assertFinderDependencies(
        _ section: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(section.contains("FileConverterContracts"), file: file, line: line)
        XCTAssertTrue(section.contains("FileConverterFinderSupport"), file: file, line: line)
        XCTAssertFalse(section.contains("FileConverterCore"), file: file, line: line)
        XCTAssertFalse(section.contains("FileConverterNativeBackends"), file: file, line: line)
        XCTAssertFalse(section.contains("FileConverterExternalBackends"), file: file, line: line)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func swiftFiles(in relativeDirectory: String) throws -> [URL] {
        let directory = repositoryRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
