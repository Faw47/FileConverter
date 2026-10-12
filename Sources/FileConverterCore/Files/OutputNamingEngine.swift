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
            var cleanSubfolder = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            cleanSubfolder = cleanSubfolder.replacingOccurrences(of: "{name}", with: baseName)
            guard !cleanSubfolder.isEmpty,
                  cleanSubfolder != ".",
                  cleanSubfolder != "..",
                  !cleanSubfolder.contains("/"),
                  !cleanSubfolder.contains("\\") else {
                throw ConversionError.destinationUnavailable(path: subfolder)
            }
            let targetDir = sourceURL.deletingLastPathComponent().appendingPathComponent(cleanSubfolder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            } catch {
                throw ConversionError.destinationUnavailable(path: targetDir.path)
            }
            return targetDir

        case .customFolder(_, let displayPath):
            guard let customFolderURL else {
                throw ConversionError.sandboxAccessFailure(path: displayPath)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: customFolderURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ConversionError.destinationUnavailable(path: displayPath)
            }
            return customFolderURL
        }
    }

    /// Filename for a conversion, using the preset's effective pattern
    /// (its own, or the General pattern when it inherits it).
    public static func generateFormattedFilename(
        sourceURL: URL,
        preset: ConversionPreset,
        targetExtension: String,
        suffix: String? = nil,
        date: Date = Date(),
        defaults: ConversionDefaults? = nil
    ) -> String {
        let pattern = EffectivePresetResolver.resolve(
            preset: preset,
            defaults: defaults ?? .current
        ).filenamePattern.value
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceExtension = sourceURL.pathExtension
        var fullSuffix = suffix
        if let sameFormatSuffix = sameFormatSuffix(
            for: preset,
            pattern: pattern,
            sourceExtension: sourceExtension,
            targetExtension: targetExtension
        ) {
            fullSuffix = [sameFormatSuffix, suffix].compactMap { $0 }.joined(separator: "-")
        }
        return formatFilename(
            pattern: pattern,
            baseName: baseName,
            presetMenuName: preset.menuName,
            targetExtension: targetExtension,
            suffix: fullSuffix,
            date: date
        )
    }

    /// The same formatting the queue uses, for previews in Settings.
    public static func previewFilename(
        pattern: String,
        sourceName: String,
        sourceExtension: String,
        targetExtension: String,
        presetMenuName: String,
        date: Date = Date()
    ) -> String {
        formatFilename(
            pattern: pattern,
            baseName: sourceName,
            presetMenuName: presetMenuName,
            targetExtension: targetExtension,
            suffix: nil,
            date: date
        )
    }

    /// When a conversion keeps the file type (JPEG → smaller JPEG) and the
    /// pattern is just the source name, a descriptive suffix keeps the result
    /// from being named "photo (1).jpg".
    static func sameFormatSuffix(
        for preset: ConversionPreset,
        pattern: String,
        sourceExtension: String,
        targetExtension: String
    ) -> String? {
        guard let suffix = preset.sameFormatSuffix?.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ")),
              !suffix.isEmpty,
              pattern.trimmingCharacters(in: .whitespacesAndNewlines) == "{name}" else { return nil }
        let source = FormatRegistry.shared.format(forExtension: sourceExtension)?.id ?? sourceExtension.lowercased()
        let target = FormatRegistry.shared.format(forExtension: targetExtension)?.id ?? targetExtension.lowercased()
        return source == target ? suffix : nil
    }

    /// "MKV → MP4" becomes "MKV_to_MP4": arrows read as "to", and every run of
    /// characters that is not a letter, digit, or hyphen becomes one underscore.
    public static func sanitizedPresetToken(_ menuName: String) -> String {
        let spelled = menuName
            .replacingOccurrences(of: "→", with: " to ")
            .replacingOccurrences(of: "–", with: "-")
        var result = ""
        var pendingSeparator = false
        for scalar in spelled.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                if pendingSeparator && !result.isEmpty { result.append("_") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    static func formatFilename(
        pattern rawPattern: String,
        baseName: String,
        presetMenuName: String,
        targetExtension: String,
        suffix: String?,
        date: Date
    ) -> String {
        let cleanExt = targetExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{name}" : rawPattern

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "HH-mm-ss"
        let timeString = dateFormatter.string(from: date)

        var formatted = pattern
            .replacingOccurrences(of: "{name}", with: baseName)
            .replacingOccurrences(of: "{preset}", with: sanitizedPresetToken(presetMenuName))
            .replacingOccurrences(of: "{date}", with: dateString)
            .replacingOccurrences(of: "{time}", with: timeString)
            .replacingOccurrences(of: "{ext}", with: cleanExt)

        // Remove any invalid path characters
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        formatted = formatted.components(separatedBy: invalidChars).joined(separator: "_")

        var base = formatted
        if !cleanExt.isEmpty {
            if base.lowercased().hasSuffix(".\(cleanExt)") {
                base.removeLast(cleanExt.count + 1)
            }
            if let suffix, !suffix.isEmpty {
                base += "-\(suffix)"
            }
            return "\(base).\(cleanExt)"
        } else {
            if base.hasSuffix(".") {
                base.removeLast()
            }
            if let suffix, !suffix.isEmpty {
                base += "-\(suffix)"
            }
            return base
        }
    }

    public static var globalDefaultOutputPolicy: OutputDirectoryPolicy {
        ConversionDefaults.current.outputDirectoryPolicy
    }

    public static func resolveFinalDestinationURL(
        sourceURL: URL,
        preset: ConversionPreset,
        targetExtension: String? = nil,
        suffix: String? = nil,
        reservedURLs: Set<URL> = [],
        customFolderURL: URL? = nil,
        collisionPlan: CollisionResolutionPlan? = nil,
        namingDate: Date = Date()
    ) throws -> URL {
        let reservationKeys = canonicalReservationKeys(reservedURLs)
        let ext = targetExtension ?? preset.destinationFormat
        let effectivePolicy = EffectivePresetResolver.resolve(preset: preset).outputDirectoryPolicy.value
        var effectiveCustomFolderURL = customFolderURL

        if case .customFolder(let bookmarkData, _) = effectivePolicy, effectiveCustomFolderURL == nil {
            let displayPath: String = {
                if case .customFolder(_, let path) = effectivePolicy { return path }
                return ""
            }()
            effectiveCustomFolderURL = try resolveCustomFolderBookmark(
                bookmarkData,
                displayPath: displayPath
            )
        }

        let baseTargetDir = try resolveDestinationDirectory(
            forSourceURL: sourceURL,
            policy: effectivePolicy,
            customFolderURL: effectiveCustomFolderURL
        )

        let targetDir: URL
        if (preset.splitPDFIntoPages || preset.isPDFSplitWorkflow),
           let subfolder = preset.processingOptions?.pdfOutputSubfolder,
           !subfolder.isEmpty {
            var cleanSubfolder = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            cleanSubfolder = cleanSubfolder.replacingOccurrences(of: "{name}", with: baseName)
            if !cleanSubfolder.isEmpty && cleanSubfolder != "." && cleanSubfolder != ".." && !cleanSubfolder.contains("/") && !cleanSubfolder.contains("\\") {
                if case .sourceSubfolder = effectivePolicy {
                    targetDir = baseTargetDir
                    } else {
                        targetDir = baseTargetDir.appendingPathComponent(cleanSubfolder, isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                    } catch {
                        throw ConversionError.destinationUnavailable(path: targetDir.path)
                    }
                }
            } else {
                targetDir = baseTargetDir
            }
        } else {
            targetDir = baseTargetDir
        }

        let filename = generateFormattedFilename(sourceURL: sourceURL, preset: preset, targetExtension: ext, suffix: suffix, date: namingDate)
        let idealURL = targetDir.appendingPathComponent(filename)

        // Same-file guard: never convert a file onto itself, even when the
        // naming pattern resolves to the source path.
        if FileAccessManager.shared.urlsReferToSameFile(sourceURL, idealURL) {
            throw ConversionError.destinationUnavailable(path: idealURL.path)
        }

        if let plan = collisionPlan {
            if let decision = plan.decision(for: idealURL) {
                switch decision {
                case .replace(let approvedFingerprint):
                    if approvedFingerprint.matchesCurrentState(of: idealURL) {
                        return idealURL
                    } else {
                        throw ConversionError.outputCollision(path: idealURL.path)
                    }
                case .keepBoth:
                    return findAvailableNumberedURL(for: idealURL, reservedURLs: reservationKeys)
                case .skip:
                    throw ConversionError.outputCollision(path: idealURL.path)
                }
            } else if FileManager.default.fileExists(atPath: idealURL.path) {
                throw ConversionError.outputCollision(path: idealURL.path)
            }
        }

        if reservationKeys.contains(FileAccessManager.shared.reservationKey(for: idealURL)) {
            switch preset.overwritePolicy {
            case .appendNumber:
                return findAvailableNumberedURL(for: idealURL, reservedURLs: reservationKeys)
            case .ask, .overwrite, .replaceIfNewer, .skip:
                // Another queued job is creating this file. Wait for it, then
                // apply the collision policy to the file it produced.
                throw ConversionError.destinationReserved(path: idealURL.path)
            }
        }

        guard !FileManager.default.fileExists(atPath: idealURL.path) else {
            return try resolveCollision(
                at: idealURL,
                sourceURL: sourceURL,
                preset: preset,
                reservedURLs: reservationKeys
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
        let reservationKeys = canonicalReservationKeys(reservedURLs)
        let dir = targetURL.deletingLastPathComponent()
        let baseName = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension

        var candidateURL = targetURL
        if !isOccupied(candidateURL, reservedURLs: reservationKeys) {
            return candidateURL
        }

        var counter = 1
        // Fast linear probe for initial collisions
        while counter <= 15 {
            let newFilename = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidateURL = dir.appendingPathComponent(newFilename)
            if !isOccupied(candidateURL, reservedURLs: reservationKeys) {
                return candidateURL
            }
            counter += 1
        }

        // For heavily congested directories, read directory contents once instead of doing thousands of stat calls
        let existingNames: Set<String> = {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
                return []
            }
            return Set(contents)
        }()

        while counter <= 9999 {
            let newFilename = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidateURL = dir.appendingPathComponent(newFilename)
            let isReserved = reservationKeys.contains(FileAccessManager.shared.reservationKey(for: candidateURL))
            let existsInDir = existingNames.isEmpty ? FileManager.default.fileExists(atPath: candidateURL.path) : existingNames.contains(newFilename)
            if !isReserved && !existsInDir {
                return candidateURL
            }
            counter += 1
        }

        let uuid = UUID().uuidString.prefix(6)
        let fallbackFilename = ext.isEmpty ? "\(baseName)_\(uuid)" : "\(baseName)_\(uuid).\(ext)"
        return dir.appendingPathComponent(fallbackFilename)
    }

    public static func createTemporaryOutputURL(for finalDestinationURL: URL) -> URL {
        let dir = finalDestinationURL.deletingLastPathComponent()
        let baseName = finalDestinationURL.deletingPathExtension().lastPathComponent
        let ext = finalDestinationURL.pathExtension
        let tempName = ".\(baseName).fileconverter-tmp-\(UUID().uuidString).\(ext)"
        return dir.appendingPathComponent(tempName)
    }

    @discardableResult
    public static func finalizeConversionOutput(
        temporaryURL: URL,
        finalDestinationURL: URL,
        overwrite: Bool = true,
        collisionPlan: CollisionResolutionPlan? = nil
    ) throws -> URL {
        let results = try finalizeConversionOutputs(
            [PlannedConversionOutput(finalURL: finalDestinationURL, temporaryURL: temporaryURL)],
            overwrite: overwrite,
            collisionPlan: collisionPlan
        )
        return results.first ?? finalDestinationURL
    }

    /// Commits every temporary output as one recoverable operation. If a later
    /// output cannot be moved, outputs already committed in this attempt are
    /// removed and any replaced originals are restored.
    /// Coordination uses NSFileCoordinator off the main actor so a racing
    /// writer cannot slip in between validation and commit.
    @discardableResult
    public static func finalizeConversionOutputs(
        _ outputs: [PlannedConversionOutput],
        overwrite: Bool = true,
        collisionPlan: CollisionResolutionPlan? = nil,
        sourceURL: URL? = nil,
        isReplaceIfNewer: Bool = false,
        allowKeepBothRetry: Bool = false
    ) throws -> [URL] {
        try finalizeConversionOutputsWithReport(
            outputs,
            overwrite: overwrite,
            collisionPlan: collisionPlan,
            sourceURL: sourceURL,
            isReplaceIfNewer: isReplaceIfNewer,
            allowKeepBothRetry: allowKeepBothRetry
        ).committedURLs
    }

    public struct FinalizeReport: Sendable {
        public let committedURLs: [URL]
        /// Replaced files now in the Trash.
        public let trashedOriginals: [URL]
        /// Replaced files that could not be moved to the Trash and were deleted.
        public let untrashableOriginals: [URL]
    }

    public static func finalizeConversionOutputsWithReport(
        _ outputs: [PlannedConversionOutput],
        overwrite: Bool = true,
        collisionPlan: CollisionResolutionPlan? = nil,
        sourceURL: URL? = nil,
        isReplaceIfNewer: Bool = false,
        allowKeepBothRetry: Bool = false
    ) throws -> FinalizeReport {
        try finalizeConversionOutputs(
            outputs,
            overwrite: overwrite,
            collisionPlan: collisionPlan,
            sourceURL: sourceURL,
            isReplaceIfNewer: isReplaceIfNewer,
            allowKeepBothRetry: allowKeepBothRetry,
            beforeCoordination: nil,
            coordinatorErrorForTesting: nil
        )
    }

    @discardableResult
    static func finalizeConversionOutputsForTesting(
        _ outputs: [PlannedConversionOutput],
        overwrite: Bool = true,
        collisionPlan: CollisionResolutionPlan? = nil,
        sourceURL: URL? = nil,
        isReplaceIfNewer: Bool = false,
        allowKeepBothRetry: Bool = false,
        beforeCoordination: @escaping () throws -> Void,
        coordinatorErrorForTesting: NSError? = nil
    ) throws -> [URL] {
        try finalizeConversionOutputs(
            outputs,
            overwrite: overwrite,
            collisionPlan: collisionPlan,
            sourceURL: sourceURL,
            isReplaceIfNewer: isReplaceIfNewer,
            allowKeepBothRetry: allowKeepBothRetry,
            beforeCoordination: beforeCoordination,
            coordinatorErrorForTesting: coordinatorErrorForTesting
        ).committedURLs
    }

    private static func splitBaseNameAndCounter(_ name: String) -> (base: String, counter: Int?) {
        if let lastOpen = name.lastIndex(of: "("),
           name.hasSuffix(")"),
           lastOpen > name.startIndex {
            let prevIdx = name.index(before: lastOpen)
            if name[prevIdx] == " " {
                let numStart = name.index(after: lastOpen)
                let numEnd = name.index(before: name.endIndex)
                if let num = Int(name[numStart..<numEnd]), num > 0 {
                    let base = String(name[..<prevIdx])
                    return (base, num)
                }
            }
        }
        return (name, nil)
    }

    @discardableResult
    private static func finalizeConversionOutputs(
        _ outputs: [PlannedConversionOutput],
        overwrite: Bool,
        collisionPlan: CollisionResolutionPlan?,
        sourceURL: URL?,
        isReplaceIfNewer: Bool,
        allowKeepBothRetry: Bool,
        beforeCoordination: (() throws -> Void)?,
        coordinatorErrorForTesting: NSError?
    ) throws -> FinalizeReport {
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

            let destination = FileAccessManager.shared.reservationKey(for: output.finalURL)
            guard seenDestinations.insert(destination).inserted else {
                throw ConversionError.destinationUnavailable(path: output.finalURL.path)
            }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: output.finalURL.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw ConversionError.destinationUnavailable(path: output.finalURL.path)
                }
                let shouldKeepBoth: Bool = {
                    if allowKeepBothRetry { return true }
                    if let plan = collisionPlan, let decision = plan.decision(for: output.finalURL) {
                        if case .keepBoth = decision { return true }
                    }
                    return false
                }()

                if let plan = collisionPlan {
                    guard let decision = plan.decision(for: output.finalURL) else {
                        throw ConversionError.outputCollision(path: output.finalURL.path)
                    }
                    switch decision {
                    case .replace:
                        existingDestinations.insert(destination)
                    case .keepBoth:
                        break
                    case .skip:
                        throw ConversionError.outputCollision(path: output.finalURL.path)
                    }
                } else if shouldKeepBoth {
                    // Numbered candidate will be allocated during coordination
                    break
                } else if isReplaceIfNewer {
                    // Will verify timestamp inside coordination lock
                    existingDestinations.insert(destination)
                } else {
                    guard overwrite else {
                        throw ConversionError.outputCollision(path: output.finalURL.path)
                    }
                    existingDestinations.insert(destination)
                }
            }
        }

        struct CommittedOutput {
            let finalURL: URL
            let replacedExistingFile: Bool
        }
        var committed: [CommittedOutput] = []
        var commitError: Error?
        try beforeCoordination?()

        struct CoordinationFailure {
            let destinationURL: URL
            let underlyingError: NSError
        }
        var coordinationFailure: CoordinationFailure?

        for output in outputs {
            if commitError != nil || coordinationFailure != nil {
                break
            }

            let isKeepBoth: Bool = {
                if allowKeepBothRetry { return true }
                if let plan = collisionPlan, let decision = plan.decision(for: output.finalURL) {
                    if case .keepBoth = decision { return true }
                }
                return false
            }()

            if isKeepBoth {
                let dir = output.finalURL.deletingLastPathComponent()
                let fullBaseName = output.finalURL.deletingPathExtension().lastPathComponent
                let ext = output.finalURL.pathExtension
                let (baseName, existingCounter) = splitBaseNameAndCounter(fullBaseName)

                var candidateCounter = existingCounter ?? 0
                var committedThisOutput = false
                let maxKeepBothAttempts = 100
                var attempts = 0

                while attempts < maxKeepBothAttempts {
                    attempts += 1
                    let candidateURL: URL
                    if candidateCounter == 0 {
                        if fileManager.fileExists(atPath: output.finalURL.path) {
                            candidateCounter = 1
                            let newFilename = ext.isEmpty ? "\(baseName) (\(candidateCounter))" : "\(baseName) (\(candidateCounter)).\(ext)"
                            candidateURL = dir.appendingPathComponent(newFilename)
                        } else {
                            candidateURL = output.finalURL
                        }
                    } else {
                        let newFilename = ext.isEmpty ? "\(baseName) (\(candidateCounter))" : "\(baseName) (\(candidateCounter)).\(ext)"
                        candidateURL = dir.appendingPathComponent(newFilename)
                    }

                    if let coordinatorErrorForTesting {
                        coordinationFailure = CoordinationFailure(
                            destinationURL: candidateURL,
                            underlyingError: coordinatorErrorForTesting
                        )
                        break
                    }

                    let coordinator = NSFileCoordinator(filePresenter: nil)
                    var coordinatorError: NSError?
                    var pathTaken = false

                    coordinator.coordinate(
                        writingItemAt: candidateURL,
                        options: [],
                        error: &coordinatorError
                    ) { coordinatedURL in
                        if fileManager.fileExists(atPath: coordinatedURL.path) {
                            pathTaken = true
                        } else {
                            do {
                                try fileManager.moveItem(at: output.temporaryURL, to: coordinatedURL)
                                committed.append(CommittedOutput(finalURL: coordinatedURL, replacedExistingFile: false))
                                committedThisOutput = true
                            } catch {
                                commitError = error
                            }
                        }
                    }

                    if let coordinatorError {
                        coordinationFailure = CoordinationFailure(
                            destinationURL: candidateURL,
                            underlyingError: coordinatorError
                        )
                        break
                    }
                    if commitError != nil || committedThisOutput {
                        break
                    }
                    if pathTaken {
                        candidateCounter += 1
                    }
                }

                if !committedThisOutput && commitError == nil && coordinationFailure == nil {
                    commitError = ConversionError.destinationChangingTooQuickly(path: output.finalURL.path)
                }
            } else {
                let destination = FileAccessManager.shared.reservationKey(for: output.finalURL)
                if let coordinatorErrorForTesting {
                    coordinationFailure = CoordinationFailure(
                        destinationURL: output.finalURL,
                        underlyingError: coordinatorErrorForTesting
                    )
                    break
                }

                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinatorError: NSError?
                coordinator.coordinate(
                    writingItemAt: output.finalURL,
                    options: .forReplacing,
                    error: &coordinatorError
                ) { coordinatedURL in
                    do {
                        let canonicalCoordinated = FileAccessManager.shared.reservationKey(for: coordinatedURL)
                        let destExists = fileManager.fileExists(atPath: coordinatedURL.path)
                        if destExists {
                            if let plan = collisionPlan {
                                guard let decision = plan.decision(for: output.finalURL) else {
                                    throw ConversionError.outputCollision(path: coordinatedURL.path)
                                }
                                switch decision {
                                case .replace(let approvedFingerprint):
                                    guard approvedFingerprint.matchesCurrentState(of: coordinatedURL) else {
                                        throw ConversionError.outputCollision(path: coordinatedURL.path)
                                    }
                                case .keepBoth, .skip:
                                    throw ConversionError.outputCollision(path: coordinatedURL.path)
                                }
                            } else if isReplaceIfNewer {
                                guard let srcURL = sourceURL,
                                      let srcAttrs = try? fileManager.attributesOfItem(atPath: srcURL.path),
                                      let srcDate = srcAttrs[.modificationDate] as? Date,
                                      let dstAttrs = try? fileManager.attributesOfItem(atPath: coordinatedURL.path),
                                      let dstDate = dstAttrs[.modificationDate] as? Date,
                                      srcDate > dstDate else {
                                    throw ConversionError.outputCollision(path: coordinatedURL.path)
                                }
                            } else {
                                guard overwrite && existingDestinations.contains(destination) else {
                                    throw ConversionError.outputCollision(path: coordinatedURL.path)
                                }
                            }

                            let backupName = ".\(coordinatedURL.lastPathComponent).fileconverter-original-\(UUID().uuidString)"
                            let backupURL = coordinatedURL.deletingLastPathComponent().appendingPathComponent(backupName)
                            try fileManager.copyItem(at: coordinatedURL, to: backupURL)
                            backupsByDestination[canonicalCoordinated] = backupURL

                            _ = try fileManager.replaceItemAt(
                                coordinatedURL,
                                withItemAt: output.temporaryURL,
                                backupItemName: nil,
                                options: []
                            )
                            committed.append(CommittedOutput(finalURL: coordinatedURL, replacedExistingFile: true))
                        } else {
                            try fileManager.moveItem(at: output.temporaryURL, to: coordinatedURL)
                            committed.append(CommittedOutput(finalURL: coordinatedURL, replacedExistingFile: false))
                        }
                    } catch {
                        commitError = error
                    }
                }

                if let coordinatorError {
                    coordinationFailure = CoordinationFailure(
                        destinationURL: output.finalURL,
                        underlyingError: coordinatorError
                    )
                }
            }
        }

        if coordinationFailure == nil, commitError == nil {
            var trashed: [URL] = []
            var untrashable: [URL] = []
            for (destination, backupURL) in backupsByDestination {
                if let trashedURL = moveReplacedOriginalToTrash(backupURL, originalURL: destination) {
                    trashed.append(trashedURL)
                } else {
                    try? fileManager.removeItem(at: backupURL)
                    untrashable.append(destination)
                }
            }
            return FinalizeReport(
                committedURLs: committed.map(\.finalURL),
                trashedOriginals: trashed,
                untrashableOriginals: untrashable
            )
        }

        let failure: Error
        if let coordinationFailure {
            failure = ConversionError.unknown(
                message: "Could not coordinate destination '\(coordinationFailure.destinationURL.path)': \(coordinationFailure.underlyingError.localizedDescription)"
            )
        } else {
            failure = commitError ?? ConversionError.unknown(message: "Could not commit conversion outputs.")
        }

        var rollbackError: Error?
        let committedNewDestinations = Set(
            committed
                .filter { !$0.replacedExistingFile }
                .map { FileAccessManager.shared.reservationKey(for: $0.finalURL) }
        )
        for committedOutput in committed.reversed() {
            let destination = FileAccessManager.shared.reservationKey(for: committedOutput.finalURL)
            guard backupsByDestination[destination] != nil || committedNewDestinations.contains(destination) else {
                continue
            }

            let rollbackCoordinator = NSFileCoordinator(filePresenter: nil)
            var rollbackCoordinationError: NSError?
            rollbackCoordinator.coordinate(
                writingItemAt: committedOutput.finalURL,
                options: .forReplacing,
                error: &rollbackCoordinationError
            ) { coordinatedRollbackURL in
                do {
                    if let backupURL = backupsByDestination[destination],
                       fileManager.fileExists(atPath: backupURL.path) {
                        if fileManager.fileExists(atPath: coordinatedRollbackURL.path) {
                            try fileManager.removeItem(at: coordinatedRollbackURL)
                        }
                        try fileManager.moveItem(at: backupURL, to: coordinatedRollbackURL)
                    } else if committedNewDestinations.contains(destination),
                              fileManager.fileExists(atPath: coordinatedRollbackURL.path) {
                        try fileManager.removeItem(at: coordinatedRollbackURL)
                    }
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            if let rollbackCoordinationError {
                rollbackError = rollbackError ?? rollbackCoordinationError
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
        throw failure
    }

    /// Gives the hidden backup of a replaced file a readable name next to the
    /// new file, then moves it to the Trash so the user can restore it.
    /// Returns the item's location in the Trash, or nil when the volume has
    /// no Trash.
    static func moveReplacedOriginalToTrash(_ backupURL: URL, originalURL: URL, date: Date = Date()) -> URL? {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        let label = "\(base) (replaced \(formatter.string(from: date)))"
        let readableURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(ext.isEmpty ? label : "\(label).\(ext)")
        do {
            if !fileManager.fileExists(atPath: readableURL.path) {
                try fileManager.moveItem(at: backupURL, to: readableURL)
            }
            let source = fileManager.fileExists(atPath: readableURL.path) ? readableURL : backupURL
            if let testTrash = ReplacedFileTrash.directoryOverride {
                try fileManager.createDirectory(at: testTrash, withIntermediateDirectories: true)
                let target = testTrash.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
                try fileManager.moveItem(at: source, to: target)
                return target
            }
            var resulting: NSURL?
            try fileManager.trashItem(at: source, resultingItemURL: &resulting)
            return (resulting as URL?) ?? source
        } catch {
            // Leave nothing visible behind; the caller deletes the backup.
            if fileManager.fileExists(atPath: readableURL.path), !fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: readableURL, to: backupURL)
            }
            return nil
        }
    }

    public static func cleanupTemporaryFile(at url: URL?) {
        guard let url = url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func resolveCustomFolderBookmark(_ bookmarkData: Data, displayPath: String) throws -> URL {
        guard !bookmarkData.isEmpty else {
            throw ConversionError.sandboxAccessFailure(path: displayPath)
        }

        var scopedBookmarkIsStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &scopedBookmarkIsStale
            )
            if scopedBookmarkIsStale {
                throw ConversionError.sandboxAccessFailure(path: displayPath)
            }
            return try validateResolvedCustomFolder(url, displayPath: displayPath)
        } catch let error as ConversionError {
            throw error
        } catch {
            // Finder bookmarks may require implicit-scope resolution.
        }

        var ephemeralBookmarkIsStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &ephemeralBookmarkIsStale
            )
            if ephemeralBookmarkIsStale {
                throw ConversionError.sandboxAccessFailure(path: displayPath)
            }
            return try validateResolvedCustomFolder(url, displayPath: displayPath)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.sandboxAccessFailure(path: displayPath)
        }
    }

    private static func validateResolvedCustomFolder(_ url: URL, displayPath: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConversionError.sandboxAccessFailure(path: displayPath)
        }
        return url
    }

    private static func isOccupied(_ url: URL, reservedURLs: Set<URL>) -> Bool {
        reservedURLs.contains(FileAccessManager.shared.reservationKey(for: url))
            || FileManager.default.fileExists(atPath: url.path)
    }

    private static func canonicalReservationKeys(_ reservedURLs: Set<URL>) -> Set<URL> {
        Set(reservedURLs.map { FileAccessManager.shared.reservationKey(for: $0) })
    }
}

/// Where replaced files go. In test processes they go to a temporary folder
/// instead of the user's Trash.
public enum ReplacedFileTrash {
    private static let box = OverrideBox()

    public static var directoryOverride: URL? {
        get { box.value }
        set { box.value = newValue }
    }

    private final class OverrideBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL? = NSClassFromString("XCTestCase") != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("FileConverterTestTrash", isDirectory: true)
            : nil

        var value: URL? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
