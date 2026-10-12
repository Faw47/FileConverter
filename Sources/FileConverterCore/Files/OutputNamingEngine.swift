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

    public static func generateFormattedFilename(
        sourceURL: URL,
        preset: ConversionPreset,
        targetExtension: String,
        suffix: String? = nil
    ) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let cleanExt = targetExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()

        var pattern = preset.filenamePattern
        if pattern.isEmpty || pattern == "{name}" {
            if let defaultPattern = UserDefaults.standard.string(forKey: "fc.defaultFilenamePattern"),
               !defaultPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pattern = defaultPattern
            } else if pattern.isEmpty {
                pattern = "{name}"
            }
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
        let policyRaw = UserDefaults.standard.string(forKey: "outputDirectoryPolicy")
            ?? UserDefaults.standard.string(forKey: "fc.defaultOutputPolicy")
            ?? "sameAsSource"
        switch policyRaw {
        case "downloads":
            return .downloads
        case "custom":
            if let bookmark = UserDefaults.standard.data(forKey: "fc.customOutputFolderBookmark"),
               let path = UserDefaults.standard.string(forKey: "fc.customOutputFolderPath"),
               !path.isEmpty {
                return .customFolder(bookmarkData: bookmark, displayPath: path)
            }
            return .sameAsSource
        default:
            return .sameAsSource
        }
    }

    public static func resolveFinalDestinationURL(
        sourceURL: URL,
        preset: ConversionPreset,
        targetExtension: String? = nil,
        suffix: String? = nil,
        reservedURLs: Set<URL> = [],
        customFolderURL: URL? = nil,
        collisionPlan: CollisionResolutionPlan? = nil
    ) throws -> URL {
        let reservationKeys = canonicalReservationKeys(reservedURLs)
        let ext = targetExtension ?? preset.destinationFormat
        let effectivePolicy: OutputDirectoryPolicy
        var effectiveCustomFolderURL = customFolderURL
        if preset.outputDirectoryPolicy == .sameAsSource {
            let globalPolicy = globalDefaultOutputPolicy
            if globalPolicy != .sameAsSource {
                effectivePolicy = globalPolicy
                if case .customFolder(let bookmarkData, let displayPath) = globalPolicy, effectiveCustomFolderURL == nil {
                    effectiveCustomFolderURL = try resolveCustomFolderBookmark(
                        bookmarkData,
                        displayPath: displayPath
                    )
                }
            } else {
                effectivePolicy = .sameAsSource
            }
        } else {
            effectivePolicy = preset.outputDirectoryPolicy
        }

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

        let filename = generateFormattedFilename(sourceURL: sourceURL, preset: preset, targetExtension: ext, suffix: suffix)
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
                throw ConversionError.outputCollision(path: idealURL.path)
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
        )
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
    ) throws -> [URL] {
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
            for backupURL in backupsByDestination.values {
                try? fileManager.removeItem(at: backupURL)
            }
            return committed.map(\.finalURL)
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
