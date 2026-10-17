import AppIntents
import FileConverterCore
import FileConverterNativeBackends
import Foundation
import UniformTypeIdentifiers

/// A preset, as Shortcuts and Siri see it. Its id is the preset's own UUID,
/// which never changes, so saved shortcuts keep finding it.
struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetQuery()

    let id: UUID
    @Property(title: "Finder Menu Name") var menuName: String
    @Property(title: "Name") var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(menuName)", subtitle: "\(name)")
    }

    init(_ preset: ConversionPreset) {
        id = preset.id
        menuName = preset.menuName
        name = preset.name
    }
}

/// Presets that can run without File Converter's PDF dialogs.
struct PresetQuery: EntityStringQuery {
    private static var runnable: [ConversionPreset] {
        PresetStore.shared.enabledPresets.filter { !$0.isInteractiveWorkflow }
    }

    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        let wanted = Set(identifiers)
        return Self.runnable.filter { wanted.contains($0.id) }.map(PresetEntity.init)
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        Self.runnable.map(PresetEntity.init)
    }

    func entities(matching string: String) async throws -> [PresetEntity] {
        Self.runnable
            .filter {
                $0.menuName.localizedCaseInsensitiveContains(string)
                    || $0.name.localizedCaseInsensitiveContains(string)
                    || $0.destinationFormat.localizedCaseInsensitiveContains(string)
            }
            .map(PresetEntity.init)
    }
}

struct ConvertFilesError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

/// Converts files with a preset and returns the converted files, for use in
/// Shortcuts, Quick Actions, and Siri.
struct ConvertFilesIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription(
        "Converts files with a File Converter preset and returns the converted files. They are saved where the preset says, or in the folder you choose."
    )
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @Parameter(title: "Save to", description: "Leave empty to save where the preset says.")
    var saveTo: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) with \(\.$preset)") {
            \.$saveTo
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard var stored = PresetStore.shared.preset(forID: preset.id), !stored.isInteractiveWorkflow else {
            throw ConvertFilesError(localizedStringResource: "That preset is no longer available.")
        }
        let urls = try IntentConversion.localURLs(for: files)
        guard !urls.isEmpty else {
            throw ConvertFilesError(localizedStringResource: "No files were given to convert.")
        }
        guard !PresetValidator.compatiblePresets(forURLs: urls, from: [stored]).isEmpty else {
            throw ConvertFilesError(localizedStringResource: "This preset can't convert these files.")
        }
        if let folder = saveTo?.fileURL {
            stored = try IntentConversion.saving(stored, to: folder)
        }
        // Everything is checked; the conversion itself comes last.
        let outputs = try await IntentConversion.convertAndWait(urls: urls, preset: stored, progress: progress)
        return .result(value: outputs.map { IntentFile(fileURL: $0) })
    }
}

/// Compresses PDFs with the Compress PDF preset's own settings, without
/// showing its dialog.
struct CompressPDFIntent: AppIntent, ProgressReportingIntent {
    static let title: LocalizedStringResource = "Compress PDF"
    static let description = IntentDescription(
        "Makes PDFs smaller with File Converter's Compress PDF settings and returns the compressed PDFs. Each is saved next to the original with “-compressed” added to its name, or in the folder you choose."
    )
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "PDFs")
    var files: [IntentFile]

    @Parameter(title: "Save to", description: "Leave empty to save next to each PDF.")
    var saveTo: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$files)") {
            \.$saveTo
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard var preset = Self.compressPreset() else {
            throw ConvertFilesError(localizedStringResource: "The Compress PDF preset is missing. Restore it in File Converter's settings.")
        }
        let urls = try IntentConversion.localURLs(for: files)
        guard !urls.isEmpty else {
            throw ConvertFilesError(localizedStringResource: "No PDFs were given to compress.")
        }
        guard urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) else {
            throw ConvertFilesError(localizedStringResource: "Only PDFs can be compressed.")
        }
        // The same name ending the Compress PDF dialog starts with.
        var inheritance = preset.resolvedInheritance
        if !preset.filenamePattern.hasPrefix("{name}") || preset.filenamePattern == "{name}" {
            preset.filenamePattern = "{name}-" + (preset.sameFormatSuffix ?? "compressed")
        }
        inheritance.filenamePattern = false
        preset.sameFormatSuffix = nil
        preset.inheritance = inheritance
        if let folder = saveTo?.fileURL {
            preset = try IntentConversion.saving(preset, to: folder)
        }
        let outputs = try await IntentConversion.convertAndWait(urls: urls, preset: preset, progress: progress)
        return .result(value: outputs.map { IntentFile(fileURL: $0) })
    }

    private static func compressPreset() -> ConversionPreset? {
        let presets = PresetStore.shared.presets.filter(\.isPDFCompressWorkflow)
        return presets.first { $0.builtInKey == "document.pdf-compressed" } ?? presets.first
    }
}

/// Puts PDFs and images into one PDF, in the order given.
struct CombineIntoPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Combine into PDF"
    static let description = IntentDescription(
        "Puts PDFs and images into one PDF, in the order given, and returns it. It is saved in the first file's folder, or in the folder you choose."
    )
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Name", default: "Combined")
    var name: String

    @Parameter(title: "Save to", description: "Leave empty to save in the first file's folder.")
    var saveTo: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Combine \(\.$files) into a PDF named \(\.$name)") {
            \.$saveTo
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        await MainActor.run { AppDelegate.shared?.stayInBackgroundIfLaunchedForIntent() }
        let urls = try IntentConversion.localURLs(for: files)
        guard PDFCombiner.canCombine(urls) else {
            throw ConvertFilesError(localizedStringResource: "Give two or more PDFs or images to combine.")
        }
        let folderURL = saveTo?.fileURL
        guard let folder = folderURL ?? urls.first?.deletingLastPathComponent() else {
            throw ConvertFilesError(localizedStringResource: "No files were given to combine.")
        }
        let accessed = folderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if accessed { folderURL?.stopAccessingSecurityScopedResource() } }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let base = trimmed.isEmpty ? "Combined" : (trimmed.lowercased().hasSuffix(".pdf") ? String(trimmed.dropLast(4)) : trimmed)
        let destination = Self.unusedURL(in: folder, base: base)
        try await Task.detached(priority: .userInitiated) {
            _ = try PDFCombiner.combine(urls, into: destination)
        }.value
        return .result(value: IntentFile(fileURL: destination))
    }

    /// "Combined.pdf", or "Combined 2.pdf" and so on when that is taken;
    /// combining never replaces a file.
    private static func unusedURL(in folder: URL, base: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("pdf")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension("pdf")
            number += 1
        }
        return candidate
    }
}

/// Shared by the actions that run conversions through the queue.
enum IntentConversion {
    /// Files from Shortcuts may arrive as data without a location; those
    /// are written to a temporary folder first.
    static func localURLs(for files: [IntentFile]) throws -> [URL] {
        var urls: [URL] = []
        var temporary: URL?
        for file in files {
            if let url = file.fileURL {
                urls.append(url)
                continue
            }
            if temporary == nil {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FileConverterShortcuts-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                temporary = folder
            }
            let name = file.filename.isEmpty ? "File" : file.filename
            let url = temporary!.appendingPathComponent(name)
            try file.data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// The preset, saving into `folder` instead of where it says, as the
    /// preset picker's "Save to" choice does.
    static func saving(_ original: ConversionPreset, to folder: URL) throws -> ConversionPreset {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        guard let bookmark = (try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? folder.bookmarkData()) else {
            throw ConvertFilesError(localizedStringResource: "File Converter can't save to that folder.")
        }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw ConvertFilesError(localizedStringResource: "Choose a folder to save to.")
        }
        var preset = original
        var inheritance = preset.resolvedInheritance
        preset.outputDirectoryPolicy = .customFolder(bookmarkData: bookmark, displayPath: folder.path)
        inheritance.outputLocation = false
        preset.inheritance = inheritance
        return preset
    }

    /// Queues the files and waits for their jobs to finish, following the
    /// queue's changes rather than polling it. Reports progress as the jobs
    /// run, and cancels them if the shortcut is stopped.
    @MainActor
    static func convertAndWait(urls: [URL], preset: ConversionPreset, progress: Progress) async throws -> [URL] {
        AppDelegate.shared?.stayInBackgroundIfLaunchedForIntent()
        let queue = ConversionQueue.shared
        let before = Set(queue.jobs.map(\.id))
        let wanted = Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        progress.totalUnitCount = Int64(urls.count) * 100
        progress.completedUnitCount = 0
        try await AppState.shared.convertFilesWhenReady(urls: urls, preset: preset)

        func ownJobs(in jobs: [ConversionJob]) -> [ConversionJob] {
            jobs.filter {
                !before.contains($0.id) && wanted.contains($0.sourceURL.resolvingSymlinksInPath().standardizedFileURL.path)
            }
        }
        let ids = Set(ownJobs(in: queue.jobs).map(\.id))

        let finished: [ConversionJob]? = await withTaskCancellationHandler {
            // Sends the current jobs first, then every change.
            for await jobs in queue.jobUpdates() {
                let mine = ownJobs(in: jobs)
                guard !mine.isEmpty else { continue }
                progress.totalUnitCount = Int64(mine.count) * 100
                progress.completedUnitCount = mine.reduce(0) { total, job in
                    total + (job.state.isTerminal ? 100 : Int64(min(max(job.progress.fractionCompleted, 0), 1) * 100))
                }
                if mine.allSatisfy(\.state.isTerminal) { return mine }
            }
            return nil
        } onCancel: {
            Task { @MainActor in
                for id in ids { ConversionQueue.shared.cancelJob(id: id) }
            }
        }
        try Task.checkCancellation()
        guard let finished else { throw CancellationError() }

        let outputs = finished.flatMap { job -> [URL] in
            switch job.state {
            case .completed, .completedWithWarnings:
                return job.outputURLs.isEmpty ? (job.destinationURL.map { [$0] } ?? []) : job.outputURLs
            default:
                return []
            }
        }
        guard !outputs.isEmpty else {
            let reason = finished.compactMap { job -> String? in
                if case .failed(let error) = job.state { return error.localizedDescription }
                return nil
            }.first ?? "Nothing was converted."
            throw ConvertFilesError(localizedStringResource: "\(reason)")
        }
        return outputs
    }
}

struct FileConverterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertFilesIntent(),
            phrases: ["Convert files with \(.applicationName)"],
            shortTitle: "Convert Files",
            systemImageName: "arrow.left.arrow.right"
        )
        AppShortcut(
            intent: CompressPDFIntent(),
            phrases: ["Compress PDFs with \(.applicationName)"],
            shortTitle: "Compress PDF",
            systemImageName: "arrow.down.right.and.arrow.up.left"
        )
        AppShortcut(
            intent: CombineIntoPDFIntent(),
            phrases: ["Combine into PDF with \(.applicationName)"],
            shortTitle: "Combine into PDF",
            systemImageName: "doc.on.doc"
        )
    }
}
