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

    /// The settings domain. Under XCTest this is an empty plist in
    /// `directory`: the standard domain of a test run is
    /// `com.apple.dt.xctest.tool`, shared by every parallel test process, so
    /// tests that changed a setting there could leave it changed for each
    /// other (and send output to ~/Downloads).
    public nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isRunningTests, let path = file("defaults")?.path,
              let defaults = UserDefaults(suiteName: path) else { return .standard }
        defaults.removePersistentDomain(forName: path)
        return defaults
    }()

    /// `directory/name`, creating the directory if needed.
    public static func file(_ name: String) -> URL? {
        guard let directory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}
