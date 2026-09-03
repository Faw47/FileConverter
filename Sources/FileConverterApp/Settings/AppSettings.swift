import Combine
import FileConverterCore
import Foundation

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    public enum Keys {
        public static let defaultOutputPolicy = "outputDirectoryPolicy"
        public static let defaultOverwritePolicy = "overwritePolicy"
        public static let preserveTimestamps = "preserveTimestamps"
        public static let enableNotifications = "enableNotifications"
        public static let revealInFinder = "revealInFinderOnComplete"
        public static let maxConcurrentJobs = "maxConcurrentJobs"
        public static let defaultFilenamePattern = "fc.defaultFilenamePattern"
        public static let selectedSettingsTab = "fc.selectedSettingsTab"
    }

    @Published public var defaultOutputPolicyRaw: String {
        didSet {
            let normalized = Self.normalizeOutputPolicy(defaultOutputPolicyRaw)
            if normalized != defaultOutputPolicyRaw {
                defaultOutputPolicyRaw = normalized
                return
            }
            defaults.set(defaultOutputPolicyRaw, forKey: Keys.defaultOutputPolicy)
        }
    }

    @Published public var defaultOverwritePolicyRaw: String {
        didSet {
            let normalized = Self.normalizeOverwritePolicy(defaultOverwritePolicyRaw)
            if normalized != defaultOverwritePolicyRaw {
                defaultOverwritePolicyRaw = normalized
                return
            }
            defaults.set(defaultOverwritePolicyRaw, forKey: Keys.defaultOverwritePolicy)
        }
    }

    @Published public var preserveTimestamps: Bool {
        didSet { defaults.set(preserveTimestamps, forKey: Keys.preserveTimestamps) }
    }

    @Published public var enableNotifications: Bool {
        didSet { defaults.set(enableNotifications, forKey: Keys.enableNotifications) }
    }

    @Published public var revealInFinder: Bool {
        didSet { defaults.set(revealInFinder, forKey: Keys.revealInFinder) }
    }

    @Published public var maxConcurrentJobs: Int {
        didSet {
            let normalized = Self.normalizeConcurrency(maxConcurrentJobs)
            if normalized != maxConcurrentJobs {
                maxConcurrentJobs = normalized
                return
            }
            defaults.set(maxConcurrentJobs, forKey: Keys.maxConcurrentJobs)
            ConversionQueue.shared.setMaxConcurrency(maxConcurrentJobs)
        }
    }

    @Published public var defaultFilenamePattern: String {
        didSet {
            let normalized = Self.normalizeFilenamePattern(defaultFilenamePattern)
            if normalized != defaultFilenamePattern {
                defaultFilenamePattern = normalized
                return
            }
            defaults.set(defaultFilenamePattern, forKey: Keys.defaultFilenamePattern)
        }
    }

    private let defaults: UserDefaults

    public var defaultOverwritePolicy: OverwritePolicy {
        OverwritePolicy(rawValue: defaultOverwritePolicyRaw) ?? .appendNumber
    }

    public static var systemDefaultConcurrency: Int {
        normalizeConcurrency(max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            Keys.defaultOutputPolicy: "sameAsSource",
            Keys.defaultOverwritePolicy: OverwritePolicy.appendNumber.rawValue,
            Keys.preserveTimestamps: true,
            Keys.enableNotifications: true,
            Keys.revealInFinder: false,
            Keys.maxConcurrentJobs: Self.systemDefaultConcurrency,
            Keys.defaultFilenamePattern: "{name}",
        ])

        defaultOutputPolicyRaw = Self.normalizeOutputPolicy(
            defaults.string(forKey: Keys.defaultOutputPolicy) ?? "sameAsSource"
        )
        defaultOverwritePolicyRaw = Self.normalizeOverwritePolicy(
            defaults.string(forKey: Keys.defaultOverwritePolicy) ?? OverwritePolicy.appendNumber.rawValue
        )
        preserveTimestamps = defaults.bool(forKey: Keys.preserveTimestamps)
        enableNotifications = defaults.bool(forKey: Keys.enableNotifications)
        revealInFinder = defaults.bool(forKey: Keys.revealInFinder)

        let storedConcurrency = defaults.integer(forKey: Keys.maxConcurrentJobs)
        maxConcurrentJobs = storedConcurrency == 0
            ? Self.systemDefaultConcurrency
            : Self.normalizeConcurrency(storedConcurrency)

        defaultFilenamePattern = Self.normalizeFilenamePattern(
            defaults.string(forKey: Keys.defaultFilenamePattern) ?? "{name}"
        )

        ConversionQueue.shared.setMaxConcurrency(maxConcurrentJobs)
    }

    public func resetAllToDefaults() {
        defaultOutputPolicyRaw = "sameAsSource"
        defaultOverwritePolicyRaw = OverwritePolicy.appendNumber.rawValue
        preserveTimestamps = true
        enableNotifications = true
        revealInFinder = false
        defaultFilenamePattern = "{name}"
        maxConcurrentJobs = Self.systemDefaultConcurrency
    }

    private static func normalizeOutputPolicy(_ value: String) -> String {
        value == "downloads" ? "downloads" : "sameAsSource"
    }

    private static func normalizeOverwritePolicy(_ value: String) -> String {
        OverwritePolicy(rawValue: value)?.rawValue ?? OverwritePolicy.appendNumber.rawValue
    }

    private static func normalizeConcurrency(_ value: Int) -> Int {
        min(max(1, value), 16)
    }

    private static func normalizeFilenamePattern(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "{name}" : trimmed
    }
}
