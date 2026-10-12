import Foundation

/// Represents a single conflict between an incoming imported preset and an existing preset in the store.
public struct PresetImportConflict: Identifiable, Sendable {
    public var id: UUID { importedPreset.id }
    public let importedPreset: ConversionPreset
    public let existingPreset: ConversionPreset
    public let conflictReason: ConflictReason

    public enum ConflictReason: String, Sendable {
        case sameID = "Matches identifier of existing preset"
        case sameName = "Matches name of existing preset"
        case sameIDAndName = "Matches identifier and name of existing preset"
    }

    public init(importedPreset: ConversionPreset, existingPreset: ConversionPreset, conflictReason: ConflictReason) {
        self.importedPreset = importedPreset
        self.existingPreset = existingPreset
        self.conflictReason = conflictReason
    }
}

public enum PresetConflictResolution: String, CaseIterable, Sendable {
    case replace = "Replace"
    case copy = "Import as Copy"
    case skip = "Skip"
}

public enum PresetExchangeError: Error, LocalizedError, Sendable {
    case malformedJSON(String)
    case unsupportedSchemaVersion(Int)
    case missingField(preset: String, field: String)
    case invalidField(preset: String, field: String, reason: String)
    case incompatibleConfiguration(preset: String, reason: String)
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .malformedJSON(let details):
            return "The presets file contains malformed JSON: \(details)"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported schema version \(version). Please update File Converter to import this file."
        case .missingField(let preset, let field):
            return "Preset '\(preset)': Required field '\(field)' is missing or empty."
        case .invalidField(let preset, let field, let reason):
            return "Preset '\(preset)': Field '\(field)' is invalid: \(reason)"
        case .incompatibleConfiguration(let preset, let reason):
            return "Preset '\(preset)': Incompatible configuration: \(reason)"
        case .emptyDocument:
            return "The preset file contains no presets."
        }
    }
}


/// Serializes and deserializes presets in human-readable, schema-versioned portable JSON.
public enum PresetExchange {
    public static let currentSchemaVersion = 1

    // MARK: - Export

    public static func exportAll(presets: [ConversionPreset], includeLocalPaths: Bool = false) throws -> Data {
        let exportablePresets = presets.map { presetToDictionary($0, includeLocalPaths: includeLocalPaths) }
        let document: [String: Any] = [
            "schemaVersion": currentSchemaVersion,
            "minCompatibleVersion": 1,
            "presets": exportablePresets
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func exportSingle(preset: ConversionPreset, includeLocalPaths: Bool = false) throws -> Data {
        let exportable = presetToDictionary(preset, includeLocalPaths: includeLocalPaths)
        let document: [String: Any] = [
            "schemaVersion": currentSchemaVersion,
            "minCompatibleVersion": 1,
            "presets": [exportable]
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Import

    public static func importPresets(from data: Data) throws -> [ConversionPreset] {
        guard !data.isEmpty else {
            throw PresetExchangeError.malformedJSON("The data is empty.")
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PresetExchangeError.malformedJSON(error.localizedDescription)
        }

        // Case 1: Standard dictionary document with schemaVersion
        if let dict = jsonObject as? [String: Any] {
            return try parseDocumentDictionary(dict)
        }

        // Case 2: Legacy raw array of presets
        if let array = jsonObject as? [[String: Any]] {
            return try parsePresetsArray(array, schemaVersion: 1)
        }

        throw PresetExchangeError.malformedJSON("Expected a top-level JSON object or array of presets.")
    }

    private static func parseDocumentDictionary(_ dict: [String: Any]) throws -> [ConversionPreset] {
        let version = dict["schemaVersion"] as? Int ?? 1
        let minCompatible = dict["minCompatibleVersion"] as? Int ?? version
        guard minCompatible <= currentSchemaVersion else {
            throw PresetExchangeError.unsupportedSchemaVersion(version)
        }

        if let presetsArray = dict["presets"] as? [[String: Any]] {
            guard !presetsArray.isEmpty else {
                throw PresetExchangeError.emptyDocument
            }
            return try parsePresetsArray(presetsArray, schemaVersion: version)
        }

        if let singlePresetDict = dict["preset"] as? [String: Any] {
            let preset = try dictionaryToPreset(singlePresetDict, index: 0, schemaVersion: version)
            if let error = PresetValidator.validationErrors(for: preset).first {
                throw PresetExchangeError.incompatibleConfiguration(preset: preset.name, reason: error)
            }
            return [preset]
        }

        // Check if top-level dictionary is itself a single preset
        if dict["name"] != nil {
            let preset = try dictionaryToPreset(dict, index: 0, schemaVersion: version)
            if let error = PresetValidator.validationErrors(for: preset).first {
                throw PresetExchangeError.incompatibleConfiguration(preset: preset.name, reason: error)
            }
            return [preset]
        }

        throw PresetExchangeError.malformedJSON("Document is missing a 'presets' array.")
    }

    private static func parsePresetsArray(_ array: [[String: Any]], schemaVersion: Int) throws -> [ConversionPreset] {
        guard !array.isEmpty else {
            throw PresetExchangeError.emptyDocument
        }
        var results: [ConversionPreset] = []
        for (index, dict) in array.enumerated() {
            let preset = try dictionaryToPreset(dict, index: index, schemaVersion: schemaVersion)
            if let error = PresetValidator.validationErrors(for: preset).first {
                throw PresetExchangeError.incompatibleConfiguration(preset: preset.name, reason: error)
            }
            results.append(preset)
        }
        return results
    }

    // MARK: - Dictionary <-> ConversionPreset Mapping

    private static func presetToDictionary(_ preset: ConversionPreset, includeLocalPaths: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["id"] = preset.id.uuidString
        if let builtInKey = preset.builtInKey {
            dict["builtInKey"] = builtInKey
        }
        dict["name"] = preset.name
        dict["menuTitle"] = preset.menuName
        dict["category"] = preset.category.rawValue
        dict["enabled"] = preset.isEnabled
        dict["sources"] = preset.sourceFormats
        dict["sortOrder"] = preset.sortOrder

        // Output section
        var output: [String: Any] = [
            "container": preset.container ?? preset.destinationFormat,
            "extension": preset.destinationFormat,
            "filenamePattern": preset.filenamePattern,
            "overwritePolicy": preset.overwritePolicy.rawValue
        ]
        switch preset.outputDirectoryPolicy {
        case .sameAsSource:
            output["directory"] = ["type": "sameAsSource"]
        case .downloads:
            output["directory"] = ["type": "downloads"]
        case .sourceSubfolder(let sub):
            output["directory"] = ["type": "subfolder", "subfolder": sub]
        case .customFolder(let bookmark, let displayPath):
            if includeLocalPaths {
                var dirInfo: [String: Any] = [
                    "type": "customFolder",
                    "path": displayPath
                ]
                if !bookmark.isEmpty {
                    dirInfo["bookmark"] = bookmark.base64EncodedString()
                }
                output["directory"] = dirInfo
            } else {
                output["directory"] = ["type": "sameAsSource"]
            }
        }
        dict["output"] = output

        // Conversion section
        var conversion: [String: Any] = [
            "engine": preset.backend.rawValue,
            "videoCodec": preset.videoCodec.rawValue,
            "quality": preset.quality.rawValue,
            "hardwareAcceleration": preset.hardwareAcceleration.rawValue
        ]

        // Format-aware audio codec representation distinguishing codec from container
        if preset.audioCodec == .wav || preset.destinationFormat.lowercased() == "wav" {
            let depth = preset.audioBitDepth ?? .bit16
            conversion["audioCodec"] = depth.ffmpegWavCodec
            conversion["pcmBitDepth"] = depth.rawValue
        } else if preset.audioCodec == .aiff || preset.destinationFormat.lowercased() == "aiff" || preset.destinationFormat.lowercased() == "aif" {
            let depth = preset.audioBitDepth ?? .bit16
            conversion["audioCodec"] = depth.ffmpegAiffCodec
            conversion["pcmBitDepth"] = depth.rawValue
        } else {
            conversion["audioCodec"] = preset.audioCodec.rawValue
            if let bitDepth = preset.audioBitDepth {
                conversion["pcmBitDepth"] = bitDepth.rawValue
            }
        }

        if let audioBitrate = preset.audioBitrateKbps {
            conversion["audioBitrateKbps"] = audioBitrate
        }
        if let sampleRate = preset.audioSampleRate {
            conversion["sampleRate"] = sampleRate
        }
        if let channels = preset.audioChannels {
            conversion["channels"] = channels
        }
        if let videoBitrate = preset.videoBitrateKbps {
            conversion["videoBitrateKbps"] = videoBitrate
        }
        if let crf = preset.crf {
            conversion["crf"] = crf
        }
        switch preset.resolution {
        case .original:
            conversion["resolution"] = "original"
        case .uhd4k:
            conversion["resolution"] = "uhd4k"
        case .hd1080p:
            conversion["resolution"] = "hd1080p"
        case .hd720p:
            conversion["resolution"] = "hd720p"
        case .sd480p:
            conversion["resolution"] = "sd480p"
        case .custom(let w, let h):
            conversion["resolution"] = "\(w)x\(h)"
        }
        if let framerate = preset.framerate {
            conversion["framerate"] = framerate
        }
        if !preset.extraBackendOptions.isEmpty {
            conversion["extraBackendOptions"] = preset.extraBackendOptions
        }
        dict["conversion"] = conversion

        // Split section
        if let splitSeconds = preset.audioSplitDurationSeconds {
            dict["split"] = [
                "enabled": true,
                "partLength": AudioDurationParser.format(seconds: splitSeconds)
            ]
        } else {
            dict["split"] = ["enabled": false]
        }

        // File-size target section
        if let targetBytes = preset.audioTargetFileSizeBytes {
            dict["targetFileSize"] = [
                "enabled": true,
                "targetBytes": targetBytes
            ]
        } else {
            dict["targetFileSize"] = ["enabled": false]
        }

        // PDF section
        if preset.splitPDFIntoPages || preset.processingOptions?.pdfSplitMode != nil || preset.processingOptions?.pdfCompressionProfile != nil {
            var pdfOptions: [String: Any] = ["splitIntoPages": preset.splitPDFIntoPages]
            if let mode = preset.processingOptions?.pdfSplitMode { pdfOptions["splitMode"] = mode }
            if let ranges = preset.processingOptions?.pdfPageRanges { pdfOptions["pageRanges"] = ranges }
            if let chunk = preset.processingOptions?.pdfChunkSize { pdfOptions["chunkSize"] = chunk }
            if let selected = preset.processingOptions?.pdfSelectedPages { pdfOptions["selectedPages"] = selected }
            if let merge = preset.processingOptions?.pdfMergeSplitOutputs { pdfOptions["mergeSplitOutputs"] = merge }
            if let pattern = preset.processingOptions?.pdfNamingPattern { pdfOptions["namingPattern"] = pattern }
            if let pad = preset.processingOptions?.pdfZeroPadDigits { pdfOptions["zeroPadDigits"] = pad }
            if let subfolder = preset.processingOptions?.pdfOutputSubfolder { pdfOptions["outputSubfolder"] = subfolder }
            if let profile = preset.processingOptions?.pdfCompressionProfile { pdfOptions["compressionProfile"] = profile }
            if let dpi = preset.processingOptions?.pdfDPI { pdfOptions["dpi"] = dpi }
            if let quality = preset.processingOptions?.pdfImageQuality { pdfOptions["imageQuality"] = quality }
            if let colorMode = preset.processingOptions?.pdfColorMode { pdfOptions["colorMode"] = colorMode }
            if let removeMetadata = preset.processingOptions?.pdfRemoveMetadata, removeMetadata { pdfOptions["removeMetadata"] = removeMetadata }
            if let removeAnnotations = preset.processingOptions?.pdfRemoveAnnotations, removeAnnotations { pdfOptions["removeAnnotations"] = removeAnnotations }
            if let removeThumbnails = preset.processingOptions?.pdfRemoveThumbnails, removeThumbnails { pdfOptions["removeThumbnails"] = removeThumbnails }
            if let linearize = preset.processingOptions?.pdfLinearize, linearize { pdfOptions["linearize"] = linearize }
            if let compatibility = preset.processingOptions?.pdfCompatibilityLevel { pdfOptions["compatibilityLevel"] = compatibility }
            dict["pdf"] = pdfOptions
        }

        // Metadata section
        dict["metadata"] = [
            "preserveMetadata": preset.preserveMetadata,
            "preserveCreationDate": preset.preserveCreationDate
        ]

        // Preserve unrecognized opaque fields from newer schema if present
        if let opaque = preset.opaqueFields {
            for (k, v) in opaque.fields where dict[k] == nil {
                if !includeLocalPaths {
                    let lowerKey = k.lowercased()
                    if lowerKey.contains("path") || lowerKey.contains("bookmark") || lowerKey.contains("url") {
                        continue
                    }
                    if let str = v.value as? String, str.hasPrefix("/") {
                        continue
                    }
                }
                dict[k] = v.value
            }
        } else if let extra = preset.extraBackendOptions["__unrecognizedJSON"],
                  let extraData = extra.data(using: .utf8),
                  let extraDict = try? JSONSerialization.jsonObject(with: extraData) as? [String: Any] {
            for (k, v) in extraDict where dict[k] == nil {
                if !includeLocalPaths {
                    let lowerKey = k.lowercased()
                    if lowerKey.contains("path") || lowerKey.contains("bookmark") || lowerKey.contains("url") {
                        continue
                    }
                    if let str = v as? String, str.hasPrefix("/") {
                        continue
                    }
                }
                dict[k] = v
            }
        }

        return dict
    }

    private static func dictionaryToPreset(_ dict: [String: Any], index: Int, schemaVersion: Int) throws -> ConversionPreset {
        let presetName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = presetName.isEmpty ? "Preset #\(index + 1)" : presetName
        guard !presetName.isEmpty else {
            throw PresetExchangeError.missingField(preset: displayName, field: "name")
        }

        let menuTitle = (dict["menuTitle"] as? String ?? dict["menuName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? presetName
        guard !menuTitle.isEmpty else {
            throw PresetExchangeError.missingField(preset: displayName, field: "menuTitle")
        }

        // Category
        guard let categoryRaw = dict["category"] as? String else {
            throw PresetExchangeError.missingField(preset: displayName, field: "category")
        }
        guard let category = FormatCategory(rawValue: categoryRaw.lowercased()) else {
            let valid = FormatCategory.allCases.map(\.rawValue).joined(separator: ", ")
            throw PresetExchangeError.invalidField(preset: displayName, field: "category", reason: "Unsupported category '\(categoryRaw)'. Must be one of: \(valid)")
        }

        let isEnabled = dict["enabled"] as? Bool ?? true
        let sortOrder = dict["sortOrder"] as? Int ?? 0

        // Sources
        var sources: [String] = []
        if let srcArray = dict["sources"] as? [String] ?? dict["sourceFormats"] as? [String] {
            sources = srcArray.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        }
        if sources.isEmpty {
            sources = [category.rawValue]
        }

        // Output section
        let outputDict = dict["output"] as? [String: Any] ?? dict
        let destinationFormat = ((outputDict["extension"] as? String
            ?? outputDict["format"] as? String
            ?? outputDict["destinationFormat"] as? String
            ?? dict["destinationFormat"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()) ?? ""
        guard !destinationFormat.isEmpty else {
            throw PresetExchangeError.missingField(preset: displayName, field: "destinationFormat")
        }

        let container = (outputDict["container"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filenamePattern = (outputDict["filenamePattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "{name}"

        var overwritePolicy: OverwritePolicy = .appendNumber
        if let overwriteRaw = outputDict["overwritePolicy"] as? String {
            guard let parsed = OverwritePolicy(rawValue: overwriteRaw) else {
                let valid = OverwritePolicy.allCases.map(\.rawValue).joined(separator: ", ")
                throw PresetExchangeError.invalidField(preset: displayName, field: "output.overwritePolicy", reason: "Unsupported value '\(overwriteRaw)'. Must be one of: \(valid)")
            }
            overwritePolicy = parsed
        }

        var outputDirectoryPolicy: OutputDirectoryPolicy = .sameAsSource
        if let dirDict = outputDict["directory"] as? [String: Any] {
            let dirType = dirDict["type"] as? String ?? "sameAsSource"
            switch dirType {
            case "downloads":
                outputDirectoryPolicy = .downloads
            case "subfolder":
                let sub = (dirDict["subfolder"] as? String ?? "Converted").trimmingCharacters(in: .whitespacesAndNewlines)
                outputDirectoryPolicy = .sourceSubfolder(subfolderName: sub.isEmpty ? "Converted" : sub)
            case "customFolder":
                let displayPath = dirDict["path"] as? String ?? dirDict["displayPath"] as? String ?? ""
                let bookmarkBase64 = dirDict["bookmark"] as? String ?? ""
                let bookmarkData = Data(base64Encoded: bookmarkBase64) ?? Data()
                outputDirectoryPolicy = .customFolder(bookmarkData: bookmarkData, displayPath: displayPath)
            default:
                outputDirectoryPolicy = .sameAsSource
            }
        }

        // Conversion section
        let convDict = dict["conversion"] as? [String: Any] ?? dict["audio"] as? [String: Any] ?? dict

        var backend: BackendType = .auto
        if let engineRaw = convDict["engine"] as? String ?? convDict["backend"] as? String {
            guard let parsed = BackendType(rawValue: engineRaw) else {
                let valid = BackendType.allCases.map(\.rawValue).joined(separator: ", ")
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.engine", reason: "Unsupported engine '\(engineRaw)'. Must be one of: \(valid)")
            }
            backend = parsed
        }

        var videoCodec: VideoCodecType = .auto
        if let vCodecRaw = convDict["videoCodec"] as? String {
            guard let parsed = VideoCodecType(rawValue: vCodecRaw.lowercased()) else {
                let valid = VideoCodecType.allCases.map(\.rawValue).joined(separator: ", ")
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.videoCodec", reason: "Unsupported video codec '\(vCodecRaw)'. Must be one of: \(valid)")
            }
            videoCodec = parsed
        }

        // Parse Audio Codec & Bit Depth with alias support
        var audioCodec: AudioCodecType = .auto
        var audioBitDepth: AudioBitDepth? = nil

        let bitDepthRawOpt = convDict["pcmBitDepth"] as? String
            ?? convDict["bitDepth"] as? String
            ?? (dict["audio"] as? [String: Any])?["pcmBitDepth"] as? String
            ?? (dict["audio"] as? [String: Any])?["bitDepth"] as? String

        if let bitDepthRaw = bitDepthRawOpt {
            if let parsed = AudioBitDepth(rawValue: bitDepthRaw) ?? AudioBitDepth(ffmpegCodec: bitDepthRaw) {
                audioBitDepth = parsed
            } else {
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.pcmBitDepth", reason: "Unsupported bit depth '\(bitDepthRaw)'. Must be 16, 24, or 32float.")
            }
        }

        let aCodecRawOpt = convDict["audioCodec"] as? String
            ?? convDict["codec"] as? String
            ?? (dict["audio"] as? [String: Any])?["codec"] as? String
            ?? (dict["audio"] as? [String: Any])?["audioCodec"] as? String

        if let aCodecRaw = aCodecRawOpt {
            let cleanACodec = aCodecRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let direct = AudioCodecType(rawValue: cleanACodec) {
                audioCodec = direct
            } else if let depth = AudioBitDepth(ffmpegCodec: cleanACodec) {
                if cleanACodec.contains("be") {
                    audioCodec = .aiff
                } else {
                    audioCodec = .wav
                }
                audioBitDepth = depth
            } else if cleanACodec == "pcm" {
                audioCodec = .wav
            } else {
                let valid = AudioCodecType.allCases.map(\.rawValue).joined(separator: ", ")
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.audioCodec", reason: "Unsupported audio codec '\(aCodecRaw)'. Valid options include: \(valid), or pcm_s16le/pcm_s24le/pcm_f32le.")
            }
        }

        // Quality
        var quality: QualitySetting = .high
        if let qualRaw = convDict["quality"] as? String {
            guard let parsed = QualitySetting(rawValue: qualRaw) else {
                let valid = QualitySetting.allCases.map(\.rawValue).joined(separator: ", ")
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.quality", reason: "Unsupported quality '\(qualRaw)'. Must be one of: \(valid)")
            }
            quality = parsed
        }

        // Quality vs lossy check (Requirement 5)
        if quality == .lossless && PresetValidator.isLossyAudioCodec(audioCodec) {
            throw PresetExchangeError.incompatibleConfiguration(
                preset: displayName,
                reason: "Lossless quality cannot be selected with lossy audio codec '\(audioCodec.displayName)'."
            )
        }

        // Container vs codec check (Requirement 6)
        if !PresetValidator.isCodecCompatible(audioCodec: audioCodec, destinationFormat: destinationFormat) {
            throw PresetExchangeError.incompatibleConfiguration(
                preset: displayName,
                reason: "Destination format .\(destinationFormat) cannot contain audio codec \(audioCodec.displayName)."
            )
        }

        // Audio bitrate
        var audioBitrateKbps: Int? = nil
        let bitrateOpt = convDict["audioBitrateKbps"] as? Int
            ?? convDict["bitrateKbps"] as? Int
            ?? (dict["audio"] as? [String: Any])?["audioBitrateKbps"] as? Int
            ?? (dict["audio"] as? [String: Any])?["bitrateKbps"] as? Int
        if let br = bitrateOpt {
            guard br > 0 else {
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.audioBitrateKbps", reason: "Must be a positive integer.")
            }
            audioBitrateKbps = br
        }

        // Sample rate
        var audioSampleRate: Int? = nil
        let sampleRateOpt = convDict["sampleRate"] as? Int
            ?? convDict["audioSampleRate"] as? Int
            ?? (dict["audio"] as? [String: Any])?["sampleRate"] as? Int
            ?? (dict["audio"] as? [String: Any])?["audioSampleRate"] as? Int
        if let sr = sampleRateOpt {
            guard sr > 0, sr <= 384_000 else {
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.sampleRate", reason: "Must be a positive number up to 384,000 Hz.")
            }
            audioSampleRate = sr
        }

        // Channels
        var audioChannels: Int? = nil
        let channelsOpt = convDict["channels"] as? Int
            ?? convDict["audioChannels"] as? Int
            ?? (dict["audio"] as? [String: Any])?["channels"] as? Int
            ?? (dict["audio"] as? [String: Any])?["audioChannels"] as? Int
        if let ch = channelsOpt {
            guard (1...8).contains(ch) else {
                throw PresetExchangeError.invalidField(preset: displayName, field: "conversion.channels", reason: "Must be between 1 and 8.")
            }
            audioChannels = ch
        }

        var hardwareAcceleration: HardwareAccelerationPolicy = .auto
        if let hwRaw = convDict["hardwareAcceleration"] as? String {
            if let parsed = HardwareAccelerationPolicy(rawValue: hwRaw) {
                hardwareAcceleration = parsed
            }
        }

        let videoBitrateKbps: Int? = convDict["videoBitrateKbps"] as? Int
        let crf: Int? = convDict["crf"] as? Int
        let framerate: Double? = convDict["framerate"] as? Double
        var resolution: ResolutionSetting = .original
        if let resRaw = convDict["resolution"] as? String {
            switch resRaw.lowercased() {
            case "original": resolution = .original
            case "uhd4k", "4k": resolution = .uhd4k
            case "hd1080p", "1080p": resolution = .hd1080p
            case "hd720p", "720p": resolution = .hd720p
            case "sd480p", "480p": resolution = .sd480p
            default:
                let dims = resRaw.split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]), w > 0, h > 0 {
                    resolution = .custom(width: w, height: h)
                }
            }
        }

        var extraBackendOptions: [String: String] = convDict["extraBackendOptions"] as? [String: String] ?? [:]

        // Split audio processing
        var splitDurationSeconds: Int? = nil
        if let splitDict = dict["split"] as? [String: Any] {
            let splitEnabled = splitDict["enabled"] as? Bool ?? true
            if splitEnabled {
                if let partLengthStr = splitDict["partLength"] as? String {
                    if let error = AudioDurationParser.validateDurationString(partLengthStr) {
                        throw PresetExchangeError.invalidField(preset: displayName, field: "split.partLength", reason: error)
                    }
                    splitDurationSeconds = AudioDurationParser.parseSecondsInt(partLengthStr)
                } else if let seconds = splitDict["partLength"] as? Int ?? splitDict["seconds"] as? Int {
                    guard seconds >= 1 else {
                        throw PresetExchangeError.invalidField(preset: displayName, field: "split.partLength", reason: "Must be at least 1 second.")
                    }
                    splitDurationSeconds = seconds
                }
            }
        } else if let legacySeconds = (dict["processingOptions"] as? [String: Any])?["audioSplitDurationSeconds"] as? Int {
            splitDurationSeconds = legacySeconds
        }

        // File-size target processing
        var targetFileSizeBytes: Int? = nil
        if let targetDict = dict["targetFileSize"] as? [String: Any] {
            let targetEnabled = targetDict["enabled"] as? Bool ?? true
            if targetEnabled {
                if let bytes = targetDict["targetBytes"] as? Int {
                    guard bytes >= 256 * 1024 else {
                        throw PresetExchangeError.invalidField(preset: displayName, field: "targetFileSize.targetBytes", reason: "Target size must be at least 256 KB.")
                    }
                    targetFileSizeBytes = bytes
                }
            }
        }

        // Direct Stream Copy checks (Requirement 3)
        if audioCodec == .copy && targetFileSizeBytes != nil {
            throw PresetExchangeError.incompatibleConfiguration(
                preset: displayName,
                reason: "Direct Stream Copy cannot target a specific file size because it does not re-encode audio."
            )
        }

        // Metadata
        let metaDict = dict["metadata"] as? [String: Any] ?? dict
        let preserveMetadata = metaDict["preserveMetadata"] as? Bool ?? true
        let preserveCreationDate = metaDict["preserveCreationDate"] as? Bool ?? true

        // Capture unrecognized fields into opaqueFields for inert round-tripping
        let recognizedKeys: Set<String> = [
            "id", "builtInKey", "name", "menuTitle", "menuName", "category", "enabled",
            "sources", "sourceFormats", "sortOrder", "output", "conversion", "split",
            "targetFileSize", "metadata", "pdf", "processingOptions", "opaqueFields"
        ]
        let unrecognized = dict.filter { !recognizedKeys.contains($0.key) }
        var opaqueDict: [String: AnyCodableValue] = [:]
        for (key, val) in unrecognized {
            if let codableVal = AnyCodableValue.from(jsonValue: val) {
                opaqueDict[key] = codableVal
            }
        }
        if let unrec = extraBackendOptions.removeValue(forKey: "__unrecognizedJSON"),
           let unrecData = unrec.data(using: .utf8),
           let unrecDict = try? JSONSerialization.jsonObject(with: unrecData) as? [String: Any] {
            for (k, v) in unrecDict {
                if let codableVal = AnyCodableValue.from(jsonValue: v) {
                    opaqueDict[k] = codableVal
                }
            }
        }
        let opaqueFields = opaqueDict.isEmpty ? nil : PresetOpaqueFields(fields: opaqueDict)

        var splitPDFIntoPages = false
        var pdfSplitMode: String?
        var pdfPageRanges: String?
        var pdfChunkSize: Int?
        var pdfSelectedPages: [Int]?
        var pdfMergeSplitOutputs = false
        var pdfNamingPattern: String?
        var pdfZeroPadDigits: Int?
        var pdfOutputSubfolder: String?
        var pdfCompressionProfile: String?
        var pdfDPI: Int?
        var pdfImageQuality: Double?
        var pdfColorMode: String?
        var pdfRemoveMetadata = false
        var pdfRemoveAnnotations = false
        var pdfRemoveThumbnails = false
        var pdfLinearize = false
        var pdfCompatibilityLevel: String?

        if let pdfDict = dict["pdf"] as? [String: Any] {
            splitPDFIntoPages = pdfDict["splitIntoPages"] as? Bool ?? false
            pdfSplitMode = pdfDict["splitMode"] as? String
            pdfPageRanges = pdfDict["pageRanges"] as? String
            pdfChunkSize = pdfDict["chunkSize"] as? Int
            pdfSelectedPages = pdfDict["selectedPages"] as? [Int]
            pdfMergeSplitOutputs = pdfDict["mergeSplitOutputs"] as? Bool ?? false
            pdfNamingPattern = pdfDict["namingPattern"] as? String
            pdfZeroPadDigits = pdfDict["zeroPadDigits"] as? Int
            pdfOutputSubfolder = pdfDict["outputSubfolder"] as? String
            pdfCompressionProfile = pdfDict["compressionProfile"] as? String
            pdfDPI = pdfDict["dpi"] as? Int
            pdfImageQuality = pdfDict["imageQuality"] as? Double
            pdfColorMode = pdfDict["colorMode"] as? String
            pdfRemoveMetadata = pdfDict["removeMetadata"] as? Bool ?? false
            pdfRemoveAnnotations = pdfDict["removeAnnotations"] as? Bool ?? false
            pdfRemoveThumbnails = pdfDict["removeThumbnails"] as? Bool ?? false
            pdfLinearize = pdfDict["linearize"] as? Bool ?? false
            pdfCompatibilityLevel = pdfDict["compatibilityLevel"] as? String
        }

        let processingOptions = ConversionProcessingOptions(
            audioSplitDurationSeconds: splitDurationSeconds,
            audioTargetFileSizeBytes: targetFileSizeBytes,
            splitPDFIntoPages: splitPDFIntoPages,
            pdfSplitMode: pdfSplitMode,
            pdfPageRanges: pdfPageRanges,
            pdfChunkSize: pdfChunkSize,
            pdfSelectedPages: pdfSelectedPages,
            pdfMergeSplitOutputs: pdfMergeSplitOutputs,
            pdfNamingPattern: pdfNamingPattern,
            pdfZeroPadDigits: pdfZeroPadDigits,
            pdfOutputSubfolder: pdfOutputSubfolder,
            pdfCompressionProfile: pdfCompressionProfile,
            pdfDPI: pdfDPI,
            pdfImageQuality: pdfImageQuality,
            pdfColorMode: pdfColorMode,
            pdfRemoveMetadata: pdfRemoveMetadata,
            pdfRemoveAnnotations: pdfRemoveAnnotations,
            pdfRemoveThumbnails: pdfRemoveThumbnails,
            pdfLinearize: pdfLinearize,
            pdfCompatibilityLevel: pdfCompatibilityLevel
        )

        let presetID = (dict["id"] as? String).flatMap(UUID.init) ?? UUID()
        let builtInKey = dict["builtInKey"] as? String

        return ConversionPreset(
            id: presetID,
            builtInKey: builtInKey,
            name: presetName,
            menuName: menuTitle,
            category: category,
            sourceFormats: sources,
            destinationFormat: destinationFormat,
            backend: backend,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            container: container,
            quality: quality,
            videoBitrateKbps: videoBitrateKbps,
            crf: crf,
            resolution: resolution,
            framerate: framerate,
            audioBitrateKbps: audioBitrateKbps,
            audioSampleRate: audioSampleRate,
            audioChannels: audioChannels,
            audioBitDepth: audioBitDepth,
            hardwareAcceleration: hardwareAcceleration,
            preserveMetadata: preserveMetadata,
            preserveCreationDate: preserveCreationDate,
            outputDirectoryPolicy: outputDirectoryPolicy,
            filenamePattern: filenamePattern,
            overwritePolicy: overwritePolicy,
            extraBackendOptions: extraBackendOptions,
            processingOptions: processingOptions.isEmpty ? nil : processingOptions,
            opaqueFields: opaqueFields,
            isEnabled: isEnabled,
            isBuiltIn: builtInKey != nil,
            sortOrder: sortOrder
        )
    }
}
