import Foundation
import FileConverterContracts

public enum PresetStoreError: Error, LocalizedError, Sendable {
    case appGroupContainerUnavailable(String)
    case storageUnavailable
    case readOnlyExtension
    case invalidPresetDocument
    case invalidPreset(reason: String)
    case recoveryRequired(reason: String)
    case backupNotFound(URL)
    case backupCorrupted(URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .appGroupContainerUnavailable(let identifier):
            return "The preset App Group container is unavailable: \(identifier)"
        case .storageUnavailable:
            return "Application Support directory is unavailable."
        case .readOnlyExtension:
            return "Finder extensions cannot modify presets."
        case .invalidPresetDocument:
            return "The preset export is not a supported File Converter document."
        case .invalidPreset(let reason):
            return "The preset export contains an invalid preset: \(reason)"
        case .recoveryRequired(let reason):
            return "Preset store requires recovery: \(reason)"
        case .backupNotFound(let url):
            return "Preset backup file not found at \(url.lastPathComponent)"
        case .backupCorrupted(let url, let reason):
            return "Preset backup at \(url.lastPathComponent) is invalid: \(reason)"
        }
    }
}

private struct PresetStoreDocument: Codable {
    let schemaVersion: Int
    let presets: [ConversionPreset]

    init(schemaVersion: Int = 2, presets: [ConversionPreset]) {
        self.schemaVersion = schemaVersion
        self.presets = presets
    }
}

public final class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()

    public static let presetsFileName = "presets.json"

    private var cachedPresets: [ConversionPreset] = []
    private var cachedErrorDescription: String?
    private var cachedQuarantineWarning: String?
    private var cachedImportWarning: String?
    private var hasLoadedPresetsSuccessfully = false
    private var lastSaveSucceededValue = true
    private var currentState: PresetStoreState = .loading
    private let lock = NSLock()
    private let storageURLOverride: URL?
    private let postsDarwinNotifications: Bool
    private let snapshotWriterOverride: (([ConversionPreset]) throws -> Void)?

    public init(
        storageURL: URL? = nil,
        postsDarwinNotifications: Bool = true,
        snapshotWriterOverride: (([ConversionPreset]) throws -> Void)? = nil
    ) {
        self.storageURLOverride = storageURL
        self.postsDarwinNotifications = postsDarwinNotifications
        self.snapshotWriterOverride = snapshotWriterOverride
        loadPresets()
    }

    public var state: PresetStoreState {
        lock.withLock { currentState }
    }

    public var presets: [ConversionPreset] {
        lock.withLock { cachedPresets }
    }

    public var enabledPresets: [ConversionPreset] {
        lock.withLock { cachedPresets.filter(\.isEnabled) }
    }

    public var lastErrorDescription: String? {
        lock.withLock { cachedErrorDescription ?? cachedQuarantineWarning }
    }

    public var lastSaveSucceeded: Bool {
        lock.withLock { lastSaveSucceededValue }
    }

    public var lastImportWarning: String? {
        lock.withLock { cachedImportWarning }
    }

    public func clearLastImportWarning() {
        lock.withLock { cachedImportWarning = nil }
    }

    public func preset(forID id: UUID) -> ConversionPreset? {
        lock.withLock { cachedPresets.first { $0.id == id } }
    }

    public func loadPresets() {
        let fileURL: URL
        do {
            fileURL = try storageFileURL()
        } catch {
            let recoveryCtx = PresetStoreRecoveryContext(
                errorDescription: error.localizedDescription,
                sourceFileURL: URL(fileURLWithPath: "presets.json"),
                backupCandidates: []
            )
            lock.withLock {
                hasLoadedPresetsSuccessfully = false
                cachedQuarantineWarning = nil
                currentState = .recoveryRequired(recoveryCtx)
                lastSaveSucceededValue = false
            }
            record(error)
            return
        }

        do {
            let loaded: [ConversionPreset]
            let needsSave: Bool
            var quarantineMessage: String?

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let decoded = try decodePresets(data)
                // Migrate legacy built-ins first: older versions lacked stable
                // keys and could contain stale matching rules. `mergeBuiltIns`
                // restores factory rules while preserving user state, so legacy
                // entries are not mistaken for malformed customs.
                let merged = mergeBuiltIns(into: decoded)
                // Quarantine malformed custom records instead of rejecting the
                // whole file: preserve built-ins and every valid custom preset
                // with a visible diagnostic. The last-known-good in-memory
                // collection is retained when nothing valid remains.
                let (validDecoded, quarantined) = quarantineInvalidPresets(merged)
                if validDecoded.isEmpty {
                    throw PresetStoreError.invalidPreset(
                        reason: quarantined.isEmpty
                            ? "No presets found."
                            : "All stored presets are invalid: \(quarantined.joined(separator: ", "))."
                    )
                }
                if !quarantined.isEmpty {
                    quarantineMessage = "Quarantined \(quarantined.count) invalid preset(s): \(quarantined.joined(separator: ", ")). Valid presets were preserved."
                }
                loaded = validDecoded.sorted(by: presetSort)
                try validatePresetCollection(loaded)
                // Quarantine is deliberately non-destructive: the decoded file
                // remains the evidence of what was stored, while the filtered
                // collection is used in memory. An explicit user save may later
                // rewrite it, with the normal rotating backup protection.
                needsSave = quarantined.isEmpty
                    && (loaded != decoded || (try? JSONDecoder().decode(PresetStoreDocument.self, from: data)) == nil)
            } else {
                loaded = BuiltInPresets.makeDefaultPresets()
                needsSave = true
            }

            lock.withLock {
                cachedPresets = loaded
                cachedErrorDescription = nil
                cachedQuarantineWarning = quarantineMessage
                hasLoadedPresetsSuccessfully = true
                currentState = .ready
                lastSaveSucceededValue = true
            }
            if let quarantineMessage {
                AppLogger.presets.warning("\(quarantineMessage, privacy: .public)")
            }

            if needsSave, !isExtensionProcess {
                try persist(loaded)
            }
        } catch {
            let backupCandidates = discoverBackupCandidates(for: fileURL)
            let recoveryCtx = PresetStoreRecoveryContext(
                errorDescription: error.localizedDescription,
                sourceFileURL: fileURL,
                backupCandidates: backupCandidates
            )
            lock.withLock {
                hasLoadedPresetsSuccessfully = false
                cachedQuarantineWarning = nil
                currentState = .recoveryRequired(recoveryCtx)
                lastSaveSucceededValue = false
            }
            record(error)
        }
    }

    public func savePresets(_ newPresets: [ConversionPreset]) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        let sorted = newPresets.sorted(by: presetSort)
        try persistAndNotifyThrowing(sorted)
    }

    @discardableResult
    public func publishFinderMenuSnapshot() -> Bool {
        guard lock.withLock({ hasLoadedPresetsSuccessfully }) else { return false }
        do {
            if let snapshotWriterOverride {
                try snapshotWriterOverride(presets)
            } else {
                try FinderMenuSnapshotWriter.write(presets: presets, resolver: .shared)
            }
            lock.withLock { cachedErrorDescription = nil }
            postNotification()
            return true
        } catch {
            record(error)
            return false
        }
    }

    public func addPreset(_ preset: ConversionPreset) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        var customPreset = preset
        customPreset.builtInKey = nil
        customPreset.isBuiltIn = false

        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = cachedPresets
            if result.contains(where: { $0.id == customPreset.id }) {
                customPreset.id = UUID()
            }
            result.append(customPreset)
            return result.sorted(by: presetSort)
        }
        try persistAndNotifyThrowing(updated)
    }

    public func updatePreset(_ preset: ConversionPreset) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        var normalized = preset
        if normalized.isBuiltIn, let key = normalized.builtInKey {
            normalized.builtInKey = key
        } else {
            normalized.builtInKey = nil
            normalized.isBuiltIn = false
        }
        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = cachedPresets
            if let index = result.firstIndex(where: { $0.id == normalized.id }) {
                result[index] = normalized
            } else {
                result.append(normalized)
            }
            return result.sorted(by: presetSort)
        }
        try persistAndNotifyThrowing(updated)
    }

    public func deletePreset(withID id: UUID) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        let updated = lock.withLock { () -> [ConversionPreset] in
            var result = cachedPresets
            if let index = result.firstIndex(where: { $0.id == id }) {
                if result[index].isBuiltIn {
                    result[index].isEnabled = false
                } else {
                    result.remove(at: index)
                }
            }
            return result
        }
        try persistAndNotifyThrowing(updated)
    }

    public func restoreBuiltIn(withID id: UUID) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        guard let stored = preset(forID: id) else {
            throw PresetStoreError.invalidPreset(reason: "Preset not found.")
        }
        guard stored.isBuiltIn,
              let key = stored.builtInKey,
              let factory = BuiltInPresets.makeDefaultPresets().first(where: { $0.builtInKey == key }) else {
            throw PresetStoreError.invalidPreset(reason: "Preset is not a restorable built-in preset.")
        }
        var restored = factory
        restored.isEnabled = true
        restored.sortOrder = stored.sortOrder
        try updatePreset(restored)
    }

    public func duplicatePreset(withID id: UUID) throws -> ConversionPreset? {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        let duplicated = lock.withLock { () -> ConversionPreset? in
            guard let original = cachedPresets.first(where: { $0.id == id }) else {
                return nil
            }

            var copy = original
            copy.id = UUID()
            copy.builtInKey = nil
            copy.name = "\(original.name) (Copy)"
            copy.menuName = "\(original.menuName) (Copy)"
            copy.isBuiltIn = false
            copy.sortOrder = original.sortOrder + 1
            return copy
        }

        if let duplicated {
            let updated = lock.withLock { () -> [ConversionPreset] in
                var result = cachedPresets
                result.append(duplicated)
                return result.sorted(by: presetSort)
            }
            try persistAndNotifyThrowing(updated)
        }
        return duplicated
    }

    public func resetToDefaults() throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        try savePresets(BuiltInPresets.makeDefaultPresets())
    }

    public func reorderPresets(withIDs ids: [UUID]) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        let updated = lock.withLock { () -> [ConversionPreset] in
            var lookup = Dictionary(uniqueKeysWithValues: cachedPresets.map { ($0.id, $0) })
            var ordered: [ConversionPreset] = []
            var currentSort = 0
            for id in ids {
                if var preset = lookup.removeValue(forKey: id) {
                    preset.sortOrder = currentSort
                    currentSort += 1
                    ordered.append(preset)
                }
            }
            for (_, var preset) in lookup.sorted(by: { $0.value.sortOrder < $1.value.sortOrder }) {
                preset.sortOrder = currentSort
                currentSort += 1
                ordered.append(preset)
            }
            return ordered
        }
        try persistAndNotifyThrowing(updated)
    }

    public func exportPresetsJSON(includeLocalPaths: Bool = false) throws -> Data {
        return try PresetExchange.exportAll(presets: presets, includeLocalPaths: includeLocalPaths)
    }

    public func exportPresetJSON(withID id: UUID, includeLocalPaths: Bool = false) throws -> Data {
        guard let p = preset(forID: id) else {
            throw PresetStoreError.invalidPreset(reason: "Preset not found.")
        }
        return try PresetExchange.exportSingle(preset: p, includeLocalPaths: includeLocalPaths)
    }

    public func exportDamagedData() throws -> Data {
        let primaryURL = try storageFileURL()
        guard FileManager.default.fileExists(atPath: primaryURL.path) else {
            throw PresetStoreError.storageUnavailable
        }
        return try Data(contentsOf: primaryURL)
    }

    public func discoverBackupCandidates() throws -> [PresetBackupCandidate] {
        let fileURL = try storageFileURL()
        return discoverBackupCandidates(for: fileURL)
    }

    public func discoverBackupCandidates(for fileURL: URL) -> [PresetBackupCandidate] {
        let directory = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        var candidates: [PresetBackupCandidate] = []
        for index in 1...5 {
            let backupURL = directory.appendingPathComponent("presets.backup.\(index).json")
            guard fm.fileExists(atPath: backupURL.path) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: backupURL.path)
            let modDate = attrs?[.modificationDate] as? Date
            var isValid = false
            var presetCount = 0
            if let data = try? Data(contentsOf: backupURL),
               let decoded = try? decodePresets(data) {
                let (validDecoded, _) = quarantineInvalidPresets(decoded)
                if !validDecoded.isEmpty && (try? validatePresetCollection(validDecoded)) != nil {
                    isValid = true
                    presetCount = validDecoded.count
                }
            }
            candidates.append(PresetBackupCandidate(
                url: backupURL,
                backupNumber: index,
                modificationDate: modDate,
                presetCount: presetCount,
                isValid: isValid
            ))
        }
        return candidates
    }

    public func restoreFromBackup(url: URL) throws {
        let primaryURL = try storageFileURL()
        let fm = FileManager.default

        let directory = primaryURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let requestedDir = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard requestedDir.path == directory.path,
              url.lastPathComponent.hasPrefix("presets.backup."),
              url.pathExtension == "json" else {
            throw PresetStoreError.backupCorrupted(url, reason: "File is not an authorized File Converter backup.")
        }

        guard fm.fileExists(atPath: url.path) else {
            throw PresetStoreError.backupNotFound(url)
        }

        // Validate the backup file before restoring
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetStoreError.backupCorrupted(url, reason: error.localizedDescription)
        }

        do {
            let decoded = try decodePresets(data)
            let (validDecoded, _) = quarantineInvalidPresets(decoded)
            guard !validDecoded.isEmpty else {
                throw PresetStoreError.backupCorrupted(url, reason: "Backup contains no valid presets.")
            }
            try validatePresetCollection(validDecoded)
        } catch {
            throw PresetStoreError.backupCorrupted(url, reason: error.localizedDescription)
        }

        // Archive the corrupt primary file if it exists; abort if archiving fails to prevent unrecoverable data loss
        try archiveCorruptPrimaryFile(primaryURL: primaryURL)

        // Write the validated backup data atomically to primaryURL
        try data.write(to: primaryURL, options: .atomic)

        // Reload presets into memory and update state
        loadPresets()
        postNotification()
    }

    public func startFresh() throws {
        let primaryURL = try storageFileURL()
        let fm = FileManager.default

        // Archive corrupt primary file if it exists; abort if archiving fails to prevent unrecoverable data loss
        try archiveCorruptPrimaryFile(primaryURL: primaryURL)

        let directory = primaryURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let defaults = BuiltInPresets.makeDefaultPresets()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(PresetStoreDocument(presets: defaults)).write(to: primaryURL, options: .atomic)

        loadPresets()
        postNotification()
    }

    private func archiveCorruptPrimaryFile(primaryURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: primaryURL.path) else { return }
        let directory = primaryURL.deletingLastPathComponent()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let baseTimestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var archiveURL = directory.appendingPathComponent("presets.corrupt.\(baseTimestamp).json")
        var counter = 1
        while fm.fileExists(atPath: archiveURL.path) {
            archiveURL = directory.appendingPathComponent("presets.corrupt.\(baseTimestamp)-\(counter).json")
            counter += 1
        }
        do {
            try fm.copyItem(at: primaryURL, to: archiveURL)
            AppLogger.presets.info("Preserved damaged presets file to \(archiveURL.lastPathComponent, privacy: .public)")
        } catch {
            AppLogger.presets.error("Failed to archive damaged presets file: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func detectImportConflicts(in data: Data) throws -> [PresetImportConflict] {
        let incoming = try decodePresets(data)
        return lock.withLock {
            var conflicts: [PresetImportConflict] = []
            for item in incoming {
                if let existing = cachedPresets.first(where: {
                    $0.id == item.id || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }) {
                    let idMatches = existing.id == item.id
                    let nameMatches = existing.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let reason: PresetImportConflict.ConflictReason
                    if idMatches && nameMatches {
                        reason = .sameIDAndName
                    } else if idMatches {
                        reason = .sameID
                    } else {
                        reason = .sameName
                    }
                    conflicts.append(PresetImportConflict(importedPreset: item, existingPreset: existing, conflictReason: reason))
                }
            }
            return conflicts
        }
    }

    public func importPresetsJSON(
        _ data: Data,
        resolutions: [UUID: PresetConflictResolution] = [:],
        defaultResolution: PresetConflictResolution? = nil,
        overwrite: Bool = false
    ) throws {
        if case .recoveryRequired(let context) = state {
            throw PresetStoreError.recoveryRequired(reason: context.errorDescription)
        }
        let decoded = try decodePresets(data)
        try validatePresetCollection(decoded)
        var unresolvablePresetNames: [String] = []
        let sanitized = decoded.map { preset -> ConversionPreset in
            var p = preset
            if case .customFolder(let bookmarkData, let displayPath) = p.outputDirectoryPolicy {
                var isStale = false
                var resolvable = false
                if !bookmarkData.isEmpty {
                    if let url = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ), FileManager.default.fileExists(atPath: url.path) {
                        resolvable = true
                    } else if let url = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: [.withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ), FileManager.default.fileExists(atPath: url.path) {
                        resolvable = true
                    }
                }

                if !resolvable && !displayPath.isEmpty && FileManager.default.fileExists(atPath: displayPath) {
                    let folderURL = URL(fileURLWithPath: displayPath)
                    let newBookmark = (try? folderURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
                        ?? (try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                    if let bm = newBookmark {
                        p.outputDirectoryPolicy = .customFolder(bookmarkData: bm, displayPath: displayPath)
                        resolvable = true
                    }
                }

                if !resolvable {
                    // Do not silently change an unavailable custom folder to sameAsSource.
                    // Preserve the intended path and place the preset into a disabled state
                    // requiring the user to select/re-authorize that folder.
                    p.outputDirectoryPolicy = .customFolder(bookmarkData: bookmarkData, displayPath: displayPath)
                    p.isEnabled = false
                    AppLogger.presets.warning(
                        "Custom folder '\(displayPath, privacy: .public)' for preset '\(p.name, privacy: .public)' requires authorization on this Mac."
                    )
                    unresolvablePresetNames.append("\(p.name) ('\(displayPath)')")
                }
            }
            return p
        }

        let warningMessage: String? = unresolvablePresetNames.isEmpty
            ? nil
            : "The custom destination folder for \(unresolvablePresetNames.joined(separator: ", ")) is not authorized on this Mac. The preset has been disabled until the folder is selected or re-authorized in settings."

        let updated = lock.withLock { () -> [ConversionPreset] in
            cachedImportWarning = warningMessage
            var result = cachedPresets

            var existingNames = Set(result.map { $0.name.lowercased() })

            for var item in sanitized {
                let conflict = result.first(where: {
                    $0.id == item.id || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                })

                let resolution = resolutions[item.id] ?? defaultResolution ?? (overwrite ? .replace : nil)

                if let conflict {
                    if resolution == .skip {
                        continue
                    } else if resolution == .copy {
                        item.id = UUID()
                        item.builtInKey = nil
                        item.isBuiltIn = false
                        item.name = uniquePresetName(basedOn: item.name, existingNames: existingNames)
                        item.menuName = uniquePresetName(basedOn: item.menuName, existingNames: existingNames)
                        existingNames.insert(item.name.lowercased())
                        result.append(item)
                        continue
                    }
                    if item.isBuiltIn, let key = item.builtInKey,
                       let existingIndex = result.firstIndex(where: { $0.isBuiltIn && $0.builtInKey == key }) {
                        item.id = result[existingIndex].id
                        item.builtInKey = key
                        result[existingIndex] = item
                    } else if let index = result.firstIndex(where: { $0.id == item.id || $0.id == conflict.id }) {
                        result[index] = item
                    } else {
                        item.isBuiltIn = false
                        item.builtInKey = nil
                        result.append(item)
                    }
                } else {
                    if item.isBuiltIn, let key = item.builtInKey,
                       let existingIndex = result.firstIndex(where: { $0.isBuiltIn && $0.builtInKey == key }) {
                        item.id = result[existingIndex].id
                        item.builtInKey = key
                        result[existingIndex] = item
                    } else if let index = result.firstIndex(where: { $0.id == item.id }) {
                        result[index] = item
                    } else {
                        item.isBuiltIn = false
                        item.builtInKey = nil
                        result.append(item)
                    }
                }
                existingNames.insert(item.name.lowercased())
            }
            return mergeBuiltIns(into: result).sorted(by: presetSort)
        }
        guard !updated.isEmpty else { throw PresetStoreError.invalidPresetDocument }
        try persistAndNotifyThrowing(updated)
    }

    private func uniquePresetName(basedOn baseName: String, existingNames: Set<String>) -> String {
        var candidate = "\(baseName) (Copy)"
        var counter = 2
        while existingNames.contains(candidate.lowercased()) {
            candidate = "\(baseName) (Copy \(counter))"
            counter += 1
        }
        return candidate
    }

    private func mergeBuiltIns(into storedPresets: [ConversionPreset]) -> [ConversionPreset] {
        let defaultPresets = BuiltInPresets.makeDefaultPresets()
        let knownBuiltInKeys = Set(defaultPresets.compactMap(\.builtInKey))

        // Retain only valid current built-in presets and all user-created presets.
        // Retired built-ins (such as redundant source-to-destination recipes) are pruned.
        var merged = storedPresets.filter { stored in
            guard stored.isBuiltIn else { return true }
            if let key = stored.builtInKey {
                return knownBuiltInKeys.contains(key)
            }
            return defaultPresets.contains { def in
                def.name == stored.name
                    && def.category == stored.category
                    && def.destinationFormat == stored.destinationFormat
            }
        }

        for defaultPreset in defaultPresets {
            let matchIndex = merged.firstIndex { stored in
                guard stored.isBuiltIn else { return false }
                if let key = stored.builtInKey {
                    return key == defaultPreset.builtInKey
                }
                return stored.name == defaultPreset.name
                    && stored.category == defaultPreset.category
                    && stored.destinationFormat == defaultPreset.destinationFormat
            }

            guard let matchIndex else {
                merged.append(defaultPreset)
                continue
            }

            let stored = merged[matchIndex]
            var updated = stored
            // Legacy entries without an identity are migrated to the factory UUID/key,
            // but all user-edited fields are retained.
            updated.id = defaultPreset.id
            updated.builtInKey = defaultPreset.builtInKey
            updated.isBuiltIn = true
            // Matching rules are part of the built-in identity; do not let
            // malformed legacy entries hide a factory preset from Finder.
            updated.sourceFormats = defaultPreset.sourceFormats
            if defaultPreset.builtInKey == "document.pdf-compressed" && updated.backend == .ghostscript {
                updated.backend = .auto
            }
            merged[matchIndex] = updated
        }

        return merged
    }

    private var isExtensionProcess: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    private func storageFileURL() throws -> URL {
        if let storageURLOverride {
            return storageURLOverride
        }

        if let configuration = try? IPCConfiguration.current() {
            guard let container = configuration.sharedContainerURL() else {
                throw PresetStoreError.appGroupContainerUnavailable(configuration.appGroupID)
            }
            return container
                .appendingPathComponent("FileConverter", isDirectory: true)
                .appendingPathComponent(Self.presetsFileName)
        }

        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PresetStoreError.storageUnavailable
        }
        return appSupport
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent(Self.presetsFileName)
    }

    private func persistAndNotify(_ presets: [ConversionPreset]) {
        do {
            try persistAndNotifyThrowing(presets)
        } catch {
            lock.withLock { lastSaveSucceededValue = false }
            record(error)
        }
    }

    private func persistAndNotifyThrowing(_ presets: [ConversionPreset]) throws {
        guard !isExtensionProcess else {
            throw PresetStoreError.readOnlyExtension
        }
        try validatePresetCollection(presets)
        do {
            try persist(presets)
        } catch {
            lock.withLock { lastSaveSucceededValue = false }
            record(error)
            throw error
        }
        // The durable file is the source of truth. Update memory only after
        // the atomic write has completed, so a failed save cannot claim success.
        lock.withLock {
            cachedPresets = presets
            cachedErrorDescription = nil
            hasLoadedPresetsSuccessfully = true
            lastSaveSucceededValue = true
            currentState = .ready
        }

        if isIPCConfigured {
            do {
                try FinderMenuSnapshotWriter.write(presets: presets, resolver: .shared)
            } catch {
                // A preset save remains successful even when the extension
                // snapshot is temporarily unavailable. Surface the sync issue.
                record(error)
            }
        }
        postNotification()
    }

    private func persist(_ presets: [ConversionPreset]) throws {
        let fileURL = try storageFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateBackups(for: fileURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(PresetStoreDocument(presets: presets)).write(to: fileURL, options: .atomic)
    }

    private func decodePresets(_ data: Data) throws -> [ConversionPreset] {
        // Schema-versioned decoding with no silent quality migrations.
        // FLAC lossless presets must round-trip as lossless.
        // 1. Try schemaVersion <= 2 PresetStoreDocument (internal storage)
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(PresetStoreDocument.self, from: data) {
            guard document.schemaVersion <= 2 else {
                throw PresetStoreError.invalidPresetDocument
            }
            return document.presets
        }

        // 2. Try legacy raw [ConversionPreset] array (schema version 1 storage).
        if let legacy = try? decoder.decode([ConversionPreset].self, from: data) {
            return legacy
        }

        // 3. Reject future schema versions before attempting exchange parsing
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["schemaVersion"] as? Int,
           version > 2 {
            throw PresetStoreError.invalidPresetDocument
        }

        // 4. Try PresetExchange (schemaVersion 1 portable human-readable JSON)
        do {
            return try PresetExchange.importPresets(from: data)
        } catch let error as PresetExchangeError {
            throw error
        } catch {
            throw PresetStoreError.invalidPresetDocument
        }
    }

    /// Partitions a decoded collection into valid presets and quarantined
    /// invalid records. Used only on load so one malformed custom preset
    /// cannot remove built-ins or other valid customs.
    private func quarantineInvalidPresets(_ presets: [ConversionPreset]) -> (valid: [ConversionPreset], quarantined: [String]) {
        var valid: [ConversionPreset] = []
        var quarantined: [String] = []
        var seenIDs = Set<UUID>()
        var seenBuiltInKeys = Set<String>()
        let knownBuiltInKeys = Set(BuiltInPresets.makeDefaultPresets().compactMap(\.builtInKey))

        for preset in presets {
            let label = preset.name.isEmpty ? preset.id.uuidString : preset.name
            guard seenIDs.insert(preset.id).inserted else {
                quarantined.append("\(label) (duplicate identifier)")
                continue
            }
            if let error = PresetValidator.validationErrors(for: preset).first {
                quarantined.append("\(label) (\(error))")
                continue
            }
            if preset.isBuiltIn {
                guard let key = preset.builtInKey,
                      knownBuiltInKeys.contains(key),
                      seenBuiltInKeys.insert(key).inserted else {
                    quarantined.append("\(label) (unknown or duplicate built-in identity)")
                    continue
                }
            } else if preset.builtInKey != nil {
                quarantined.append("\(label) (custom preset claims built-in identity)")
                continue
            }
            valid.append(preset)
        }
        return (valid, quarantined)
    }

    private func validatePresetCollection(_ presets: [ConversionPreset]) throws {
        guard !presets.isEmpty else {
            throw PresetStoreError.invalidPresetDocument
        }

        var identifiers = Set<UUID>()
        var builtInKeys = Set<String>()
        let knownBuiltInKeys = Set(BuiltInPresets.makeDefaultPresets().compactMap(\.builtInKey))

        for preset in presets {
            guard identifiers.insert(preset.id).inserted else {
                throw PresetStoreError.invalidPreset(reason: "Duplicate preset identifier.")
            }
            if let error = PresetValidator.validationErrors(for: preset).first {
                throw PresetStoreError.invalidPreset(reason: error)
            }
            if preset.isBuiltIn {
                guard let key = preset.builtInKey,
                      knownBuiltInKeys.contains(key),
                      builtInKeys.insert(key).inserted else {
                    throw PresetStoreError.invalidPreset(reason: "Unknown or duplicate built-in preset identity.")
                }
            } else if preset.builtInKey != nil {
                throw PresetStoreError.invalidPreset(reason: "Custom presets cannot claim a built-in identity.")
            }
        }
    }

    private func rotateBackups(for fileURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let directory = fileURL.deletingLastPathComponent()
        for index in stride(from: 4, through: 1, by: -1) {
            let oldURL = directory.appendingPathComponent("presets.backup.\(index).json")
            let newURL = directory.appendingPathComponent("presets.backup.\(index + 1).json")
            try? fm.removeItem(at: newURL)
            try? fm.moveItem(at: oldURL, to: newURL)
        }
        let firstBackup = directory.appendingPathComponent("presets.backup.1.json")
        try? fm.removeItem(at: firstBackup)
        try? fm.copyItem(at: fileURL, to: firstBackup)
    }

    private func record(_ error: Error) {
        lock.withLock { cachedErrorDescription = error.localizedDescription }
        AppLogger.presets.error("Preset persistence failed: \(error.localizedDescription, privacy: .public)")
    }

    private func postNotification() {
        guard postsDarwinNotifications, let configuration = try? IPCConfiguration.current() else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = CFNotificationName(configuration.finderMenuSnapshotNotificationName as CFString)
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    private var isIPCConfigured: Bool {
        (try? IPCConfiguration.current()) != nil
    }

    private func presetSort(_ lhs: ConversionPreset, _ rhs: ConversionPreset) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.sortOrder < rhs.sortOrder
    }
}
