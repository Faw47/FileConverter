import AppIntents
import FileConverterCore
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
struct ConvertFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Files"
    static let description = IntentDescription(
        "Converts files with a File Converter preset and returns the converted files. They are saved where the preset says, as when converting in the app."
    )

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$files) with \(\.$preset)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        guard let stored = PresetStore.shared.preset(forID: preset.id), !stored.isInteractiveWorkflow else {
            throw ConvertFilesError(localizedStringResource: "That preset is no longer available.")
        }
        let urls = try Self.localURLs(for: files)
        guard !urls.isEmpty else {
            throw ConvertFilesError(localizedStringResource: "No files were given to convert.")
        }
        guard !PresetValidator.compatiblePresets(forURLs: urls, from: [stored]).isEmpty else {
            throw ConvertFilesError(localizedStringResource: "This preset can't convert these files.")
        }
        // Everything is checked; the conversion itself comes last.
        let outputs = try await Self.convertAndWait(urls: urls, preset: stored)
        return .result(value: outputs.map { IntentFile(fileURL: $0) })
    }

    /// Files from Shortcuts may arrive as data without a location; those
    /// are written to a temporary folder first.
    private static func localURLs(for files: [IntentFile]) throws -> [URL] {
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

    @MainActor
    private static func convertAndWait(urls: [URL], preset: ConversionPreset) async throws -> [URL] {
        let queue = ConversionQueue.shared
        let before = Set(queue.jobs.map(\.id))
        let wanted = Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        try await AppState.shared.convertFilesWhenReady(urls: urls, preset: preset)

        let deadline = Date().addingTimeInterval(60 * 60)
        while Date() < deadline {
            let mine = queue.jobs.filter {
                !before.contains($0.id) && wanted.contains($0.sourceURL.resolvingSymlinksInPath().standardizedFileURL.path)
            }
            if !mine.isEmpty, mine.allSatisfy(\.state.isTerminal) {
                let outputs = mine.flatMap { job -> [URL] in
                    switch job.state {
                    case .completed, .completedWithWarnings:
                        return job.outputURLs.isEmpty ? (job.destinationURL.map { [$0] } ?? []) : job.outputURLs
                    default:
                        return []
                    }
                }
                guard !outputs.isEmpty else {
                    let reason = mine.compactMap { job -> String? in
                        if case .failed(let error) = job.state { return error.localizedDescription }
                        return nil
                    }.first ?? "Nothing was converted."
                    throw ConvertFilesError(localizedStringResource: "\(reason)")
                }
                return outputs
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ConvertFilesError(localizedStringResource: "The conversion is taking too long. It continues in File Converter.")
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
    }
}
