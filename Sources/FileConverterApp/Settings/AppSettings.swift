import Combine
import FileConverterCore
import Foundation
import UserNotifications

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    /// Conversion keys are shared with Core (`ConversionDefaults.Keys`), which
    /// reads them; this type is the only writer.
    public enum Keys {
        public static let defaultOutputPolicy = ConversionDefaults.Keys.outputDirectoryPolicy
        public static let defaultOverwritePolicy = ConversionDefaults.Keys.overwritePolicy
        public static let preserveCreationDate = ConversionDefaults.Keys.preserveCreationDate
        public static let preserveModificationDate = ConversionDefaults.Keys.preserveModificationDate
        public static let legacyPreserveTimestamps = ConversionDefaults.Keys.legacyPreserveTimestamps
        public static let removeLocationData = ConversionDefaults.Keys.removeLocationData
        public static let enableNotifications = ConversionDefaults.Keys.enableNotifications
        public static let revealInFinder = "revealInFinderOnComplete"
        public static let maxConcurrentJobs = ConversionDefaults.Keys.maxConcurrentJobs
        public static let defaultFilenamePattern = ConversionDefaults.Keys.filenamePattern
        public static let selectedSettingsTab = "fc.selectedSettingsTab"
        public static let customOutputFolderBookmark = ConversionDefaults.Keys.customOutputFolderBookmark
        public static let customOutputFolderPath = ConversionDefaults.Keys.customOutputFolderPath
        public static let openWithBehavior = "fc.openWithBehavior"
        public static let showMenuBarExtra = "fc.showMenuBarExtra"
    }

    /// What happens when files arrive without a preset (Open With, Services,
    /// the Dock icon).
    public enum OpenWithBehavior: String, CaseIterable, Identifiable {
        case askWithLastChoice
        case convertWithLastChoice

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .askWithLastChoice: return "Ask, with my last choice selected"
            case .convertWithLastChoice: return "Convert right away with my last choice for that file type"
            }
        }
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

    @Published public var preserveCreationDate: Bool {
        didSet { defaults.set(preserveCreationDate, forKey: Keys.preserveCreationDate) }
    }

    @Published public var preserveModificationDate: Bool {
        didSet { defaults.set(preserveModificationDate, forKey: Keys.preserveModificationDate) }
    }

    @Published public var removeLocationData: Bool {
        didSet { defaults.set(removeLocationData, forKey: Keys.removeLocationData) }
    }

    @Published public var enableNotifications: Bool {
        didSet {
            defaults.set(enableNotifications, forKey: Keys.enableNotifications)
            if enableNotifications { refreshNotificationAuthorization(requestIfNeeded: true) }
        }
    }

    @Published public private(set) var notificationStatusText = "Checking notification access…"
    @Published public private(set) var notificationAuthorizationState: NotificationAuthorizationState = .checking

    @Published public var openWithBehavior: OpenWithBehavior {
        didSet { defaults.set(openWithBehavior.rawValue, forKey: Keys.openWithBehavior) }
    }

    @Published public var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: Keys.showMenuBarExtra) }
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

    /// Saved as given. Editing UI commits through `commitFilenamePattern`,
    /// which trims and validates once editing ends, never per keystroke.
    @Published public var defaultFilenamePattern: String {
        didSet {
            defaults.set(defaultFilenamePattern, forKey: Keys.defaultFilenamePattern)
        }
    }

    /// Characters that cannot appear in a filename pattern.
    public static let invalidPatternCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")

    /// Problem with a pattern, or nil when it is usable.
    public static func filenamePatternProblem(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.rangeOfCharacter(from: invalidPatternCharacters) != nil {
            return "Remove these characters: / : \\ ? % * | \" < >"
        }
        if !trimmed.contains("{name}") {
            return "Include {name} so converted files keep their original names."
        }
        return nil
    }

    /// Saves a pattern the user finished editing. Empty means "{name}".
    @discardableResult
    public func commitFilenamePattern(_ draft: String) -> Bool {
        guard Self.filenamePatternProblem(draft) == nil else { return false }
        defaultFilenamePattern = Self.normalizeFilenamePattern(draft)
        return true
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
            Keys.removeLocationData: true,
            Keys.showMenuBarExtra: true,
            Keys.enableNotifications: true,
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

        let conversionDefaults = ConversionDefaults.load(from: defaults)
        preserveCreationDate = conversionDefaults.preserveCreationDate
        preserveModificationDate = conversionDefaults.preserveModificationDate
        removeLocationData = conversionDefaults.removeLocationData
        enableNotifications = defaults.bool(forKey: Keys.enableNotifications)
        revealInFinder = defaults.bool(forKey: Keys.revealInFinder)
        openWithBehavior = OpenWithBehavior(rawValue: defaults.string(forKey: Keys.openWithBehavior) ?? "") ?? .askWithLastChoice
        showMenuBarExtra = defaults.bool(forKey: Keys.showMenuBarExtra)

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
        preserveCreationDate = true
        preserveModificationDate = false
        removeLocationData = true
        enableNotifications = true
        revealInFinder = false
        openWithBehavior = .askWithLastChoice
        showMenuBarExtra = true
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
