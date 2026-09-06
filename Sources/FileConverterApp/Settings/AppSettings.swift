import Combine
import FileConverterCore
import Foundation
import UserNotifications

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
        public static let customOutputFolderBookmark = "fc.customOutputFolderBookmark"
        public static let customOutputFolderPath = "fc.customOutputFolderPath"
    }

    public enum NotificationAuthorizationState: Equatable {
        case checking
        case notDetermined
        case authorized
        case denied
        case unavailable
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

    @Published public var customOutputFolderPath: String {
        didSet {
            defaults.set(customOutputFolderPath, forKey: Keys.customOutputFolderPath)
        }
    }

    @Published public var customOutputFolderBookmark: Data? {
        didSet {
            defaults.set(customOutputFolderBookmark, forKey: Keys.customOutputFolderBookmark)
        }
    }

    @Published public private(set) var customOutputFolderError: String?

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
        didSet {
            defaults.set(enableNotifications, forKey: Keys.enableNotifications)
            if enableNotifications { refreshNotificationAuthorization(requestIfNeeded: true) }
        }
    }

    @Published public private(set) var notificationStatusText = "Checking notification access…"
    @Published public private(set) var notificationAuthorizationState: NotificationAuthorizationState = .checking

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

    public var defaultOutputPolicy: OutputDirectoryPolicy {
        switch defaultOutputPolicyRaw {
        case "downloads":
            return .downloads
        case "custom":
            if let bookmark = customOutputFolderBookmark, !customOutputFolderPath.isEmpty {
                return .customFolder(bookmarkData: bookmark, displayPath: customOutputFolderPath)
            }
            return .sameAsSource
        default:
            return .sameAsSource
        }
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
            Keys.enableNotifications: false,
            Keys.revealInFinder: false,
            Keys.maxConcurrentJobs: Self.systemDefaultConcurrency,
            Keys.defaultFilenamePattern: "{name}",
            Keys.customOutputFolderPath: "",
        ])

        defaultOutputPolicyRaw = Self.normalizeOutputPolicy(
            defaults.string(forKey: Keys.defaultOutputPolicy) ?? "sameAsSource"
        )
        defaultOverwritePolicyRaw = Self.normalizeOverwritePolicy(
            defaults.string(forKey: Keys.defaultOverwritePolicy) ?? OverwritePolicy.appendNumber.rawValue
        )
        customOutputFolderPath = defaults.string(forKey: Keys.customOutputFolderPath) ?? ""
        customOutputFolderBookmark = defaults.data(forKey: Keys.customOutputFolderBookmark)
        customOutputFolderError = nil

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
        refreshNotificationAuthorization(requestIfNeeded: false)
    }

    @discardableResult
    public func setCustomOutputFolder(url: URL) -> Bool {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            customOutputFolderBookmark = bookmark
            customOutputFolderPath = url.path
            defaultOutputPolicyRaw = "custom"
            defaults.set(bookmark, forKey: Keys.customOutputFolderBookmark)
            defaults.set(url.path, forKey: Keys.customOutputFolderPath)
            customOutputFolderError = nil
            return true
        } catch {
            // Never persist a custom policy without a valid security-scoped
            // bookmark; doing so silently falls back to the source directory.
            customOutputFolderBookmark = nil
            customOutputFolderPath = ""
            defaultOutputPolicyRaw = "sameAsSource"
            customOutputFolderError = "Could not secure access to that folder. Choose it again."
            return false
        }
    }

    public func resetAllToDefaults() {
        defaultOutputPolicyRaw = "sameAsSource"
        defaultOverwritePolicyRaw = OverwritePolicy.appendNumber.rawValue
        customOutputFolderPath = ""
        customOutputFolderBookmark = nil
        customOutputFolderError = nil
        preserveTimestamps = true
        enableNotifications = false
        revealInFinder = false
        defaultFilenamePattern = "{name}"
        maxConcurrentJobs = Self.systemDefaultConcurrency
    }

    public func refreshNotificationAuthorization(requestIfNeeded: Bool) {
        // The snapshot runner and SwiftPM executable are intentionally not
        // packaged app bundles. UserNotifications relies on an application
        // bundle proxy, so asking it for settings in those development modes
        // terminates the process before a visual test can render.
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            notificationStatusText = "Notification access is available in the packaged app."
            notificationAuthorizationState = .unavailable
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let status: String
            let state: NotificationAuthorizationState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                status = "Notifications are allowed."
                state = .authorized
            case .denied:
                status = "Notifications are blocked in System Settings."
                state = .denied
            case .notDetermined:
                status = "Notification access has not been requested."
                state = .notDetermined
            @unknown default:
                status = "Notification access is unavailable."
                state = .unavailable
            }
            Task { @MainActor in
                self?.notificationStatusText = status
                self?.notificationAuthorizationState = state
            }
        }
        if requestIfNeeded {
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshNotificationAuthorization(requestIfNeeded: false)
                }
            }
        }
    }

    public func requestNotificationAuthorization() {
        refreshNotificationAuthorization(requestIfNeeded: true)
    }

    private static func normalizeOutputPolicy(_ value: String) -> String {
        switch value {
        case "downloads": return "downloads"
        case "custom": return "custom"
        default: return "sameAsSource"
        }
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
