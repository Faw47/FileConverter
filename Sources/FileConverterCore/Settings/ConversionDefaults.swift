import Foundation

/// The General settings that conversions inherit, read from one place.
/// The app writes these keys through `AppSettings`; Core only reads them.
public struct ConversionDefaults: Sendable, Equatable {
    public enum Keys {
        public static let outputDirectoryPolicy = "outputDirectoryPolicy"
        public static let legacyOutputDirectoryPolicy = "fc.defaultOutputPolicy"
        public static let overwritePolicy = "overwritePolicy"
        public static let filenamePattern = "fc.defaultFilenamePattern"
        public static let customOutputFolderBookmark = "fc.customOutputFolderBookmark"
        public static let customOutputFolderPath = "fc.customOutputFolderPath"
        public static let preserveCreationDate = "fc.preserveCreationDate"
        public static let preserveModificationDate = "fc.preserveModificationDate"
        /// Pre-split single toggle covering both dates.
        public static let legacyPreserveTimestamps = "preserveTimestamps"
        public static let removeLocationData = "fc.removeLocationData"
        public static let enableNotifications = "enableNotifications"
        public static let maxConcurrentJobs = "maxConcurrentJobs"
    }

    public var outputDirectoryPolicy: OutputDirectoryPolicy
    public var overwritePolicy: OverwritePolicy
    public var filenamePattern: String
    public var preserveCreationDate: Bool
    public var preserveModificationDate: Bool
    public var removeLocationData: Bool

    public init(
        outputDirectoryPolicy: OutputDirectoryPolicy = .sameAsSource,
        overwritePolicy: OverwritePolicy = .appendNumber,
        filenamePattern: String = "{name}",
        preserveCreationDate: Bool = true,
        preserveModificationDate: Bool = false,
        removeLocationData: Bool = true
    ) {
        self.outputDirectoryPolicy = outputDirectoryPolicy
        self.overwritePolicy = overwritePolicy
        self.filenamePattern = filenamePattern
        self.preserveCreationDate = preserveCreationDate
        self.preserveModificationDate = preserveModificationDate
        self.removeLocationData = removeLocationData
    }

    public static func load(from defaults: UserDefaults) -> ConversionDefaults {
        var result = ConversionDefaults()

        let policyRaw = defaults.string(forKey: Keys.outputDirectoryPolicy)
            ?? defaults.string(forKey: Keys.legacyOutputDirectoryPolicy)
            ?? "sameAsSource"
        switch policyRaw {
        case "downloads":
            result.outputDirectoryPolicy = .downloads
        case "custom":
            if let bookmark = defaults.data(forKey: Keys.customOutputFolderBookmark),
               let path = defaults.string(forKey: Keys.customOutputFolderPath),
               !path.isEmpty {
                result.outputDirectoryPolicy = .customFolder(bookmarkData: bookmark, displayPath: path)
            }
        default:
            break
        }

        if let raw = defaults.string(forKey: Keys.overwritePolicy), let policy = OverwritePolicy(rawValue: raw) {
            result.overwritePolicy = policy
        }

        if let pattern = defaults.string(forKey: Keys.filenamePattern),
           !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.filenamePattern = pattern
        }

        // The old single toggle meant "keep both dates". Migrate it to the
        // new defaults: creation date follows it, modification date becomes
        // fresh so new files sort to the top in Finder.
        let legacyTimestamps = defaults.object(forKey: Keys.legacyPreserveTimestamps) as? Bool
        if let creation = defaults.object(forKey: Keys.preserveCreationDate) as? Bool {
            result.preserveCreationDate = creation
        } else if let legacyTimestamps {
            result.preserveCreationDate = legacyTimestamps
        }
        if let modification = defaults.object(forKey: Keys.preserveModificationDate) as? Bool {
            result.preserveModificationDate = modification
        }

        if let removeLocation = defaults.object(forKey: Keys.removeLocationData) as? Bool {
            result.removeLocationData = removeLocation
        }
        return result
    }

    private static let storeBox = DefaultsBox()

    /// The defaults domain Core reads. Tests swap in an isolated suite so
    /// they never touch the user's real settings.
    public static var store: UserDefaults {
        get { storeBox.value }
        set { storeBox.value = newValue }
    }

    public static var current: ConversionDefaults {
        load(from: store)
    }
}

private final class DefaultsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UserDefaults = .standard

    var value: UserDefaults {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
