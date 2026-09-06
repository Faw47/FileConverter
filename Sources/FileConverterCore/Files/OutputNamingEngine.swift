import Foundation

public enum OutputNamingEngine {
    public static func resolveDestinationDirectory(
        forSourceURL sourceURL: URL,
        policy: OutputDirectoryPolicy,
        customFolderURL: URL? = nil
    ) throws -> URL {
        switch policy {
        case .sameAsSource:
            return sourceURL.deletingLastPathComponent()

        case .downloads:
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                return downloads
            }
            return sourceURL.deletingLastPathComponent()

        case .sourceSubfolder(let subfolder):
            let cleanSubfolder = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanSubfolder.isEmpty,
                  cleanSubfolder != ".",
                  cleanSubfolder != "..",
                  !cleanSubfolder.contains("/"),
                  !cleanSubfolder.contains("\\") else {
                throw ConversionError.destinationUnavailable(path: subfolder)
            }
            let targetDir = sourceURL.deletingLastPathComponent().appendingPathComponent(cleanSubfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            return targetDir

        case .customFolder(_, let displayPath):
            guard let customFolderURL else {
                throw ConversionError.destinationUnavailable(path: displayPath)
            }
            return customFolderURL
        }
    }

    public static func generateFormattedFilename(
        sourceURL: URL,
        preset: ConversionPreset,
        targetExtension: String,
        suffix: String? = nil
    ) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let cleanExt = targetExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()

        var pattern = preset.filenamePattern
        if pattern.isEmpty {
            pattern = "{name}"
        }

        // Format dates
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"
        let timeString = timeFormatter.string(from: Date())

        let sanitizedPresetName = preset.menuName
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined(separator: "_")

        var formatted = pattern
            .replacingOccurrences(of: "{name}", with: baseName)
            .replacingOccurrences(of: "{preset}", with: sanitizedPresetName)
            .replacingOccurrences(of: "{date}", with: dateString)
            .replacingOccurrences(of: "{time}", with: timeString)
            .replacingOccurrences(of: "{ext}", with: cleanExt)

        // Remove any invalid path characters
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        formatted = formatted.components(separatedBy: invalidChars).joined(separator: "_")

        if let suffix, !suffix.isEmpty {
            formatted += "-\(suffix)"
        }
        return "\(formatted).\(cleanExt)"
    }

    public static func resolveFinalDestinationURL(
        sourceURL: URL,
        preset: ConversionPreset,
        targetExtension: String? = nil,
        suffix: String? = nil,
        reservedURLs: Set<URL> = [],
        customFolderURL: URL? = nil
    ) throws -> URL {
        let ext = targetExtension ?? preset.destinationFormat
        let targetDir = try resolveDestinationDirectory(
            forSourceURL: sourceURL,
            policy: preset.outputDirectoryPolicy,
            customFolderURL: customFolderURL
        )
        let filename = generateFormattedFilename(sourceURL: sourceURL, preset: preset, targetExtension: ext, suffix: suffix)
        let idealURL = targetDir.appendingPathComponent(filename)

        if reservedURLs.contains(idealURL.standardizedFileURL) {
            switch preset.overwritePolicy {
            case .appendNumber:
                return findAvailableNumberedURL(for: idealURL, reservedURLs: reservedURLs)
            case .ask, .overwrite, .replaceIfNewer, .skip:
                throw ConversionError.outputCollision(path: idealURL.path)
            }
        }

        guard !FileManager.default.fileExists(atPath: idealURL.path) else {
            return try resolveCollision(
                at: idealURL,
                sourceURL: sourceURL,
                preset: preset,
                reservedURLs: reservedURLs
            )
        }
        return idealURL
    }

    private static func resolveCollision(
        at idealURL: URL,
        sourceURL: URL,
        preset: ConversionPreset,
        reservedURLs: Set<URL>
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: idealURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw ConversionError.destinationUnavailable(path: idealURL.path)
        }

        switch preset.overwritePolicy {
        case .overwrite:
            return idealURL

        case .skip:
            throw ConversionError.outputCollision(path: idealURL.path)

        case .ask:
            // Ask is resolved by the batch conflict UI. Fail during preflight
            // so the queue can pause before a backend spends time converting.
            throw ConversionError.outputCollision(path: idealURL.path)

        case .replaceIfNewer:
            if let srcAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
               let srcDate = srcAttrs[.modificationDate] as? Date,
               let dstAttrs = try? FileManager.default.attributesOfItem(atPath: idealURL.path),
               let dstDate = dstAttrs[.modificationDate] as? Date {
                if srcDate > dstDate {
                    return idealURL
                } else {
                    throw ConversionError.outputCollision(path: idealURL.path)
                }
            }
            throw ConversionError.outputCollision(path: idealURL.path)

        case .appendNumber:
            return findAvailableNumberedURL(for: idealURL, reservedURLs: reservedURLs)
        }
    }

    public static func findAvailableNumberedURL(
        for targetURL: URL,
        reservedURLs: Set<URL> = []
    ) -> URL {
        let dir = targetURL.deletingLastPathComponent()
        let baseName = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension

        var counter = 1
        var candidateURL = targetURL

        while isOccupied(candidateURL, reservedURLs: reservedURLs) {
            let newFilename = "\(baseName) (\(counter)).\(ext)"
            candidateURL = dir.appendingPathComponent(newFilename)
            counter += 1
            if counter > 9999 {
                // Safeguard against infinite loop
                let uuid = UUID().uuidString.prefix(6)
                return dir.appendingPathComponent("\(baseName)_\(uuid).\(ext)")
            }
        }

        return candidateURL
    }

    public static func createTemporaryOutputURL(for finalDestinationURL: URL) -> URL {
        let dir = finalDestinationURL.deletingLastPathComponent()
        let baseName = finalDestinationURL.deletingPathExtension().lastPathComponent
        let ext = finalDestinationURL.pathExtension
        let tempName = ".\(baseName).converting-\(UUID().uuidString).\(ext)"
        return dir.appendingPathComponent(tempName)
    }

    public static func finalizeConversionOutput(
        temporaryURL: URL,
        finalDestinationURL: URL,
        overwrite: Bool = true
    ) throws {
        try finalizeConversionOutputs(
            [PlannedConversionOutput(finalURL: finalDestinationURL, temporaryURL: temporaryURL)],
            overwrite: overwrite
        )
    }

    /// Commits every temporary output as one recoverable operation. If a later
    /// output cannot be moved, outputs already committed in this attempt are
    /// removed and any replaced originals are restored.
    public static func finalizeConversionOutputs(
        _ outputs: [PlannedConversionOutput],
        overwrite: Bool = true
    ) throws {
        guard !outputs.isEmpty else {
            throw ConversionError.destinationUnavailable(path: "")
        }

        let fileManager = FileManager.default
        var seenDestinations = Set<URL>()
        var existingDestinations = Set<URL>()
        var backupsByDestination: [URL: URL] = [:]

        for output in outputs {
            guard fileManager.fileExists(atPath: output.temporaryURL.path) else {
                throw ConversionError.fileNotFound(path: output.temporaryURL.path)
            }

            let destination = output.finalURL.standardizedFileURL
            guard seenDestinations.insert(destination).inserted else {
                throw ConversionError.destinationUnavailable(path: output.finalURL.path)
            }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: output.finalURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw ConversionError.destinationUnavailable(path: output.finalURL.path)
                }
                guard overwrite else {
                    throw ConversionError.outputCollision(path: output.finalURL.path)
                }
                existingDestinations.insert(destination)
            }
        }

        struct CommittedOutput {
            let finalURL: URL
            let replacedExistingFile: Bool
        }
        var committed: [CommittedOutput] = []

        do {
            for output in outputs {
                let destination = output.finalURL.standardizedFileURL
                guard existingDestinations.contains(destination) else { continue }
                let backupName = ".\(output.finalURL.lastPathComponent).fileconverter-original-\(UUID().uuidString)"
                let backupURL = output.finalURL.deletingLastPathComponent().appendingPathComponent(backupName)
                // Do not rely on FileManager's undocumented backup placement
                // after replaceItemAt. Keeping our own copy makes the whole
                // multi-file operation recoverable on every supported volume.
                try fileManager.copyItem(at: output.finalURL, to: backupURL)
                backupsByDestination[destination] = backupURL
            }

            for output in outputs {
                let destination = output.finalURL.standardizedFileURL
                if existingDestinations.contains(destination) {
                    _ = try fileManager.replaceItemAt(
                        output.finalURL,
                        withItemAt: output.temporaryURL,
                        backupItemName: nil,
                        options: []
                    )
                    committed.append(CommittedOutput(finalURL: output.finalURL, replacedExistingFile: true))
                } else {
                    try fileManager.moveItem(at: output.temporaryURL, to: output.finalURL)
                    committed.append(CommittedOutput(finalURL: output.finalURL, replacedExistingFile: false))
                }
            }

            for backupURL in backupsByDestination.values {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            var rollbackError: Error?
            let committedNewDestinations = Set(
                committed
                    .filter { !$0.replacedExistingFile }
                    .map { $0.finalURL.standardizedFileURL }
            )
            for output in outputs.reversed() {
                let destination = output.finalURL.standardizedFileURL
                do {
                    if let backupURL = backupsByDestination[destination],
                       fileManager.fileExists(atPath: backupURL.path) {
                        if fileManager.fileExists(atPath: output.finalURL.path) {
                            try fileManager.removeItem(at: output.finalURL)
                        }
                        try fileManager.moveItem(at: backupURL, to: output.finalURL)
                    } else if committedNewDestinations.contains(destination),
                              fileManager.fileExists(atPath: output.finalURL.path) {
                        try fileManager.removeItem(at: output.finalURL)
                    }
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }

            if rollbackError == nil {
                for backupURL in backupsByDestination.values where fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
            }

            if let rollbackError {
                throw ConversionError.unknown(
                    message: "Could not commit all conversion outputs and restore the original files: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    public static func cleanupTemporaryFile(at url: URL?) {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func isOccupied(_ url: URL, reservedURLs: Set<URL>) -> Bool {
        reservedURLs.contains(url.standardizedFileURL)
            || FileManager.default.fileExists(atPath: url.path)
    }
}
