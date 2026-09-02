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
    @Published public private(set) var cancelledCount: Int = 0
    @Published public private(set) var overallProgress: Double = 0.0

    private var maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    private var activeJobIDs = Set<UUID>()
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var reservedOutputURLs = Set<URL>()
    private var isProcessing = false

    public init() {
        setupThermalMonitoring()
    }

    public func setMaxConcurrency(_ limit: Int) {
        maxConcurrency = max(1, limit)
        processNextJobs()
    }

    public func addJobs(_ newJobs: [ConversionJob]) {
        jobs.append(contentsOf: newJobs)
        updateCountsAndProgress()
        processNextJobs()
    }

    public func cancelJob(id: UUID) {
        var job: ConversionJob?
        var task: Task<Void, Never>?
        var leaseToRelease: SecurityScopedLease?

        if let index = jobs.firstIndex(where: { $0.id == id }) {
            guard !jobs[index].state.isTerminal, jobs[index].state != .finalizing else {
                return
            }
            jobs[index].state = .cancelled
            jobs[index].finishedAt = Date()
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
            if !jobs[i].state.isTerminal, jobs[i].state != .finalizing {
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
        tasks = Array(runningTasks.values)

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

        leasesToRelease.forEach { $0.release() }
        updateCountsAndProgress()
    }

    public func retryJob(id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }),
           jobs[index].state.isTerminal,
           !activeJobIDs.contains(id) {
            jobs[index].state = .queued
            jobs[index].progress = ConversionProgress()
            jobs[index].startedAt = nil
            jobs[index].finishedAt = nil
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

            // 3. Reserve a unique output path across concurrently running jobs.
            let (finalDestURL, tempOutputURL) = try await reserveOutput(
                for: job,
                customFolderURL: destinationAccessLease?.url
            )

            // Check destination disk space
            let targetDir = finalDestURL.deletingLastPathComponent()
            let availableSpace = FileAccessManager.shared.checkAvailableDiskSpace(at: targetDir)
            let srcSize = FileAccessManager.shared.fileSize(at: job.sourceURL)
            if srcSize > 0 && availableSpace < srcSize {
                throw ConversionError.insufficientDiskSpace(requiredBytes: srcSize, availableBytes: availableSpace)
            }

            job.destinationURL = finalDestURL
            job.temporaryOutputURL = tempOutputURL

            await updateJob(job, state: .converting)
            try Task.checkCancellation()

            // 4. Run conversion with progress reporting.
            try await backend.convert(job: job) { [weak self] progress in
                Task { @MainActor in
                    self?.updateJobProgress(id: jobID, progress: progress)
                }
            }
            try Task.checkCancellation()

            // 5. Finalize output without replacing files for non-overwrite policies.
            await updateJob(job, state: .finalizing)
            try Task.checkCancellation()
            let canCommit = await MainActor.run { self.canCommitOutput(for: jobID) }
            guard canCommit else {
                throw CancellationError()
            }
            if job.preset.overwritePolicy == .replaceIfNewer {
                try revalidateReplaceIfNewer(sourceURL: job.sourceURL, destinationURL: finalDestURL)
            }
            let allowsReplacement = job.preset.overwritePolicy == .overwrite
                || job.preset.overwritePolicy == .replaceIfNewer
            try OutputNamingEngine.finalizeConversionOutput(
                temporaryURL: tempOutputURL,
                finalDestinationURL: finalDestURL,
                overwrite: allowsReplacement
            )

            // 6. Preserve timestamps if requested
            if job.preset.preserveCreationDate {
                FileAccessManager.shared.preserveTimestamps(from: job.sourceURL, to: finalDestURL)
            }

            // 7. Mark completed
            await finishJob(id: jobID, state: .completed)

        } catch {
            // Clean up temporary output file
            if let tempURL = job.temporaryOutputURL {
                OutputNamingEngine.cleanupTemporaryFile(at: tempURL)
            }

            if error is CancellationError {
                await finishJob(id: jobID, state: .cancelled)
            } else if let convErr = error as? ConversionError {
                AppLogger.conversion.error("Job \(jobID) failed: \(convErr.localizedDescription)")
                if convErr == .cancelled {
                    await finishJob(id: jobID, state: .cancelled)
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

    private func reserveOutput(
        for job: ConversionJob,
        customFolderURL: URL?
    ) throws -> (URL, URL) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }),
              !jobs[index].state.isTerminal else {
            throw CancellationError()
        }

        let finalDestinationURL = try OutputNamingEngine.resolveFinalDestinationURL(
            sourceURL: job.sourceURL,
            preset: job.preset,
            reservedURLs: reservedOutputURLs,
            customFolderURL: customFolderURL
        )
        let temporaryURL = OutputNamingEngine.createTemporaryOutputURL(for: finalDestinationURL)
        reservedOutputURLs.insert(finalDestinationURL.standardizedFileURL)
        jobs[index].sourceURL = job.sourceURL
        jobs[index].sourceAccessLease = job.sourceAccessLease
        jobs[index].destinationURL = finalDestinationURL
        jobs[index].temporaryOutputURL = temporaryURL
        jobs[index].resolvedBackend = job.resolvedBackend
        return (finalDestinationURL, temporaryURL)
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
            if jobs[index].state == .completed {
                jobs[index].progress.fractionCompleted = 1.0
            }
            leaseToRelease = jobs[index].sourceAccessLease
            jobs[index].sourceAccessLease = nil
            if let destinationURL = jobs[index].destinationURL {
                reservedOutputURLs.remove(destinationURL.standardizedFileURL)
            }
        }
        runningTasks.removeValue(forKey: id)
        activeJobIDs.remove(id)
        let isAllDone = jobs.allSatisfy { $0.state.isTerminal } && activeJobIDs.isEmpty
        let totalCount = jobs.count
        let failed = jobs.filter { if case .failed = $0.state { return true }; return false }.count
        let completed = jobs.filter { $0.state == .completed }.count

        leaseToRelease?.release()
        updateCountsAndProgress()
        if isAllDone && totalCount > 0 {
            sendBatchCompletionNotification(total: totalCount, completed: completed, failed: failed)
        }

        processNextJobs()
    }

    private func updateCountsAndProgress() {
        let allJobs = jobs

        var active = 0
        var queued = 0
        var completed = 0
        var failed = 0
        var cancelled = 0
        var totalProgressSum: Double = 0.0

        for j in allJobs {
            switch j.state {
            case .queued:
                queued += 1
            case .preparing, .converting, .finalizing:
                active += 1
                totalProgressSum += j.progress.fractionCompleted
            case .completed:
                completed += 1
                totalProgressSum += 1.0
            case .failed:
                failed += 1
                totalProgressSum += j.progress.fractionCompleted
            case .cancelled:
                cancelled += 1
                totalProgressSum += j.progress.fractionCompleted
            }
        }

        self.activeCount = active
        self.queuedCount = queued
        self.completedCount = completed
        self.failedCount = failed
        self.cancelledCount = cancelled
        self.overallProgress = allJobs.isEmpty ? 0.0 : (totalProgressSum / Double(allJobs.count))
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
            Task { @MainActor in
                self?.processNextJobs()
            }
        }
    }

    private func sendBatchCompletionNotification(total: Int, completed: Int, failed: Int) {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Conversion Complete"

        if total == 1 {
            if completed == 1 {
                content.body = "File converted successfully."
            } else {
                content.body = "File conversion failed."
            }
        } else {
            if failed == 0 {
                content.body = "\(completed) files converted successfully."
            } else {
                content.body = "\(completed) converted, \(failed) failed."
            }
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}
