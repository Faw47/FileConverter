import Foundation
import AppKit

public enum FinderHostResolutionResult: Equatable, Sendable {
    case enclosingApp(URL)
    case singleInstalledApp(URL)
    case ambiguousInstalledApps(selected: URL, candidates: [URL])
    case notFound

    public var appURL: URL? {
        switch self {
        case .enclosingApp(let url),
             .singleInstalledApp(let url),
             .ambiguousInstalledApps(let url, _):
            return url
        case .notFound:
            return nil
        }
    }
}

/// Resolves the containing host application for the Finder Sync extension deterministically,
/// ensuring the actual enclosing `.app` is opened instead of an arbitrary installed copy.
public enum FinderHostResolver {

    /// Derives the containing application URL from the running bundle.
    /// If the extension is located inside `MyApp.app/Contents/PlugIns/MyExtension.appex`,
    /// navigating up three directory levels yields `MyApp.app`.
    public static func resolveContainingHostApp(
        extensionBundle: Bundle = .main,
        expectedBundleIdentifier: String
    ) -> URL? {
        resolveContainingHostAppWithDiagnostic(
            bundleURL: extensionBundle.bundleURL,
            expectedBundleIdentifier: expectedBundleIdentifier
        ).appURL
    }

    public static func resolveContainingHostApp(
        bundleURL: URL,
        expectedBundleIdentifier: String,
        bundleIdentifierProvider: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        installedAppsProvider: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    ) -> URL? {
        resolveContainingHostAppWithDiagnostic(
            bundleURL: bundleURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            bundleIdentifierProvider: bundleIdentifierProvider,
            installedAppsProvider: installedAppsProvider
        ).appURL
    }

    public static func resolveContainingHostAppWithDiagnostic(
        bundleURL: URL,
        expectedBundleIdentifier: String,
        bundleIdentifierProvider: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
        installedAppsProvider: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    ) -> FinderHostResolutionResult {
        // 1. Check if the running bundle is an .appex inside MyApp.app/Contents/PlugIns/
        if bundleURL.pathExtension == "appex" {
            let candidateAppURL = bundleURL
                .deletingLastPathComponent() // Contents/PlugIns
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // MyApp.app

            if candidateAppURL.pathExtension == "app",
               let ident = bundleIdentifierProvider(candidateAppURL),
               ident == expectedBundleIdentifier {
                return .enclosingApp(candidateAppURL)
            }
        }

        // 2. Fallback: Query installed applications by bundle identifier
        let installed = installedAppsProvider(expectedBundleIdentifier)
        if installed.count == 1, let single = installed.first {
            return .singleInstalledApp(single)
        } else if installed.count > 1 {
            // Ambiguity detected: prioritize currently running application if available
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: expectedBundleIdentifier)
            if let runningURL = running.first?.bundleURL, installed.contains(runningURL) {
                return .ambiguousInstalledApps(selected: runningURL, candidates: installed)
            }
            return .ambiguousInstalledApps(selected: installed[0], candidates: installed)
        }

        // 3. Last fallback: NSWorkspace urlForApplication
        if let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: expectedBundleIdentifier) {
            return .singleInstalledApp(fallback)
        }

        return .notFound
    }
}
