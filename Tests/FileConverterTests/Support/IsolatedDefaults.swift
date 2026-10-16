import Foundation
@testable import FileConverterCore

/// Runs `body` with `ConversionDefaults.store` swapped for an empty suite,
/// so a test can change General settings without touching any other test.
/// The suite is a plist in the per-process temp folder, not in
/// ~/Library/Preferences.
func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) rethrows -> T {
    let path = AppDataLocation.file("defaults-\(UUID().uuidString)")!.path
    let defaults = UserDefaults(suiteName: path)!
    let previous = ConversionDefaults.store
    ConversionDefaults.store = defaults
    defer {
        ConversionDefaults.store = previous
        defaults.removePersistentDomain(forName: path)
        try? FileManager.default.removeItem(atPath: path + ".plist")
    }
    return try body(defaults)
}
