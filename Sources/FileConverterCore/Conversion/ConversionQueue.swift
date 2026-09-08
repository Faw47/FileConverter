import Foundation
import Combine
import UserNotifications

@MainActor
public final class ConversionQueue: ObservableObject {
    public static let shared = ConversionQueue()

    @Published public private(set) var jobs: [ConversionJob] = []
    @Published public private(set) var activeCount: Int = 0
    @Published public private(set) var queuedCount: Int = 0
    @Published public private(set) var completedCount: Int = 0
    @Published public private(set) var failedCount: Int = 0
    @Published public private(set) var skippedCount: Int = 0
    @Published public private(set) var cancelledCount: Int = 0
    @Published public private(set) var cancelableCount: Int = 0
    @Published public private(set) var overallProgress: Double = 0.0
    @Published public private(set) var pendingCollisions: [CollisionConflict] = []

    public struct CollisionConflict: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let jobID: UUID
        public let destinationURL: URL
        public let sourceFilename: String

        public init(jobID: UUID, destinationURL: URL, sourceFilename: String) {
            self.id = jobID
            self.jobID = jobID
            self.destinationURL = destinationURL
            self.sourceFilename = sourceFilename
        }
    }

    public enum CollisionDecision: Sendable {
        case replace
        case keepBoth
        case skip
    }

    private var maxConcurrency: Int
    private var activeJobIDs = Set<UUID>()
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var reservedOutputURLs = Set<URL>()
    private var isProcessing = false
    private var activeBatchID: UUID?
    private var pendingProgressUpdates: [UUID: ConversionProgress] = [:]
    private var progressCoalescerTask: Task<Void, Never>?
    private var notifiedBatchIDs = Set<UUID>()

    public init() {
        let stored = UserDefaults.standard.integer(forKey: "maxConcurrentJobs")
        self.maxConcurrency = (1...16).contains(stored) ? stored : max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        setupThermalMonitoring()
    }

    public var currentMaxConcurrency: Int { maxConcurrency }

    public var effectiveMaxConcurrency: Int { calculateEffectiveConcurrency() }

    public func setMaxConcurrency(_ limit: Int) {
        maxConcurrency = min(max(1, limit), 16)
        processNextJobs()
    }

    public func addJobs(_ newJobs: [ConversionJob]) {
        guard !newJobs.isEmpty else { return }
        let batchID = UUID()
        activeBatchID = batchID
        var batchJobs = newJobs
        for index in batchJobs.indices {
            batchJobs[index].batchID = batchID
        }
        jobs.append(contentsOf: batchJobs)
        updateCountsAndProgress()
        processNextJobs()
    }

    public func cancelJob(id: UUID) {
        var job: ConversionJob?
        var task: Task<Void, Never>?
        var leaseToRelease: SecurityScopedLease?

        if let index = jobs.firstIndex(where: { $0.id == id }) {
            guard jobs[index].state.isCancellable else {
                return
            }
            jobs[index].state = .cancelled
            jobs[index].finishedAt = Date()
            pendingCollisions.removeAll { $0.jobID == id }
            job = jobs[index]
            task = runningTasks[id]
            if task == nil {
                leaseToRelease = jobs[index].sourceAccessLease
                jobs[index].sourceAccessLease = nil
            }
        }

        leaseToRelease?.release()
        task?.cancel()
        if task != nil, let job {
            Task {
                await BackendResolver.shared.cancel(jobID: job.id, backendType: job.resolvedBackend)
            }
        }

        updateCountsAndProgress()
        if task == nil {
            processNextJobs()
        }
    }

    public func cancelAll() {
        var activeJobs: [ConversionJob] = []
        var tasks: [Task<Void, Never>] = []
        var leasesToRelease: [SecurityScopedLease] = []

        for i in 0..<jobs.count {
            if jobs[i].state.isCancellable {
                jobs[i].state = .cancelled
                jobs[i].finishedAt = Date()
                if activeJobIDs.contains(jobs[i].id) {
                    activeJobs.append(jobs[i])
                } else if let lease = jobs[i].sourceAccessLease {
                    jobs[i].sourceAccessLease = nil
                    leasesToRelease.append(lease)
                }
            }
        }
        let activeIDs = Set(activeJobs.map(\.id))
        tasks = activeIDs.compactMap { runningTasks[$0] }

        leasesToRelease.forEach { $0.release() }
        for task in tasks {
            task.cancel()
        }
        for job in activeJobs {
            Task {
                await BackendResolver.shared.cancel(jobID: job.id, backendType: job.resolvedBackend)
            }
        }

        updateCountsAndProgress()
    }

    public func clearCompleted() {
        var leasesToRelease: [SecurityScopedLease] = []
        leasesToRelease = jobs.compactMap { job in
            guard job.state.isTerminal, !activeJobIDs.contains(job.id) else { return nil }
            return job.sourceAccessLease
        }
        jobs.removeAll { $0.state.isTerminal && !activeJobIDs.contains($0.id) }
        notifiedBatchIDs.formIntersection(Set(jobs.map(\.batchID)))
        pendingCollisions.removeAll { conflict in
            !jobs.contains(where: { $0.id == conflict.jobID })
        }

        leasesToRelease.forEach { $0.release() }
        updateCountsAndProgress()
    }

    public func retryJob(id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }),
           jobs[index].state.isTerminal,
           !activeJobIDs.contains(id) {
            notifiedBatchIDs.remove(jobs[index].batchID)
            jobs[index].state = .queued
            jobs[index].progress = ConversionProgress()
            jobs[index].startedAt = nil
            jobs[index].finishedAt = nil
            jobs[index].destinationURL = nil
            jobs[index].temporaryOutputURL = nil
            jobs[index].resolvedBackend = nil
            jobs[index].plannedOutputs = []
            jobs[index].outputURLs = []
            jobs[index].warnings = []
        }

        updateCountsAndProgress()
        processNextJobs()
    }

    public func resolveCollisions(
        _ decision: CollisionDecision,
        applyToAll: Bool = false,
        jobIDs: Set<UUID>? = nil
    ) {
        let matchingTargets = pendingCollisions.filter { conflict in
            (jobIDs?.contains(conflict.jobID) ?? true)
        }
        let targets = applyToAll ? matchingTargets : Array(matchingTargets.prefix(1))
        var skippedJobIDs: [UUID] = []
        for conflict in targets {
            guard let index = jobs.firstIndex(where: { $0.id == conflict.jobID }) else { continue }
            switch decision {
            case .replace:
                jobs[index].preset.overwritePolicy = .overwrite
                jobs[index].state = .queued
                jobs[index].destinationURL = nil
                jobs[index].temporaryOutputURL = nil
                jobs[index].plannedOutputs = []
            case .keepBoth:
                jobs[index].preset.overwritePolicy = .appendNumber
                jobs[index].state = .queued
                jobs[index].destinationURL = nil
                jobs[index].temporaryOutputURL = nil
                jobs[index].plannedOutputs = []
            case .skip:
                skippedJobIDs.append(jobs[index].id)
            }
        }
        let targetIDs = Set(targets.map(\.jobID))
        pendingCollisions.removeAll { targetIDs.contains($0.jobID) }
        for jobID in skippedJobIDs {
            finishJob(id: jobID, state: .skipped("Output already exists"))
        }
        updateCountsAndProgress()
        processNextJobs()
    }

    // MARK: - Queue Execution Loop

    private func processNextJobs() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        let effectiveConcurrency = calculateEffectiveConcurrency()

        while activeJobIDs.count < effectiveConcurrency {
            guard let nextJobIndex = jobs.firstIndex(where: { $0.state == .queued }) else {
                break
            }

            var job = jobs[nextJobIndex]
            job.state = .preparing
            job.startedAt = Date()
            jobs[nextJobIndex] = job

            let jobID = job.id
            activeJobIDs.insert(jobID)

            let task = Task.detached(priority: .userInitiated) { [weak self, job] in
                guard let self = self else { return }
                await self.executeJob(job)
            }
            runningTasks[jobID] = task
        }

        updateCountsAndProgress()
    }

    nonisolated private func executeJob(_ initialJob: ConversionJob) async {
        var job = initialJob
        let jobID = job.id
        defer { job.sourceAccessLease?.release() }
        var destinationAccessLease: SecurityScopedLease?
        defer { destinationAccessLease?.release() }

        do {
            if job.sourceAccessLease == nil, let bookmarkData = job.sourceBookmarkData {
                let lease = try SecurityScopedLease(bookmarkData: bookmarkData)
                job.sourceURL = lease.url
                job.sourceAccessLease = lease
            }
            try Task.checkCancellation()

            // 1. Check source file validity
            guard FileManager.default.fileExists(atPath: job.sourceURL.path) else {
                throw ConversionError.fileNotFound(path: job.sourceURL.path)
            }

            // 2. Resolve the backend before creating destination directories or temporary files.
            let backend = try BackendResolver.shared.resolveBackend(for: job)
            job.resolvedBackend = backend.backendType

            if case .customFolder(let bookmarkData, _) = job.preset.outputDirectoryPolicy {
                destinationAccessLease = try SecurityScopedLease(bookmarkData: bookmarkData)
            }

            // 3. Determine and reserve every output path before conversion.
            let plannedOutputs = try await reserveOutputs(
                for: job,
                backend: backend,
                customFolderURL: destinationAccessLease?.url
            )

            guard let firstOutput = plannedOutputs.first else {
                throw ConversionError.destinationUnavailable(path: "")
            }
            let finalDestURL = firstOutput.finalURL
            let tempOutputURL = firstOutput.temporaryURL

            // Check destination disk space
            let targetDir = finalDestURL.deletingLastPathComponent()
            let availableSpace = FileAccessManager.shared.checkAvailableDiskSpace(at: targetDir)
            let requiredSpace = estimateRequiredDiskSpace(for: job, outputCount: plannedOutputs.count)
            if requiredSpace > 0 && availableSpace < requiredSpace {
                throw ConversionError.insufficientDiskSpace(requiredBytes: requiredSpace, availableBytes: availableSpace)
            }

            job.destinationURL = finalDestURL
            job.temporaryOutputURL = tempOutputURL
            job.plannedOutputs = plannedOutputs
            job.outputURLs = plannedOutputs.map(\.finalURL)

            await updateJob(job, state: .converting)
            try Task.checkCancellation()

            // 4. Run conversion with progress reporting.
            let result = try await backend.convert(job: job, outputs: plannedOutputs) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.enqueueProgressUpdate(id: jobID, progress: progress)
                }
            }
            var warnings = result.warnings
            job.warnings = warnings
            try Task.checkCancellation()

            // 5. Finalize output without replacing files for non-overwrite policies.
            await updateJob(job, state: .finalizing)
            try Task.checkCancellation()
            let canCommit = await MainActor.run { self.canCommitOutput(for: jobID) }
            guard canCommit else {
                throw CancellationError()
            }
            if job.preset.overwritePolicy == .replaceIfNewer {
                for output in plannedOutputs {
                    try revalidateReplaceIfNewer(sourceURL: job.sourceURL, destinationURL: output.finalURL)
                }
            }
            let allowsReplacement = job.preset.overwritePolicy == .overwrite
                || job.preset.overwritePolicy == .replaceIfNewer
            try OutputNamingEngine.finalizeConversionOutputs(
                plannedOutputs,
                overwrite: allowsReplacement
            )

            // 6. Preserve timestamps if requested. Metadata failures should not
            // discard an otherwise valid output; make them visible as warnings.
            if job.preset.preserveCreationDate {
                for output in plannedOutputs {
                    do {
                        try FileAccessManager.shared.preserveTimestamps(from: job.sourceURL, to: output.finalURL)
                    } catch {
                        warnings.append("Could not preserve timestamps for \(output.finalURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            job.warnings = warnings
            await updateJob(job, state: .finalizing)

            // 7. Mark completed
            await finishJob(id: jobID, state: warnings.isEmpty ? .completed : .completedWithWarnings(warnings))

        } catch {
            // Clean up temporary output file
            for output in job.plannedOutputs {
                OutputNamingEngine.cleanupTemporaryFile(at: output.temporaryURL)
            }
            if job.plannedOutputs.isEmpty, let tempURL = job.temporaryOutputURL {
                OutputNamingEngine.cleanupTemporaryFile(at: tempURL)
            }

            if error is CancellationError {
                await finishJob(id: jobID, state: .cancelled)
            } else if let convErr = error as? ConversionError {
                AppLogger.conversion.error("Job \(jobID) failed: \(convErr.localizedDescription)")
                if convErr == .cancelled {
                    await finishJob(id: jobID, state: .cancelled)
                } else if case .outputCollision(let path) = convErr, job.preset.overwritePolicy == .ask {
                    await markAwaitingCollision(jobID: jobID, destinationPath: path)
                } else if case .outputCollision = convErr, job.preset.overwritePolicy == .skip {
                    await finishJob(id: jobID, state: .skipped("Output already exists"))
                } else {
                    await finishJob(id: jobID, state: .failed(convErr))
                }
            } else {
                let convErr = ConversionError.unknown(message: error.localizedDescription)
                AppLogger.conversion.error("Job \(jobID) failed: \(error.localizedDescription)")
                await finishJob(id: jobID, state: .failed(convErr))
            }
        }
    }

    private func reserveOutputs(
        for job: ConversionJob,
        backend: any ConversionBackend,
        customFolderURL: URL?
    ) async throws -> [PlannedConversionOutput] {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }),
              !jobs[index].state.isTerminal else {
            throw CancellationError()
        }

        let requirements = try await backend.outputRequirements(for: job)
        var outputs: [PlannedConversionOutput] = []
        var localReservations = reservedOutputURLs
        for requirement in requirements {
            let finalDestinationURL = try OutputNamingEngine.resolveFinalDestinationURL(
                sourceURL: job.sourceURL,
                preset: job.preset,
                targetExtension: requirement.extensionName,
                suffix: requirement.suffix,
                reservedURLs: localReservations,
                customFolderURL: customFolderURL
            )
            let temporaryURL = OutputNamingEngine.createTemporaryOutputURL(for: finalDestinationURL)
            localReservations.insert(finalDestinationURL.standardizedFileURL)
            outputs.append(PlannedConversionOutput(finalURL: finalDestinationURL, temporaryURL: temporaryURL))
        }
        reservedOutputURLs = localReservations
        guard let first = outputs.first else { throw ConversionError.destinationUnavailable(path: "") }
        jobs[index].sourceURL = job.sourceURL
        jobs[index].sourceAccessLease = job.sourceAccessLease
        jobs[index].destinationURL = first.finalURL
        jobs[index].temporaryOutputURL = first.temporaryURL
        jobs[index].plannedOutputs = outputs
        jobs[index].outputURLs = outputs.map(\.finalURL)
        jobs[index].resolvedBackend = job.resolvedBackend
        return outputs
    }

    private func updateJob(_ job: ConversionJob, state: JobState) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            guard !jobs[index].state.isTerminal else { return }
            jobs[index].state = state
            jobs[index].sourceURL = job.sourceURL
            jobs[index].sourceAccessLease = job.sourceAccessLease
            jobs[index].destinationURL = job.destinationURL
            jobs[index].temporaryOutputURL = job.temporaryOutputURL
            jobs[index].resolvedBackend = job.resolvedBackend
            jobs[index].plannedOutputs = job.plannedOutputs
            jobs[index].outputURLs = job.outputURLs
            jobs[index].warnings = job.warnings
        }
        updateCountsAndProgress()
    }

    private func updateJobProgress(id: UUID, progress: ConversionProgress) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if !jobs[index].state.isTerminal {
                jobs[index].progress = progress
            }
        }
        updateCountsAndProgress()
    }

    private func enqueueProgressUpdate(id: UUID, progress: ConversionProgress) {
        pendingProgressUpdates[id] = progress
        guard progressCoalescerTask == nil else { return }
        progressCoalescerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            let updates = self.pendingProgressUpdates
            self.pendingProgressUpdates.removeAll()
            self.progressCoalescerTask = nil
            for (id, progress) in updates {
                self.updateJobProgress(id: id, progress: progress)
            }
        }
    }

    private func canCommitOutput(for id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        return !jobs[index].state.isTerminal
    }

    nonisolated private func revalidateReplaceIfNewer(sourceURL: URL, destinationURL: URL) throws {
        guard FileManager.default.fileExists(atPath: destinationURL.path) else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw ConversionError.destinationUnavailable(path: destinationURL.path)
        }
        guard let srcAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let srcDate = srcAttrs[.modificationDate] as? Date,
              let dstAttrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let dstDate = dstAttrs[.modificationDate] as? Date else {
            throw ConversionError.outputCollision(path: destinationURL.path)
        }
        if srcDate <= dstDate {
            throw ConversionError.outputCollision(path: destinationURL.path)
        }
    }

    private func finishJob(id: UUID, state: JobState) {
        var leaseToRelease: SecurityScopedLease?
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            if !jobs[index].state.isTerminal {
                jobs[index].state = state
            }
            jobs[index].finishedAt = Date()
            if jobs[index].state.isTerminal {
                jobs[index].progress.fractionCompleted = 1.0
            }
            leaseToRelease = jobs[index].sourceAccessLease
            jobs[index].sourceAccessLease = nil
            for output in jobs[index].plannedOutputs {
                reservedOutputURLs.remove(output.finalURL.standardizedFileURL)
            }
            if let destinationURL = jobs[index].destinationURL {
                reservedOutputURLs.remove(destinationURL.standardizedFileURL)
            }
        }
        runningTasks.removeValue(forKey: id)
        activeJobIDs.remove(id)
        let batchID = jobs.first(where: { $0.id == id })?.batchID ?? activeBatchID
        let batchJobs = jobs.filter { $0.batchID == batchID }
        let isAllDone = !batchJobs.isEmpty && batchJobs.allSatisfy { $0.state.isTerminal }
        let totalCount = batchJobs.count
        let failed = batchJobs.filter { if case .failed = $0.state { return true }; return false }.count
        let completed = batchJobs.filter { $0.state == .completed || ifCaseCompletedWithWarnings($0.state) }.count
        let skippedOrCancelled = totalCount - completed - failed
        let shouldNotify: Bool
        if isAllDone, let batchID {
            shouldNotify = notifiedBatchIDs.insert(batchID).inserted
        } else {
            shouldNotify = false
        }

        leaseToRelease?.release()
        updateCountsAndProgress()
        if shouldNotify && totalCount > 0 {
            let completedURLs = batchJobs.flatMap { job -> [URL] in
                guard job.state == .completed || ifCaseCompletedWithWarnings(job.state) else { return [] }
                return job.outputURLs.isEmpty ? (job.destinationURL.map { [$0] } ?? []) : job.outputURLs
            }
            sendBatchCompletionNotification(
                total: totalCount,
                completed: completed,
                failed: failed,
                skippedOrCancelled: skippedOrCancelled,
                destinationURLs: completedURLs
            )
        }

        processNextJobs()
    }

    private func updateCountsAndProgress() {
        let currentJobs = jobs

        var active = 0
        var queued = 0
        var completed = 0
        var failed = 0
        var skipped = 0
        var cancelled = 0
        var cancelable = 0
        for j in currentJobs {
            if j.state.isCancellable {
                cancelable += 1
            }
            switch j.state {
            case .queued:
                queued += 1
            case .preparing, .converting, .finalizing:
                active += 1
            case .awaitingCollision:
                queued += 1
            case .completed:
                completed += 1
            case .completedWithWarnings:
                completed += 1
            case .failed:
                failed += 1
            case .skipped:
                skipped += 1
            case .cancelled:
                cancelled += 1
            }
        }

        self.activeCount = active
        self.queuedCount = queued
        self.completedCount = completed
        self.failedCount = failed
        self.skippedCount = skipped
        self.cancelledCount = cancelled
        self.cancelableCount = cancelable
        self.overallProgress = currentJobs.isEmpty ? 0.0 : (currentJobs.reduce(0) { $0 + ($1.state.isTerminal ? 1 : $1.progress.fractionCompleted) } / Double(currentJobs.count))
    }

    private func markAwaitingCollision(jobID: UUID, destinationPath: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let leaseToRelease = jobs[index].sourceAccessLease
        jobs[index].sourceAccessLease = nil
        for output in jobs[index].plannedOutputs {
            reservedOutputURLs.remove(output.finalURL.standardizedFileURL)
        }
        jobs[index].state = .awaitingCollision
        jobs[index].finishedAt = nil
        let conflict = CollisionConflict(
            jobID: jobID,
            destinationURL: URL(fileURLWithPath: destinationPath),
            sourceFilename: jobs[index].filename
        )
        if !pendingCollisions.contains(where: { $0.jobID == jobID }) {
            pendingCollisions.append(conflict)
        }
        runningTasks.removeValue(forKey: jobID)
        activeJobIDs.remove(jobID)
        leaseToRelease?.release()
        updateCountsAndProgress()
        processNextJobs()
    }

    nonisolated private func estimateRequiredDiskSpace(for job: ConversionJob, outputCount: Int) -> Int64 {
        let sourceSize = FileAccessManager.shared.fileSize(at: job.sourceURL)
        // A conversion backend may not know duration until it probes the file;
        // reserve a conservative multiple up front and refine this in future
        // backend-specific preflight implementations.
        let multiplier = Double(max(1, outputCount)) * 1.2
        if sourceSize > 0, job.preset.quality == .lossless {
            return Int64(Double(sourceSize) * 2 * multiplier)
        }
        return max(sourceSize * 4, 512 * 1024 * 1024)
    }

    private func ifCaseCompletedWithWarnings(_ state: JobState) -> Bool {
        if case .completedWithWarnings = state { return true }
        return false
    }

    private func calculateEffectiveConcurrency() -> Int {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            return 1
        }
        return maxConcurrency
    }

    private func setupThermalMonitoring() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppLogger.conversion.info("Thermal state changed to: \(ProcessInfo.processInfo.thermalState.rawValue)")
            Task { @MainActor [weak self] in
                self?.processNextJobs()
            }
        }
    }

    private func sendBatchCompletionNotification(
        total: Int,
        completed: Int,
        failed: Int,
        skippedOrCancelled: Int,
        destinationURLs: [URL] = []
    ) {
        if !destinationURLs.isEmpty {
            NotificationCenter.default.post(
                name: .fileConverterBatchCompleted,
                object: nil,
                userInfo: ["destinationURLs": destinationURLs]
            )
        }

        let enabled = UserDefaults.standard.object(forKey: "enableNotifications") as? Bool ?? false
        guard enabled else { return }
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Conversion Finished"

        if total == 1 {
            if completed == 1 {
                content.body = "File converted successfully."
            } else if failed == 1 {
                content.body = "File conversion failed."
            } else {
                content.body = "File conversion was skipped or cancelled."
            }
        } else {
            if failed == 0 && skippedOrCancelled == 0 {
                content.body = "\(completed) files converted successfully."
            } else {
                var outcomes = ["\(completed) converted"]
                if failed > 0 { outcomes.append("\(failed) failed") }
                if skippedOrCancelled > 0 { outcomes.append("\(skippedOrCancelled) skipped or cancelled") }
                content.body = outcomes.joined(separator: ", ") + "."
            }
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}

public extension Notification.Name {
    static let fileConverterBatchCompleted = Notification.Name("io.fileconverter.batchCompleted")
}
