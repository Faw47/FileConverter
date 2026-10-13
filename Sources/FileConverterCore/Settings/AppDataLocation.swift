import Foundation

/// Where File Converter keeps its own files (journal, history, caches).
/// Under XCTest this is a per-process temporary folder, so test runs never
/// write into the user's real data and never show up as "interrupted"
/// conversions in the app.
public enum AppDataLocation {
    public static let isRunningTests = NSClassFromString("XCTestCase") != nil

    public static var directory: URL? {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("FileConverterTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FileConverter", isDirectory: true)
    }

    /// `directory/name`, creating the directory if needed.
    public static func file(_ name: String) -> URL? {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
