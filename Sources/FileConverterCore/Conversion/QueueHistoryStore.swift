import Foundation

/// Finished conversions kept across launches (newest 200), so "Earlier" in
/// the queue still shows what was converted and where it went.
public enum QueueHistoryStore {
    public static let limit = 200

    struct Record: Codable, Equatable {
        let id: UUID
        let batchID: UUID
        let batchCreatedAt: Date
        let sourcePath: String
        let presetName: String
        let presetMenuName: String
        let category: FormatCategory
        let destinationFormat: String
        let outcome: Outcome
        let message: String?
        let outputPaths: [String]
        let startedAt: Date?
        let finishedAt: Date?

        enum Outcome: String, Codable {
            case completed, completedWithWarnings, failed, skipped, cancelled
        }
    }

    public static var defaultURL: URL? {
        AppDataLocation.directory?.appendingPathComponent("history.json")
    }

    static func record(for job: ConversionJob) -> Record? {
        let outcome: Record.Outcome
        var message: String?
        switch job.state {
        case .completed: outcome = .completed
        case .completedWithWarnings(let warnings):
            outcome = .completedWithWarnings
            message = warnings.joined(separator: "\n")
        case .failed(let error):
            outcome = .failed
            message = error.localizedDescription
        case .skipped(let reason):
            outcome = .skipped
            message = reason
        case .cancelled: outcome = .cancelled
        default: return nil
        }
        return Record(
            id: job.id,
            batchID: job.batchID,
            batchCreatedAt: job.batchCreatedAt,
            sourcePath: job.sourceURL.path,
            presetName: job.preset.name,
            presetMenuName: job.preset.menuName,
            category: job.preset.category,
            destinationFormat: job.preset.destinationFormat,
            outcome: outcome,
            message: message,
            outputPaths: job.outputURLs.map(\.path),
            startedAt: job.startedAt,
            finishedAt: job.finishedAt
        )
    }

    static func job(from record: Record) -> ConversionJob {
        let preset = ConversionPreset(
            name: record.presetName,
            menuName: record.presetMenuName,
            category: record.category,
            sourceFormats: [],
            destinationFormat: record.destinationFormat,
            isEnabled: false
        )
        let state: JobState
        switch record.outcome {
        case .completed: state = .completed
        case .completedWithWarnings: state = .completedWithWarnings((record.message ?? "").components(separatedBy: "\n").filter { !$0.isEmpty })
        case .failed: state = .failed(.unknown(message: record.message ?? "Conversion failed."))
        case .skipped: state = .skipped(record.message ?? "Skipped")
        case .cancelled: state = .cancelled
        }
        var job = ConversionJob(
            id: record.id,
            batchID: record.batchID,
            sourceURL: URL(fileURLWithPath: record.sourcePath),
            preset: preset,
            state: state,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            outputURLs: record.outputPaths.map { URL(fileURLWithPath: $0) },
            batchCreatedAt: record.batchCreatedAt
        )
        job.destinationURL = job.outputURLs.first
        job.isFromHistory = true
        return job
    }

    public static func save(_ jobs: [ConversionJob], to url: URL? = defaultURL) {
        guard let url else { return }
        let records = jobs.compactMap(record(for:)).suffix(limit)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Array(records)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            AppLogger.queue.error("Could not save queue history: \(error.localizedDescription, privacy: .public)")
        }
    }

    public static func load(from url: URL? = defaultURL) -> [ConversionJob] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([Record].self, from: data) else { return [] }
        return records.map(job(from:))
    }
}
