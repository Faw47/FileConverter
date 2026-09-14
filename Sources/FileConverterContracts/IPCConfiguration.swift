import Foundation
import Darwin

public enum ProductEdition: String, Codable, Sendable {
    case native
    case extended
}

public struct IPCConfiguration: Equatable, Sendable {
    public let appGroupID: String
    public let edition: ProductEdition
    public let hostBundleIdentifier: String
    public let keychainAccessGroup: String
    public let urlScheme: String
    public let localSharedContainerPath: String?

    public init(
        appGroupID: String,
        edition: ProductEdition,
        hostBundleIdentifier: String,
        keychainAccessGroup: String,
        urlScheme: String,
        localSharedContainerPath: String? = nil
    ) {
        self.appGroupID = appGroupID
        self.edition = edition
        self.hostBundleIdentifier = hostBundleIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.urlScheme = urlScheme
        self.localSharedContainerPath = localSharedContainerPath
    }

    public var conversionRequestNotificationName: String {
        "io.fileconverter.\(edition.rawValue).conversionRequestPending"
    }

    public var finderMenuSnapshotNotificationName: String {
        "io.fileconverter.\(edition.rawValue).finderMenuSnapshotChanged"
    }

    public func sharedContainerURL(fileManager: FileManager = .default) -> URL? {
        // A configured local path is an explicit product choice for local,
        // unsigned artifacts. FileManager may still return an App Group URL
        // for those builds even though the process cannot use it reliably.
        if let localSharedContainerPath, !localSharedContainerPath.isEmpty {
            let relativePath = localSharedContainerPath.hasPrefix("/") ? String(localSharedContainerPath.dropFirst()) : localSharedContainerPath
            let components = NSString(string: relativePath).pathComponents
            guard !relativePath.isEmpty,
                  components.count >= 1,
                  !components.contains(".."),
                  let homePath = Self.resolveUserHomeDirectory() else {
                return nil
            }
            return URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true)
        }
        return fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    private static func resolveUserHomeDirectory() -> String? {
        if let userRecord = getpwuid(getuid()), let homePath = userRecord.pointee.pw_dir {
            return String(cString: homePath)
        }
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty,
           let home = NSHomeDirectoryForUser(user) {
            return home
        }
        let sandboxHome = NSHomeDirectory()
        if let range = sandboxHome.range(of: "/Library/Containers/") {
            return String(sandboxHome[..<range.lowerBound])
        }
        return sandboxHome.isEmpty ? nil : sandboxHome
    }

    public static func current(bundle: Bundle = .main) throws -> IPCConfiguration {
        let candidateBundles: [Bundle] = [
            bundle,
            Bundle(for: BundleToken.self),
            Bundle(identifier: "io.fileconverter.app.findersync"),
            Bundle(identifier: "io.fileconverter.app")
        ].compactMap { $0 }

        for candidate in candidateBundles {
            if let config = tryParse(bundle: candidate) {
                return config
            }
        }
        throw IPCConfigurationError.missingBuildConfiguration
    }

    private static func tryParse(bundle: Bundle) -> IPCConfiguration? {
        guard let appGroupID = bundle.object(forInfoDictionaryKey: "FileConverterAppGroup") as? String,
              !appGroupID.isEmpty,
              let editionValue = bundle.object(forInfoDictionaryKey: "FileConverterEdition") as? String,
              let edition = ProductEdition(rawValue: editionValue),
              let hostBundleIdentifier = bundle.object(forInfoDictionaryKey: "FileConverterHostBundleIdentifier") as? String,
              !hostBundleIdentifier.isEmpty,
              let keychainAccessGroup = bundle.object(forInfoDictionaryKey: "FileConverterKeychainAccessGroup") as? String,
              !keychainAccessGroup.isEmpty,
              !keychainAccessGroup.contains("$("),
              let urlScheme = bundle.object(forInfoDictionaryKey: "FileConverterURLScheme") as? String,
              !urlScheme.isEmpty else {
            return nil
        }

        let localSharedContainerPath = bundle.object(
            forInfoDictionaryKey: "FileConverterLocalIPCPath"
        ) as? String

        return IPCConfiguration(
            appGroupID: appGroupID,
            edition: edition,
            hostBundleIdentifier: hostBundleIdentifier,
            keychainAccessGroup: keychainAccessGroup,
            urlScheme: urlScheme,
            localSharedContainerPath: localSharedContainerPath.flatMap { path in
                path.isEmpty || path.contains("$(") ? nil : path
            }
        )
    }
}

private final class BundleToken: NSObject {}

public enum IPCConfigurationError: LocalizedError, Sendable {
    case missingBuildConfiguration

    public var errorDescription: String? {
        "File Converter IPC is not configured for this product."
    }
}
