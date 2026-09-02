import SwiftUI
import Combine
import FileConverterCore

/// Central source of truth for user preferences.
///
/// Every toggle in Settings writes here. Values persist in `UserDefaults`
/// under the legacy keys so existing installs migrate silently. `AppSettings`
/// also pushes concurrency changes into `ConversionQueue` and exposes
/// validated helpers so views never parse raw strings themselves.
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
            if defaultOutputPolicyRaw != "sameAsSource" && defaultOutputPolicyRaw != "downloads" {
                defaultOutputPolicyRaw = "sameAsSource"
            }
            UserDefaults.standard.set(defaultOutputPolicyRaw, forKey: Keys.defaultOutputPolicy)
        }
    }

    @Published public var defaultOverwritePolicyRaw: String {
        didSet {
            if OverwritePolicy(rawValue: defaultOverwritePolicyRaw) == nil {
                defaultOverwritePolicyRaw = OverwritePolicy.appendNumber.rawValue
            }
            UserDefaults.standard.set(defaultOverwritePolicyRaw, forKey: Keys.defaultOverwritePolicy)
        }
    }

    @Published public var preserveTimestamps: Bool {
        didSet { UserDefaults.standard.set(preserveTimestamps, forKey: Keys.preserveTimestamps) }
    }

    @Published public var enableNotifications: Bool {
        didSet { UserDefaults.standard.set(enableNotifications, forKey: Keys.enableNotifications) }
    }

    @Published public var revealInFinder: Bool {
        didSet { UserDefaults.standard.set(revealInFinder, forKey: Keys.revealInFinder) }
    }

    @Published public var maxConcurrentJobs: Int {
        didSet {
            maxConcurrentJobs = min(max(1, maxConcurrentJobs), 16)
            UserDefaults.standard.set(maxConcurrentJobs, forKey: Keys.maxConcurrentJobs)
            ConversionQueue.shared.setMaxConcurrency(maxConcurrentJobs)
        }
    }

    @Published public var defaultFilenamePattern: String {
        didSet {
            let trimmed = defaultFilenamePattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaultFilenamePattern = "{name}"
            }
            UserDefaults.standard.set(defaultFilenamePattern, forKey: Keys.defaultFilenamePattern)
        }
    }

    public var defaultOverwritePolicy: OverwritePolicy {
        OverwritePolicy(rawValue: defaultOverwritePolicyRaw) ?? .appendNumber
    }

    public static var systemDefaultConcurrency: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    public init() {
        UserDefaults.standard.register(defaults: [
            Keys.defaultOutputPolicy: "sameAsSource",
            Keys.defaultOverwritePolicy: OverwritePolicy.appendNumber.rawValue,
            Keys.preserveTimestamps: true,
            Keys.enableNotifications: true,
            Keys.revealInFinder: false,
            Keys.maxConcurrentJobs: Self.systemDefaultConcurrency,
            Keys.defaultFilenamePattern: "{name}",
        ])

        var outputRaw = UserDefaults.standard.string(forKey: Keys.defaultOutputPolicy) ?? "sameAsSource"
        if outputRaw != "sameAsSource" && outputRaw != "downloads" {
            outputRaw = "sameAsSource"
        }
        self.defaultOutputPolicyRaw = outputRaw

        let rawOverwrite = UserDefaults.standard.string(forKey: Keys.defaultOverwritePolicy)
        self.defaultOverwritePolicyRaw = OverwritePolicy(rawValue: rawOverwrite ?? "")?.rawValue ?? OverwritePolicy.appendNumber.rawValue

        self.preserveTimestamps = UserDefaults.standard.object(forKey: Keys.preserveTimestamps) as? Bool ?? true
        self.enableNotifications = UserDefaults.standard.object(forKey: Keys.enableNotifications) as? Bool ?? true
        self.revealInFinder = UserDefaults.standard.object(forKey: Keys.revealInFinder) as? Bool ?? false

        let storedConcurrency = UserDefaults.standard.integer(forKey: Keys.maxConcurrentJobs)
        let concurrency = (1...16).contains(storedConcurrency) ? storedConcurrency : Self.systemDefaultConcurrency
        self.maxConcurrentJobs = concurrency

        let pattern = UserDefaults.standard.string(forKey: Keys.defaultFilenamePattern) ?? "{name}"
        self.defaultFilenamePattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{name}" : pattern

        ConversionQueue.shared.setMaxConcurrency(concurrency)
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
}
