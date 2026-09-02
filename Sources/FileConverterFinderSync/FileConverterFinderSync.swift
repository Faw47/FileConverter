import Cocoa
import FinderSync
import FileConverterContracts
import FileConverterFinderSupport
import os

private let finderLogger = Logger(subsystem: "io.fileconverter", category: "finder")

@objc(FileConverterFinderSync)
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

        let sections = FinderMenuCatalog.shared.sections(for: selectedURLs)

        let rootMenu = NSMenu(title: "File Converter")
        let mainMenuItem = NSMenuItem(title: "File Converter", action: nil, keyEquivalent: "")
        let subMenu = NSMenu(title: "File Converter Options")

        if !FinderRequestClient.isReady() || !FinderMenuCatalog.shared.hasUsableSnapshot {
            let setupItem = NSMenuItem(
                title: "Open File Converter to Finish Setup",
                action: #selector(openConfigurationSelected(_:)),
                keyEquivalent: ""
            )
            setupItem.target = self
            subMenu.addItem(setupItem)
        } else if sections.isEmpty {
            let noItem = NSMenuItem(title: "No Compatible Formats", action: nil, keyEquivalent: "")
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
        guard let idString = sender.representedObject as? String,
              let presetID = UUID(uuidString: idString),
              let selectedURLs = FIFinderSyncController.default().selectedItemURLs(),
              !selectedURLs.isEmpty else {
            return
        }

        do {
            let configuration = try IPCConfiguration.current()
            let sources = try selectedURLs.map { url in
                ConversionSourceDescriptor(
                    bookmarkData: try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ),
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
            launchMainApp()
        } catch {
            finderLogger.error("Failed to send conversion request: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func openConfigurationSelected(_ sender: NSMenuItem) {
        launchMainApp(openSettings: true)
    }

    private func launchMainApp(openSettings: Bool = false) {
        guard let configuration = try? IPCConfiguration.current() else { return }

        if openSettings,
           let settingsURL = URL(string: "\(configuration.urlScheme)://settings?tab=presets") {
            NSWorkspace.shared.open(settingsURL)
            return
        }

        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: configuration.hostBundleIdentifier
        ) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        } else {
            if let schemeURL = URL(string: "\(configuration.urlScheme)://queue") {
                NSWorkspace.shared.open(schemeURL)
            }
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
}
