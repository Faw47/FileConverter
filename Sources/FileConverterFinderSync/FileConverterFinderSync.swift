import Cocoa
import FinderSync
import FileConverterContracts
import FileConverterFinderSupport
import os

private let finderLogger = Logger(subsystem: "io.fileconverter", category: "finder")

public class FileConverterFinderSync: FIFinderSync {

    public override init() {
        super.init()
        finderLogger.info("FileConverterFinderSync extension initializing...")
        let snapshotReady = FinderMenuCatalog.shared.hasUsableSnapshot
        let requestChannelReady = FinderRequestClient.isReady()
        finderLogger.notice(
            "Finder integration ready: snapshot=\(snapshotReady, privacy: .public), requestChannel=\(requestChannelReady, privacy: .public)"
        )

        // Monitor root file system so context menu activates on all files and folders
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]

        // Listen for presets updates from main app
        listenForPresetChanges()
    }

    // MARK: - Menu Generation

    public override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }

        guard let selectedURLs = FIFinderSyncController.default().selectedItemURLs(), !selectedURLs.isEmpty else {
            return nil
        }

        FinderMenuCatalog.shared.ensureFresh()

        let sections = FinderMenuCatalog.shared.sections(for: selectedURLs)

        let rootMenu = NSMenu(title: "File Converter")
        let mainMenuItem = NSMenuItem(title: "File Converter", action: nil, keyEquivalent: "")
        let subMenu = NSMenu(title: "File Converter Options")

        let isClientReady = FinderRequestClient.isReady()
        let hasSnapshot = FinderMenuCatalog.shared.hasUsableSnapshot

        if !isClientReady || !hasSnapshot {
            finderLogger.notice(
                "Menu setup required: isReady=\(isClientReady), hasSnapshot=\(hasSnapshot), snapshotError=\(FinderMenuCatalog.shared.lastErrorDescription ?? "none"), clientStatus=\(FinderRequestClient.statusDescription())"
            )
            let setupItem = NSMenuItem(
                title: "Open File Converter to Finish Setup",
                action: #selector(openConfigurationSelected(_:)),
                keyEquivalent: ""
            )
            setupItem.target = self
            subMenu.addItem(setupItem)
        } else if selectedURLs.count > ConversionRequestLimits.production.maximumSourceCount {
            let limitItem = NSMenuItem(title: "Maximum \(ConversionRequestLimits.production.maximumSourceCount) Files Supported", action: nil, keyEquivalent: "")
            limitItem.isEnabled = false
            subMenu.addItem(limitItem)
        } else if sections.isEmpty {
            let hasOnlyDirectories = selectedURLs.allSatisfy(\.hasDirectoryPath)
            let title = hasOnlyDirectories ? "Folders Cannot Be Converted" : "No Compatible Formats"
            let noItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            noItem.isEnabled = false
            subMenu.addItem(noItem)
        } else {
            for section in sections {
                let catItem = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
                let catSubMenu = NSMenu(title: section.title)

                for entry in section.entries {
                    let item = NSMenuItem(
                        title: entry.title,
                        action: #selector(conversionPresetSelected(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    // Finder serializes menu items between menu construction
                    // and invocation. Keep this value Foundation-bridgeable;
                    // custom NSObject payloads are discarded by Finder and
                    // leave the action without a preset identifier.
                    item.representedObject = entry.id.uuidString
                    catSubMenu.addItem(item)
                }

                catItem.submenu = catSubMenu
                subMenu.addItem(catItem)
            }
        }

        subMenu.addItem(NSMenuItem.separator())

        let configItem = NSMenuItem(
            title: "Configure Presets...",
            action: #selector(openConfigurationSelected(_:)),
            keyEquivalent: ""
        )
        configItem.target = self
        subMenu.addItem(configItem)

        mainMenuItem.submenu = subMenu
        rootMenu.addItem(mainMenuItem)

        return rootMenu
    }

    // MARK: - Actions

    @objc private func conversionPresetSelected(_ sender: NSMenuItem) {
        let selectedURLs = FIFinderSyncController.default().selectedItemURLs() ?? []
        let presetID = resolvePresetID(for: sender, selectedURLs: selectedURLs)

        guard let presetID, !selectedURLs.isEmpty else {
            finderLogger.error(
                "Finder conversion action had no usable preset or selection: preset=\(String(describing: presetID), privacy: .public), selectedCount=\(selectedURLs.count, privacy: .public)"
            )
            launchMainApp(openSettings: true)
            return
        }

        do {
            let configuration = try IPCConfiguration.current()
            finderLogger.notice(
                "Preparing Finder conversion request: preset=\(presetID.uuidString, privacy: .public), selectedCount=\(selectedURLs.count, privacy: .public)"
            )
            let sources = try selectedURLs.map { url in
                ConversionSourceDescriptor(
                    bookmarkData: try makeBookmarkData(for: url),
                    displayName: url.lastPathComponent,
                    lastKnownPath: url.path
                )
            }
            let request = ConversionRequest(
                edition: configuration.edition,
                presetID: presetID,
                sources: sources
            )
            try FinderRequestClient.send(request)
            finderLogger.notice(
                "Finder conversion request queued: id=\(request.id.uuidString, privacy: .public), preset=\(presetID.uuidString, privacy: .public)"
            )
            launchMainApp()
        } catch {
            finderLogger.error(
                "Failed to send Finder conversion request: \(error.localizedDescription, privacy: .public) (domain=\((error as NSError).domain, privacy: .public), code=\((error as NSError).code, privacy: .public))"
            )
            // A Finder extension cannot present an app-owned error sheet. Bring
            // the user to the setup screen instead of failing silently.
            launchMainApp(openSettings: true)
        }
    }

    private func makeBookmarkData(for url: URL) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // Finder supplies an implicit scope for the selected item. Keep
            // that scope active while asking Foundation to create the
            // explicit, read-only bookmark the host can persist.
            return try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Some macOS Finder builds expose only the implicit scope to a
            // Finder Sync extension. A plain bookmark preserves that scope;
            // SecurityScopedLease has a matching implicit-scope resolution
            // path, so do not turn a valid Finder selection into a silent
            // no-op just because explicit scope creation was denied.
            finderLogger.warning(
                "Explicit Finder bookmark denied; falling back to implicit scope: domain=\((error as NSError).domain, privacy: .public), code=\((error as NSError).code, privacy: .public)"
            )
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    private func resolvePresetID(for sender: NSMenuItem, selectedURLs: [URL]) -> UUID? {
        if let idString = sender.representedObject as? String,
           let id = UUID(uuidString: idString) {
            return id
        }

        // Finder may rebuild NSMenuItem instances for nested extension menus
        // and drop representedObject entirely. The visible title and parent
        // category survive that bridge, so resolve the preset from the same
        // snapshot used to build the menu.
        let sections = FinderMenuCatalog.shared.sections(for: selectedURLs)
        let section = sections.first { $0.title == sender.menu?.title }
        let candidates = (section?.entries ?? sections.flatMap { $0.entries })
            .filter { $0.title == sender.title }
        if let candidate = candidates.first {
            if candidates.count > 1 {
                if let menu = sender.menu, let entries = section?.entries {
                    let index = menu.index(of: sender)
                    if index >= 0 && index < entries.count {
                        let indexedCandidate = entries[index]
                        if indexedCandidate.title == sender.title {
                            return indexedCandidate.id
                        }
                    }
                }
                finderLogger.warning(
                    "Finder menu title matched multiple presets; using first: title=\(sender.title, privacy: .public), matches=\(candidates.count, privacy: .public)"
                )
            }
            return candidate.id
        }

        finderLogger.error(
            "Finder menu title did not resolve to a preset: title=\(sender.title, privacy: .public), section=\(String(describing: sender.menu?.title), privacy: .public)"
        )
        return nil
    }

    @objc private func openConfigurationSelected(_ sender: NSMenuItem) {
        launchMainApp(openSettings: true)
    }

    private func launchMainApp(openSettings: Bool = false) {
        guard let configuration = try? IPCConfiguration.current() else { return }

        let targetURL = openSettings
            ? URL(string: "\(configuration.urlScheme)://settings?tab=presets")
            : URL(string: "\(configuration.urlScheme)://queue")

        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: configuration.hostBundleIdentifier
        ) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = openSettings
            if let targetURL {
                NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: config) { _, error in
                    if let error {
                        finderLogger.error("Failed to open target URL with host app: \(error.localizedDescription, privacy: .public)")
                        let fallbackConfig = NSWorkspace.OpenConfiguration()
                        fallbackConfig.activates = openSettings
                        NSWorkspace.shared.openApplication(at: appURL, configuration: fallbackConfig, completionHandler: nil)
                    } else {
                        finderLogger.notice("Successfully notified host app (activates=\(openSettings))")
                    }
                }
            } else {
                finderLogger.notice("Opening host app directly with activates=\(openSettings)")
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            }
            return
        }

        if let targetURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = openSettings
            NSWorkspace.shared.open(targetURL, configuration: config, completionHandler: nil)
        } else {
            finderLogger.error("Could not locate the host app for Finder request handoff")
        }
    }

    private func listenForPresetChanges() {
        guard let configuration = try? IPCConfiguration.current() else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, name, _, _ in
                 guard let configuration = try? IPCConfiguration.current() else { return }
                if name?.rawValue as String? == configuration.finderMenuSnapshotNotificationName {
                    FinderMenuCatalog.shared.reload()
                }
            },
            configuration.finderMenuSnapshotNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveEveryObserver(center, observer)
    }
}
