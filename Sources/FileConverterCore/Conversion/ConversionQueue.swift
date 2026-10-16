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
    /// Lifecycle completion: terminal jobs / total. Reaches 1.0 even when
    /// jobs fail, skip, or cancel.
    @Published public private(set) var completionProgress: Double = 0.0
    /// While paused, running jobs finish but no waiting job starts.
    @Published public private(set) var isPaused = false
    /// Success fraction: completed jobs / total.
    @Published public private(set) var successFraction: Double = 0.0
    @Published public private(set) var pendingCollisions: [CollisionConflict] = []

    public struct CollisionConflict: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let jobID: UUID
        public let destinationURL: URL
        /// Every conflicting output for a multi-output job, captured before
        /// presenting the decision.
        public let conflictingURLs: [URL]
        public let destinationFingerprints: [URL: DestinationFingerprint]
        public let sourceFilename: String

        public init(
            jobID: UUID,
            destinationURL: URL,
            sourceFilename: String,
            conflictingURLs: [URL]? = nil,
            destinationFingerprints: [URL: DestinationFingerprint]? = nil
        ) {
            self.id = jobID
            self.jobID = jobID
            self.destinationURL = destinationURL
            let conflicts = conflictingURLs ?? [destinationURL]
            self.conflictingURLs = conflicts
            self.destinationFingerprints = destinationFingerprints ?? Dictionary(
                uniqueKeysWithValues: conflicts.map { ($0, DestinationFingerprint(url: $0)) }
            )
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
    /// Ownership-aware reservations: destination URL -> owning job ID.
    /// An active job's reservation is held until its task actually stops.
    private var reservedOutputURLs: [URL: UUID] = [:]
    private var reservedOutputURLSet: Set<URL> {
        Set(reservedOutputURLs.keys)
    }
    private var isProcessing = false
    private var pendingProgressUpdates: [UUID: ConversionProgress] = [:]
    private var progressCoalescerTask: Task<Void, Never>?
    private var notifiedBatchIDs = Set<UUID>()

    public init() {
        let stored = ConversionDefaults.store.integer(forKey: "maxConcurrentJobs")
        self.maxConcurrency = (1...16).contains(stored) ? stored : max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        setupThermalMonitoring()
    }

    public var currentMaxConcurrency: Int { maxConcurrency }

    public var effectiveMaxConcurrency: Int { calculateEffectiveConcurrency() }

    public func setMaxConcurrency(_ limit: Int) {
        maxConcurrency = min(max(1, limit), 16)
        processNextJobs()
    }

    /// Batches started by split Finder requests, keyed by request group.
    private var groupedBatches: [UUID: (batchID: UUID, batchDate: Date)] = [:]
    static let groupMergeWindow: TimeInterval = 5

    public func addJobs(_ newJobs: [ConversionJob], groupID: UUID? = nil) {
        guard !newJobs.isEmpty else { return }
        // Batch identity is immutable through completion: each submitted batch
        // gets its own ID, except chunks of one Finder selection that arrive
        // together (same group, within a few seconds).
        let now = Date()
        groupedBatches = groupedBatches.filter { now.timeIntervalSince($0.value.batchDate) < Self.groupMergeWindow }
        let batchID: UUID
        let batchDate: Date
        if let groupID, let existing = groupedBatches[groupID] {
            batchID = existing.batchID
            batchDate = existing.batchDate
        } else {
            batchID = UUID()
            batchDate = now
            if let groupID {
                groupedBatches[groupID] = (batchID, batchDate)
            }
        }
        var batchJobs = newJobs
        for index in batchJobs.indices {
            batchJobs[index].batchID = batchID
            batchJobs[index].batchCreatedAt = batchDate
            ConversionJournal.shared.recordAdmission(
                jobID: batchJobs[index].id,
                requestID: batchID,
                sourceURL: batchJobs[index].sourceURL,
                bookmarkData: batchJobs[index].sourceBookmarkData,
                presetID: batchJobs[index].preset.id,
                presetName: batchJobs[index].preset.name
            )
        }
        jobs.append(contentsOf: batchJobs)
        updateCountsAndProgress()
        processNextJobs()
    }

    /// Records a Finder request that was refused before any job started, as
    /// failed rows in their own batch, so the refusal is visible in the queue
    /// even when notifications are off.
    public func recordRejectedRequest(
        sources: [(displayName: String, path: String)],
        preset: ConversionPreset?,
        reason: String
    ) {
        guard !sources.isEmpty else { return }
        let placeholder = preset ?? ConversionPreset(
            name: "Unavailable preset",
            category: .custom,
            sourceFormats: [],
            destinationFormat: "",
            isEnabled: false
        )
        let batchID = UUID()
        let now = Date()
        let rows = sources.map { source -> ConversionJob in
            var job = ConversionJob(
                batchID: batchID,
                sourceURL: URL(fileURLWithPath: source.path),
                preset: placeholder,
                state: .failed(.admissionRejected(reason: reason))
            )
            job.finishedAt = now
            job.batchCreatedAt = now
            return job
        }
        jobs.append(contentsOf: rows)
        updateCountsAndProgress()
        saveHistory()
        postUserNotification(
            title: rows.count == 1 ? "Could Not Convert \(sources[0].displayName)" : "Could Not Convert \(rows.count) Files",
            body: reason
        )
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

        if task == nil {
            releaseReservations(for: id)
            // A waiting job never runs, so close its journal entry here or
            // the next launch reports it as interrupted.
            if job != nil {
                ConversionJournal.shared.transitionState(jobID: id, to: .cancelled)
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
        var cancelledIDs: [UUID] = []

        for i in 0..<jobs.count {
            if jobs[i].state.isCancellable {
                cancelledIDs.append(jobs[i].id)
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

        for job in jobs where job.state == .cancelled && !activeIDs.contains(job.id) {
            releaseReservations(for: job.id)
        }

        leasesToRelease.forEach { $0.release() }
        saveHistory()
        // Waiting jobs too, or the next launch reports them as interrupted.
        ConversionJournal.shared.transitionStates(jobIDs: cancelledIDs, to: .cancelled)
        for task in tasks {
            task.cancel()
        }
        for job in activeJobs {
            Task {
                await BackendResolver.shared.cancel(jobID: job.id, backendType: job.resolvedBackend)
            }
        }

        pendingCollisions.removeAll()
        updateCountsAndProgress()
    }

    /// Cancels all running jobs and waits up to `timeout` seconds for their background tasks to exit.
    public func cancelAllAndWait(timeout: TimeInterval = 3.0) async {
        cancelAll()
        let start = Date()
        while !activeJobIDs.isEmpty && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    public func clearCompleted() {
        var leasesToRelease: [SecurityScopedLease] = []
        leasesToRelease = jobs.compactMap { job in
            guard job.state.isTerminal, !activeJobIDs.contains(job.id) else { return nil }
            return job.sourceAccessLease
        }
        let clearableIDs = Set(jobs.filter { $0.state.isTerminal && !activeJobIDs.contains($0.id) }.map(\.id))
        for id in clearableIDs {
            releaseReservations(for: id)
        }
        jobs.removeAll { $0.state.isTerminal && !activeJobIDs.contains($0.id) }
        notifiedBatchIDs.formIntersection(Set(jobs.map(\.batchID)))
        pendingCollisions.removeAll { conflict in
            !jobs.contains(where: { $0.id == conflict.jobID })
        }

        leasesToRelease.forEach { $0.release() }
        saveHistory()
        updateCountsAndProgress()
    }

    public var hasClearableJobs: Bool {
        completedCount > 0 || failedCount > 0 || cancelledCount > 0 || skippedCount > 0
    }

    public func removeJob(id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // Never remove an active job while its backend task remains alive;
        // cancel first and leave the terminal job for clearCompleted.
        if activeJobIDs.contains(id) || runningTasks[id] != nil {
            cancelJob(id: id)
            return
        }
        let leaseToRelease = jobs[index].sourceAccessLease
        jobs[index].sourceAccessLease = nil
        releaseReservations(for: id)
        jobs.remove(at: index)
        pendingCollisions.removeAll { $0.jobID == id }
        leaseToRelease?.release()
        updateCountsAndProgress()
        saveHistory()
    }

    public func setJobsForTesting(_ newJobs: [ConversionJob]) {
        self.jobs = newJobs
        updateCountsAndProgress()
    }

    public func injectCollisionForTesting(jobID: UUID, destination: URL, filename: String) {
        let conflict = CollisionConflict(jobID: jobID, destinationURL: destination, sourceFilename: filename)
        if !pendingCollisions.contains(where: { $0.jobID == jobID }) {
            pendingCollisions.append(conflict)
        }
    }

    func markAwaitingCollisionForTesting(jobID: UUID, destination: URL) {
        markAwaitingCollision(jobID: jobID, destinationPath: destination.path)
    }

    func setReservationForTesting(url: URL, jobID: UUID) {
        reservedOutputURLs[FileAccessManager.shared.reservationKey(for: url)] = jobID
    }

    var reservedOutputURLsForTesting: Set<URL> {
        Set(reservedOutputURLs.keys)
    }

    public func retryJob(id: UUID) {
        retryJobs(ids: [id])
    }

    /// Queues finished jobs again. Jobs from an earlier launch start one new
    /// batch together, after everything else, so they get their own progress,
    /// notification, and `{date}`; history rows without a stored preset and
    /// history rows that converted are left alone.
    public func retryJobs(ids: [UUID]) {
        let requested = Set(ids)
        let historyBatchID = UUID()
        let historyBatchDate = Date()
        var revivedFromHistory = Set<UUID>()

        for index in jobs.indices where requested.contains(jobs[index].id) {
            guard jobs[index].state.isTerminal, !activeJobIDs.contains(jobs[index].id) else { continue }
            if jobs[index].isFromHistory {
                guard jobs[index].canConvertAgain else { continue }
                jobs[index].isFromHistory = false
                jobs[index].batchID = historyBatchID
                jobs[index].batchCreatedAt = historyBatchDate
                revivedFromHistory.insert(jobs[index].id)
            }
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
            // Retry uses the original preset policy unless the user chooses a
            // new policy: clear the per-attempt collision override.
            jobs[index].collisionOverride = nil
            jobs[index].collisionPlan = nil
            jobs[index].resolvedSettings = nil
            jobs[index].waitingForDestinationKey = nil
            jobs[index].sourceAccessLease?.release()
            jobs[index].sourceAccessLease = nil
            jobs[index].conflictingOutputURLs = []
        }

        if !revivedFromHistory.isEmpty {
            let revived = jobs.filter { revivedFromHistory.contains($0.id) }
            jobs.removeAll { revivedFromHistory.contains($0.id) }
            jobs.append(contentsOf: revived)
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
        // A decision applies only to the conflicts the user acted on: one
        // row (explicit job IDs) or every listed conflict (apply to all).
        guard applyToAll || jobIDs != nil else {
            AppLogger.queue.error("Ignored a collision decision with no target: pass job IDs or applyToAll.")
            return
        }
        let targets = matchingTargets
        var skippedJobIDs: [UUID] = []
        for conflict in targets {
            guard let index = jobs.firstIndex(where: { $0.id == conflict.jobID }),
                  jobs[index].state != .cancelled else { continue }
            // Store the decision separately from ConversionPreset so the
            // original preset policy survives retry. Apply deterministically
            // to the full captured conflict set for multi-output jobs.
            switch decision {
            case .replace:
                var plan = CollisionResolutionPlan()
                for url in conflict.conflictingURLs {
                    let fingerprint = conflict.destinationFingerprints[url] ?? DestinationFingerprint(url: url)
                    plan.setDecision(.replace(approvedFingerprint: fingerprint), for: CanonicalDestinationKey(url: url))
                }
                jobs[index].collisionPlan = plan
                jobs[index].collisionOverride = .overwrite
                jobs[index].sourceAccessLease?.release()
                jobs[index].sourceAccessLease = nil
                jobs[index].state = .queued
                jobs[index].destinationURL = nil
                jobs[index].temporaryOutputURL = nil
                jobs[index].plannedOutputs = []
                jobs[index].outputURLs = []
                jobs[index].conflictingOutputURLs = []
            case .keepBoth:
                var plan = CollisionResolutionPlan()
                for url in conflict.conflictingURLs {
                    plan.setDecision(.keepBoth, for: CanonicalDestinationKey(url: url))
                }
                jobs[index].collisionPlan = plan
                jobs[index].collisionOverride = .appendNumber
                jobs[index].sourceAccessLease?.release()
                jobs[index].sourceAccessLease = nil
                jobs[index].state = .queued
                jobs[index].destinationURL = nil
                jobs[index].temporaryOutputURL = nil
                jobs[index].plannedOutputs = []
                jobs[index].outputURLs = []
                jobs[index].conflictingOutputURLs = []
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

    /// Progress of the batches that still have work: files left and overall
    /// fraction (0…1). Nil when nothing is waiting or converting.
    public nonisolated static func activeBatchProgress(_ jobs: [ConversionJob]) -> (remaining: Int, fraction: Double)? {
        let activeBatches = Set(jobs.filter { !$0.state.isTerminal }.map(\.batchID))
        guard !activeBatches.isEmpty else { return nil }
        let batchJobs = jobs.filter { activeBatches.contains($0.batchID) }
        let remaining = batchJobs.filter { !$0.state.isTerminal }.count
        let done = batchJobs.reduce(0.0) { sum, job in
            if job.state.isTerminal { return sum + 1 }
            return sum + max(0, min(1, job.progress.fractionCompleted))
        }
        return (remaining, done / Double(batchJobs.count))
    }

    // MARK: - History

    /// Where finished jobs are kept between launches; nil disables saving
    /// (tests, previews).
    public var historyURL: URL?

    /// Shows finished jobs from earlier launches, older than anything new.
    public func restoreHistory(from url: URL? = QueueHistoryStore.defaultURL) {
        historyURL = url
        let restored = QueueHistoryStore.load(from: url).filter { old in !jobs.contains { $0.id == old.id } }
        jobs.insert(contentsOf: restored, at: 0)
        updateCountsAndProgress()
    }

    private func saveHistory() {
        guard let historyURL else { return }
        QueueHistoryStore.save(jobs.filter(\.state.isTerminal), to: historyURL)
    }

    // MARK: - Order

    /// Moves a waiting job so it starts before `beforeID` (or last when nil).
    public func moveQueuedJob(id: UUID, before beforeID: UUID?) {
        guard id != beforeID,
              let from = jobs.firstIndex(where: { $0.id == id }),
              jobs[from].state == .queued else { return }
        let job = jobs.remove(at: from)
        if let beforeID, let to = jobs.firstIndex(where: { $0.id == beforeID }) {
            jobs.insert(job, at: to)
        } else {
            jobs.append(job)
        }
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
        processNextJobs()
    }

    private func processNextJobs() {
        guard !isPaused else {
            updateCountsAndProgress()
            return
        }
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        let effectiveConcurrency = calculateEffectiveConcurrency()

        while activeJobIDs.count < effectiveConcurrency {
            guard let nextJobIndex = jobs.firstIndex(where: {
                $0.state == .queued && !isWaitingForReservedDestination($0)
            }) else {
                break
            }

            var job = jobs[nextJobIndex]
            job.waitingForDestinationKey = nil
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
        // Capture the immutable batch ID for completion routing; never fall
        // back to a newer active batch.
        let capturedBatchID = job.batchID
        ConversionJournal.shared.transitionState(jobID: jobID, to: .running)
        defer { job.sourceAccessLease?.release() }
        var destinationAccessLease: SecurityScopedLease?
        defer { destinationAccessLease?.release() }

        do {
            if job.sourceAccessLease == nil, let bookmarkData = job.sourceBookmarkData {
                do {
                    let lease = try SecurityScopedLease(bookmarkData: bookmarkData)
                    job.sourceURL = lease.url
                    job.sourceAccessLease = lease
                } catch {
                    throw ConversionError.sandboxAccessFailure(path: job.sourceURL.path)
                }
            }
            try Task.checkCancellation()

            // 1. Check source file validity and access using the same boundary
            // as PresetValidator. Existence and readability are distinct:
            // a missing source is not a permission failure, and a present
            // source that cannot be opened is not a format mismatch.
            let sourceAccess = FormatDetector.detect(url: job.sourceURL)
            guard sourceAccess.exists else {
                throw ConversionError.fileNotFound(path: job.sourceURL.path)
            }
            guard sourceAccess.isReadable else {
                throw ConversionError.sandboxAccessFailure(path: job.sourceURL.path)
            }
            guard !sourceAccess.isDirectory else {
                if sourceAccess.isPackage {
                    throw ConversionError.unsupportedInputFormat(path: job.sourceURL.path, detectedType: "Package")
                }
                throw ConversionError.unsupportedInputFormat(path: job.sourceURL.path, detectedType: "Directory")
            }
            guard !sourceAccess.isZeroByte else {
                throw ConversionError.malformedSource(path: job.sourceURL.path, reason: "File is zero bytes.")
            }

            // Optional tools may still be under discovery right after launch;
            // wait for it so the right engine is chosen.
            if !ConversionCoordinator.isGuaranteedNative(job.preset), !BackendReadinessGate.shared.ready {
                _ = await BackendReadinessGate.shared.waitUntilReady(timeout: .seconds(30))
                try Task.checkCancellation()
            }

            // 2. Resolve the backend before creating destination directories or temporary files.
            let backend = try BackendResolver.shared.resolveBackend(for: job)
            job.resolvedBackend = backend.backendType

            // Resolve General settings and preset values once for this
            // attempt; everything below uses only the resolved values.
            let settings = EffectivePresetResolver.resolve(
                preset: job.preset,
                defaults: ConversionDefaults.current,
                collisionOverride: job.collisionOverride
            )
            job.resolvedSettings = settings
            await storeResolvedSettings(settings, for: jobID)

            if case .customFolder(let bookmarkData, let displayPath) = settings.outputDirectoryPolicy.value {
                guard !bookmarkData.isEmpty else {
                    throw ConversionError.sandboxAccessFailure(path: displayPath.isEmpty ? job.sourceURL.path : displayPath)
                }
                do {
                    destinationAccessLease = try SecurityScopedLease(bookmarkData: bookmarkData)
                } catch {
                    throw ConversionError.sandboxAccessFailure(path: displayPath.isEmpty ? job.sourceURL.path : displayPath)
                }
            }

            let effectivePolicy = settings.overwritePolicy.value
            var effectiveJob = job
            effectiveJob.preset = settings.applied(to: job.preset)

            // 3. Determine and reserve every output path before conversion.
            let plannedOutputs = try await reserveOutputs(
                for: effectiveJob,
                backend: backend,
                customFolderURL: destinationAccessLease?.url
            )

            guard let firstOutput = plannedOutputs.first else {
                throw ConversionError.destinationUnavailable(path: "")
            }
            let finalDestURL = firstOutput.finalURL
            let tempOutputURL = firstOutput.temporaryURL

            // Same-file guard before creating temporary output.
            for output in plannedOutputs {
                if FileAccessManager.shared.urlsReferToSameFile(job.sourceURL, output.finalURL) {
                    throw ConversionError.destinationUnavailable(path: output.finalURL.path)
                }
            }

            // Check destination disk space with explicit unknown handling.
            let targetDir = finalDestURL.deletingLastPathComponent()
            let diskState = FileAccessManager.shared.diskSpaceState(at: targetDir)
            let sourceFormat = FormatDetector.detect(url: job.sourceURL).format
            let measurements = await OutputSizeEstimator.measure(
                job.sourceURL,
                category: sourceFormat?.category,
                formatID: sourceFormat?.id
            )
            let requiredSpace = OutputSizeEstimator.estimate(
                preset: job.preset,
                destination: FormatRegistry.shared.format(forID: job.preset.destinationFormat),
                source: measurements,
                outputCount: plannedOutputs.count
            )
            var diskWarning: String?
            switch diskState {
            case .available(let bytes):
                if requiredSpace > 0 && bytes < requiredSpace {
                    throw ConversionError.insufficientDiskSpace(requiredBytes: requiredSpace, availableBytes: bytes)
                }
                if requiredSpace > 0 && bytes < requiredSpace * 2 {
                    let free = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    diskWarning = "Only \(free) is free on the destination disk; this conversion needed most of it."
                }
            case .unavailable:
                diskWarning = "Available disk space could not be confirmed for \(targetDir.lastPathComponent); conversion will proceed but may fail if the volume is full."
            case .queryFailed:
                diskWarning = "Available disk space is unknown for \(targetDir.lastPathComponent); conversion will proceed without a capacity guarantee."
            }

            job.destinationURL = finalDestURL
            job.temporaryOutputURL = tempOutputURL
            job.plannedOutputs = plannedOutputs
            job.outputURLs = plannedOutputs.map(\.finalURL)

            await updateJob(job, state: .converting)
            try Task.checkCancellation()

            // 4. Run conversion with progress reporting.
            let result = try await backend.convert(job: effectiveJobWithOutputs(job: effectiveJob, outputs: plannedOutputs), outputs: plannedOutputs) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.enqueueProgressUpdate(id: jobID, progress: progress)
                }
            }
            var warnings = result.warnings
            if let diskWarning { warnings.append(diskWarning) }
            job.warnings = warnings
            try Task.checkCancellation()

            // Verify every planned temporary output exists and satisfies the
            // backend contract before commit.
            for output in plannedOutputs {
                guard FileManager.default.fileExists(atPath: output.temporaryURL.path) else {
                    throw ConversionError.fileNotFound(path: output.temporaryURL.path)
                }
            }

            // Compression that does not shrink the file is not worth keeping.
            if job.preset.isPDFCompressWorkflow, plannedOutputs.count == 1 {
                let sourceSize = FileAccessManager.shared.fileSize(at: job.sourceURL)
                let outputSize = FileAccessManager.shared.fileSize(at: plannedOutputs[0].temporaryURL)
                if sourceSize > 0, outputSize >= sourceSize {
                    OutputNamingEngine.cleanupTemporaryFile(at: plannedOutputs[0].temporaryURL)
                    StagingArtifactManifest.shared.unregisterArtifacts(for: jobID)
                    ConversionJournal.shared.transitionState(jobID: jobID, to: .cancelled)
                    await finishJob(
                        id: jobID,
                        state: .skipped("Already optimized: the compressed file was not smaller"),
                        batchID: capturedBatchID
                    )
                    return
                }
            }

            // 5. Finalize output without replacing files for non-overwrite policies.
            ConversionJournal.shared.transitionState(jobID: jobID, to: .committing)
            await updateJob(job, state: .finalizing)
            try Task.checkCancellation()
            let canCommit = await MainActor.run { self.canCommitOutput(for: jobID) }
            guard canCommit else {
                throw CancellationError()
            }
            // Revalidate destination identity immediately before replacement;
            // abort if another process changed the destination or it now
            // refers to the source file.
            for output in plannedOutputs {
                if FileAccessManager.shared.urlsReferToSameFile(job.sourceURL, output.finalURL) {
                    throw ConversionError.destinationUnavailable(path: output.finalURL.path)
                }
            }
            if effectivePolicy == .replaceIfNewer {
                for output in plannedOutputs {
                    try revalidateReplaceIfNewer(sourceURL: job.sourceURL, destinationURL: output.finalURL)
                }
            }
            let isKeepBoth = effectivePolicy == .appendNumber
            let allowsReplacement = effectivePolicy == .overwrite
                || effectivePolicy == .replaceIfNewer
                || job.collisionPlan != nil
            let report = try OutputNamingEngine.finalizeConversionOutputsWithReport(
                plannedOutputs,
                overwrite: allowsReplacement,
                collisionPlan: job.collisionPlan,
                sourceURL: job.sourceURL,
                isReplaceIfNewer: effectivePolicy == .replaceIfNewer,
                allowKeepBothRetry: isKeepBoth
            )
            let committedURLs = report.committedURLs
            for original in report.untrashableOriginals {
                warnings.append("The previous \(original.lastPathComponent) could not be moved to the Trash and was replaced.")
            }
            job.outputURLs = committedURLs
            if let first = committedURLs.first {
                job.destinationURL = first
            }
            StagingArtifactManifest.shared.unregisterArtifacts(for: jobID)
            ConversionJournal.shared.transitionState(jobID: jobID, to: .finished, outputPaths: committedURLs.map(\.path))

            // 6. Preserve timestamps if requested. Metadata failures should not
            // discard an otherwise valid output; make them visible as warnings.
            if settings.preserveCreationDate.value || settings.preserveModificationDate.value {
                for outputURL in committedURLs {
                    do {
                        try FileAccessManager.shared.preserveTimestamps(
                            from: job.sourceURL,
                            to: outputURL,
                            creation: settings.preserveCreationDate.value,
                            modification: settings.preserveModificationDate.value
                        )
                    } catch {
                        warnings.append("Could not preserve timestamps for \(outputURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            job.warnings = warnings
            await updateJob(job, state: .finalizing)

            // 7. Mark completed
            await finishJob(id: jobID, state: warnings.isEmpty ? .completed : .completedWithWarnings(warnings), batchID: capturedBatchID)

        } catch {
            // Clean up temporary output file
            for output in job.plannedOutputs {
                OutputNamingEngine.cleanupTemporaryFile(at: output.temporaryURL)
            }
            if job.plannedOutputs.isEmpty, let tempURL = job.temporaryOutputURL {
                OutputNamingEngine.cleanupTemporaryFile(at: tempURL)
            }
            StagingArtifactManifest.shared.unregisterArtifacts(for: jobID)
            ConversionJournal.shared.transitionState(jobID: jobID, to: (error is CancellationError ? .cancelled : .failed))

            if error is CancellationError {
                await finishJob(id: jobID, state: .cancelled, batchID: capturedBatchID)
            } else if let convErr = error as? ConversionError {
                AppLogger.conversion.error("Job \(jobID) failed: \(convErr.localizedDescription)")
                if convErr == .cancelled {
                    await finishJob(id: jobID, state: .cancelled, batchID: capturedBatchID)
                } else if case .destinationReserved(let path) = convErr {
                    job.sourceAccessLease?.release()
                    job.sourceAccessLease = nil
                    await deferUntilDestinationIsFree(jobID: jobID, path: path)
                } else if case .outputCollision(let path) = convErr, job.effectiveOverwritePolicy == .ask {
                    await markAwaitingCollision(jobID: jobID, destinationPath: path)
                    job.sourceAccessLease = nil
                } else if case .outputCollision = convErr,
                          job.effectiveOverwritePolicy == .skip || job.effectiveOverwritePolicy == .replaceIfNewer {
                    await finishJob(id: jobID, state: .skipped("Output already exists"), batchID: capturedBatchID)
                } else {
                    await finishJob(id: jobID, state: .failed(convErr), batchID: capturedBatchID)
                }
            } else {
                let convErr = ConversionError.unknown(message: error.localizedDescription)
                AppLogger.conversion.error("Job \(jobID) failed: \(error.localizedDescription)")
                await finishJob(id: jobID, state: .failed(convErr), batchID: capturedBatchID)
            }
        }
    }

    nonisolated private func effectiveJobWithOutputs(job: ConversionJob, outputs: [PlannedConversionOutput]) -> ConversionJob {
        var copy = job
        copy.plannedOutputs = outputs
        copy.outputURLs = outputs.map(\.finalURL)
        if let first = outputs.first {
            copy.destinationURL = first.finalURL
            copy.temporaryOutputURL = first.temporaryURL
        }
        return copy
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
        guard !requirements.isEmpty else {
            throw ConversionError.destinationUnavailable(path: "")
        }
        // Exclude this job's own held reservations so a collision retry can
        // deterministically reclaim the same destination.
        var localReservations = Set(
            reservedOutputURLs.filter { $0.value != job.id }.map(\.key)
        )
        var outputs: [PlannedConversionOutput] = []
        var planned: [PlannedConversionOutput] = []
        var detectedCollisions: [URL] = []
        do {
            // Use the effective per-attempt preset so collision overrides apply
            // deterministically without mutating the stored preset.
            // When a collision plan is present, do not escalate the preset overwrite policy
            // so that unreviewed outputs cannot inherit a blanket overwrite.
            var effectivePreset = job.preset
            if job.collisionPlan == nil, let override = job.collisionOverride {
                effectivePreset.overwritePolicy = override
            }
            for requirement in requirements {
                do {
                    let finalDestinationURL = try OutputNamingEngine.resolveFinalDestinationURL(
                        sourceURL: job.sourceURL,
                        preset: effectivePreset,
                        targetExtension: requirement.extensionName,
                        suffix: requirement.suffix,
                        reservedURLs: localReservations,
                        customFolderURL: customFolderURL,
                        collisionPlan: job.collisionPlan,
                        namingDate: job.batchCreatedAt
                    )
                    // Serialize jobs targeting the same destination, including
                    // overwrite policies: the reservation is ownership-aware.
                    localReservations.insert(FileAccessManager.shared.reservationKey(for: finalDestinationURL))
                    let temporaryURL = OutputNamingEngine.createTemporaryOutputURL(for: finalDestinationURL)
                    StagingArtifactManifest.shared.registerArtifact(path: temporaryURL.path, jobID: job.id, kind: .temporaryFile)
                    planned.append(PlannedConversionOutput(finalURL: finalDestinationURL, temporaryURL: temporaryURL))
                } catch let error as ConversionError {
                    if case .outputCollision(let path) = error {
                        let collidingURL = URL(fileURLWithPath: path)
                        detectedCollisions.append(collidingURL)
                        localReservations.insert(FileAccessManager.shared.reservationKey(for: collidingURL))
                    } else {
                        throw error
                    }
                }
            }
            if !detectedCollisions.isEmpty {
                holdCollisionReservations(
                    for: job.id,
                    plannedOutputs: planned,
                    collidingURLs: detectedCollisions
                )
                throw ConversionError.outputCollision(path: detectedCollisions.first!.path)
            }
            outputs = planned
        } catch let error as ConversionError {
            throw error
        }

        // Transfer this job's existing reservation set to the newly resolved
        // outputs in one main-actor operation. Keeping the old set until this
        // point prevents a concurrent job from stealing it during a retry.
        replaceReservations(for: job.id, with: outputs.map(\.finalURL))
        guard let first = outputs.first else { throw ConversionError.destinationUnavailable(path: "") }
        jobs[index].sourceURL = job.sourceURL
        jobs[index].sourceAccessLease = job.sourceAccessLease
        jobs[index].destinationURL = first.finalURL
        jobs[index].temporaryOutputURL = first.temporaryURL
        jobs[index].plannedOutputs = outputs
        jobs[index].outputURLs = outputs.map(\.finalURL)
        jobs[index].resolvedBackend = job.resolvedBackend
        jobs[index].collisionOverride = job.collisionOverride
        jobs[index].collisionPlan = job.collisionPlan
        return outputs
    }

    /// Puts a job back in line until the job that reserved `path` releases
    /// it. The waiting job holds no reservations of its own meanwhile.
    private func deferUntilDestinationIsFree(jobID: UUID, path: String) {
        runningTasks.removeValue(forKey: jobID)
        activeJobIDs.remove(jobID)
        releaseReservations(for: jobID)
        if let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].state.isTerminal {
            jobs[index].state = .queued
            jobs[index].startedAt = nil
            jobs[index].progress = ConversionProgress()
            jobs[index].waitingForDestinationKey = FileAccessManager.shared.reservationKey(for: URL(fileURLWithPath: path))
            jobs[index].destinationURL = nil
            jobs[index].temporaryOutputURL = nil
            jobs[index].plannedOutputs = []
            jobs[index].outputURLs = []
            jobs[index].resolvedSettings = nil
            jobs[index].sourceAccessLease?.release()
            jobs[index].sourceAccessLease = nil
        }
        updateCountsAndProgress()
        processNextJobs()
    }

    private func isWaitingForReservedDestination(_ job: ConversionJob) -> Bool {
        guard let key = job.waitingForDestinationKey else { return false }
        if let owner = reservedOutputURLs[key], owner != job.id { return true }
        return false
    }

    private func storeResolvedSettings(_ settings: ResolvedConversionSettings, for jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].resolvedSettings = settings
    }

    private func releaseReservations(for jobID: UUID) {
        let hadReservations = reservedOutputURLs.values.contains(jobID)
        reservedOutputURLs = reservedOutputURLs.filter { $0.value != jobID }
        if hadReservations, jobs.contains(where: { $0.waitingForDestinationKey != nil && $0.state == .queued }) {
            // A waiting job may now be able to run.
            Task { @MainActor [weak self] in self?.processNextJobs() }
        }
    }

    private func replaceReservations(for jobID: UUID, with urls: [URL]) {
        let keys = urls.map { FileAccessManager.shared.reservationKey(for: $0) }
        reservedOutputURLs = reservedOutputURLs.filter { $0.value != jobID }
        for key in keys {
            reservedOutputURLs[key] = jobID
        }
    }

    private func holdCollisionReservations(
        for jobID: UUID,
        plannedOutputs: [PlannedConversionOutput],
        collidingURLs: [URL]
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        if !plannedOutputs.isEmpty {
            jobs[index].plannedOutputs = plannedOutputs
            jobs[index].outputURLs = plannedOutputs.map(\.finalURL)
            jobs[index].destinationURL = plannedOutputs.first?.finalURL
            jobs[index].temporaryOutputURL = plannedOutputs.first?.temporaryURL
        }

        jobs[index].conflictingOutputURLs = collidingURLs

        let candidateURLs = plannedOutputs.map(\.finalURL) + collidingURLs
        for url in candidateURLs {
            let key = FileAccessManager.shared.reservationKey(for: url)
            if reservedOutputURLs[key] == nil || reservedOutputURLs[key] == jobID {
                reservedOutputURLs[key] = jobID
            }
        }
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
            jobs[index].collisionPlan = job.collisionPlan
            jobs[index].collisionOverride = job.collisionOverride
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

    private func finishJob(id: UUID, state: JobState, batchID: UUID? = nil) {
        var leaseToRelease: SecurityScopedLease?
        // Keep a completion snapshot before any removal; batch identity is
        // the job's captured batch ID — never a newer active batch fallback.
        var capturedBatchID = batchID
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            capturedBatchID = capturedBatchID ?? jobs[index].batchID
            if !jobs[index].state.isTerminal {
                jobs[index].state = state
            }
            jobs[index].finishedAt = Date()
            if jobs[index].state == .completed || ifCaseCompletedWithWarnings(jobs[index].state) {
                jobs[index].progress.fractionCompleted = 1.0
            } else if case .failed = jobs[index].state {
                jobs[index].progress.fractionCompleted = 0.0
            }
            leaseToRelease = jobs[index].sourceAccessLease
            jobs[index].sourceAccessLease = nil
            releaseReservations(for: id)
        } else {
            // Job was removed: stop tracking without notifying a wrong batch.
            runningTasks.removeValue(forKey: id)
            activeJobIDs.remove(id)
            leaseToRelease?.release()
            updateCountsAndProgress()
            return
        }
        runningTasks.removeValue(forKey: id)
        activeJobIDs.remove(id)
        let batchJobs = jobs.filter { $0.batchID == capturedBatchID }
        let isAllDone = capturedBatchID != nil && !batchJobs.isEmpty && batchJobs.allSatisfy { $0.state.isTerminal }
        let totalCount = batchJobs.count
        let failed = batchJobs.filter { if case .failed = $0.state { return true }; return false }.count
        let completed = batchJobs.filter { $0.state == .completed || ifCaseCompletedWithWarnings($0.state) }.count
        let skippedOrCancelled = totalCount - completed - failed
        let shouldNotify: Bool
        if isAllDone, let capturedBatchID {
            shouldNotify = notifiedBatchIDs.insert(capturedBatchID).inserted
        } else {
            shouldNotify = false
        }

        leaseToRelease?.release()
        updateCountsAndProgress()
        saveHistory()
        if shouldNotify, totalCount > 0, let capturedBatchID {
            let completedURLs = batchJobs.flatMap { job -> [URL] in
                guard job.state == .completed || ifCaseCompletedWithWarnings(job.state) else { return [] }
                return job.outputURLs.isEmpty ? (job.destinationURL.map { [$0] } ?? []) : job.outputURLs
            }
            sendBatchCompletionNotification(
                batchID: capturedBatchID,
                total: totalCount,
                completed: completed,
                failed: failed,
                skippedOrCancelled: skippedOrCancelled,
                destinationURLs: completedURLs,
                batchJobs: batchJobs
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
        self.overallProgress = currentJobs.isEmpty ? 0.0 : (currentJobs.reduce(0.0) { sum, job in
            switch job.state {
            case .completed, .completedWithWarnings:
                return sum + 1.0
            case .converting, .preparing, .finalizing:
                return sum + max(0.0, min(1.0, job.progress.fractionCompleted))
            case .queued, .awaitingCollision, .cancelled, .failed, .skipped:
                return sum + 0.0
            }
        } / Double(currentJobs.count))
        // Lifecycle completion reaches 1.0 once every job is terminal,
        // while successFraction tracks completed/total separately.
        let terminalCount = completed + failed + skipped + cancelled
        self.completionProgress = currentJobs.isEmpty ? 0.0 : Double(terminalCount) / Double(currentJobs.count)
        self.successFraction = currentJobs.isEmpty ? 0.0 : Double(completed) / Double(currentJobs.count)
    }

    private func markAwaitingCollision(jobID: UUID, destinationPath: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        // Hold the reservation while awaiting a decision so a concurrent job
        // cannot claim the same destination. Do not release the source lease
        // here; the awaiting job retains ownership until resolved/cancelled.
        // Capture every planned output for multi-output jobs.
        let destinationURL = URL(fileURLWithPath: destinationPath)
        var allConflicts = jobs[index].conflictingOutputURLs
        if allConflicts.isEmpty {
            allConflicts = jobs[index].plannedOutputs.map(\.finalURL)
        }
        if !allConflicts.contains(where: {
            FileAccessManager.shared.reservationKey(for: $0)
                == FileAccessManager.shared.reservationKey(for: destinationURL)
        }) {
            allConflicts.append(destinationURL)
        }
        jobs[index].conflictingOutputURLs = allConflicts
        holdCollisionReservations(
            for: jobID,
            plannedOutputs: jobs[index].plannedOutputs,
            collidingURLs: allConflicts
        )
        // TASK-021: Awaiting-collision job must never store an inactive lease.
        // Deliberately release and clear so retry must resolve and reacquire fresh.
        jobs[index].sourceAccessLease?.release()
        jobs[index].sourceAccessLease = nil

        jobs[index].state = .awaitingCollision
        jobs[index].finishedAt = nil
        var fingerprints: [URL: DestinationFingerprint] = [:]
        for url in allConflicts {
            fingerprints[url] = DestinationFingerprint(url: url)
        }
        let conflict = CollisionConflict(
            jobID: jobID,
            destinationURL: destinationURL,
            sourceFilename: jobs[index].filename,
            conflictingURLs: allConflicts,
            destinationFingerprints: fingerprints
        )
        if let existingIdx = pendingCollisions.firstIndex(where: { $0.jobID == jobID }) {
            pendingCollisions[existingIdx] = conflict
        } else {
            pendingCollisions.append(conflict)
        }
        runningTasks.removeValue(forKey: jobID)
        activeJobIDs.remove(jobID)
        updateCountsAndProgress()
        processNextJobs()

        // One alert per batch: the conflict sheet lists every file, so
        // further conflicts in the same batch need no extra attention.
        let batchID = jobs[index].batchID
        guard collisionAlertedBatchIDs.insert(batchID).inserted else { return }
        NotificationCenter.default.post(
            name: NSNotification.Name("FileConverterActivateApp"),
            object: nil
        )
        let batchConflictCount = jobs.filter { $0.batchID == batchID && $0.state == .awaitingCollision }.count
        postUserNotification(
            title: "Files Already Exist",
            body: batchConflictCount > 1
                ? "Some files in this batch already exist. Choose what to do with each."
                : "\(jobs[index].filename) would replace an existing file. Choose what to do."
        )
    }

    /// Batches that already raised the conflict alert.
    private var collisionAlertedBatchIDs = Set<UUID>()

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
        batchID: UUID,
        total: Int,
        completed: Int,
        failed: Int,
        skippedOrCancelled: Int,
        destinationURLs: [URL] = [],
        batchJobs: [ConversionJob] = []
    ) {
        NotificationHandoffStore.save(batchID: batchID, outputURLs: destinationURLs)
        if !destinationURLs.isEmpty {
            NotificationCenter.default.post(
                name: .fileConverterBatchCompleted,
                object: nil,
                userInfo: Self.notificationUserInfo(for: batchID)
            )
        }

        let enabled = ConversionDefaults.store.object(forKey: "enableNotifications") as? Bool ?? false
        guard enabled else { return }
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = Self.formatBatchNotificationTitle(total: total, completed: completed, failed: failed)
        content.body = Self.formatBatchNotificationBody(
            total: total,
            completed: completed,
            failed: failed,
            skippedOrCancelled: skippedOrCancelled,
            batchJobs: batchJobs
        )
        content.sound = .default
        content.userInfo = Self.notificationUserInfo(for: batchID)

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    nonisolated public static let completionBatchIdentifierKey = "completionBatchID"

    nonisolated public static func notificationUserInfo(for batchID: UUID) -> [AnyHashable: Any] {
        [completionBatchIdentifierKey: batchID.uuidString]
    }

    /// Runs a reveal action only for outputs previously allowlisted for the
    /// opaque completion batch. Bookmark resolution and a fresh filesystem
    /// existence/readability check happen immediately before the action; the
    /// scoped leases remain active until the action returns.
    public func withNotificationRevealURLs(
        for batchID: UUID,
        _ action: ([URL]) -> Void
    ) {
        let persistedLeases = NotificationHandoffStore.leases(for: batchID)
        var leases = persistedLeases
        var candidates = leases.map(\.url)

        let inMemoryURLs = jobs
            .filter { $0.batchID == batchID && ($0.state == .completed || ifCaseCompletedWithWarnings($0.state)) }
            .flatMap { $0.outputURLs.isEmpty ? ($0.destinationURL.map { [$0] } ?? []) : $0.outputURLs }
        candidates.append(contentsOf: inMemoryURLs)

        var seenKeys = Set<URL>()
        let revealable = candidates.filter { url in
            let key = FileAccessManager.shared.reservationKey(for: url)
            guard seenKeys.insert(key).inserted else { return false }
            return NotificationHandoffStore.isRevealable(url)
        }

        if !revealable.isEmpty {
            action(revealable)
        }
        leases.forEach { $0.release() }
        leases.removeAll()
    }

    func persistNotificationHandoffForTesting(batchID: UUID, outputURLs: [URL]) {
        NotificationHandoffStore.save(batchID: batchID, outputURLs: outputURLs)
    }

    func clearNotificationHandoffForTesting(batchID: UUID) {
        NotificationHandoffStore.remove(batchID: batchID)
    }

    /// Says how the batch went, so a failure never reads as "Finished".
    nonisolated public static func formatBatchNotificationTitle(total: Int, completed: Int, failed: Int) -> String {
        if failed > 0 {
            if completed > 0 { return "Some Conversions Failed" }
            return total == 1 ? "Conversion Failed" : "Conversions Failed"
        }
        return completed > 0 ? "Conversion Finished" : "Nothing Converted"
    }

    nonisolated public static func formatBatchNotificationBody(
        total: Int,
        completed: Int,
        failed: Int,
        skippedOrCancelled: Int,
        batchJobs: [ConversionJob] = []
    ) -> String {
        if total == 1, let job = batchJobs.first {
            let targetFormat = job.targetFormat
            if completed == 1 {
                return "\(job.filename) converted to \(targetFormat)."
            } else if failed == 1 {
                return "\(job.filename) conversion failed."
            } else {
                return "\(job.filename) was \(job.state == .cancelled ? "cancelled" : "skipped")."
            }
        } else if total == 1 {
            if completed == 1 {
                return "File converted successfully."
            } else if failed == 1 {
                return "File conversion failed."
            } else {
                return "File conversion was skipped or cancelled."
            }
        } else {
            let formats = Set(batchJobs.map(\.targetFormat))
            let uniformFormat = formats.count == 1 ? formats.first : nil

            if failed == 0 && skippedOrCancelled == 0 {
                if let uniformFormat {
                    return "\(completed) files converted to \(uniformFormat)."
                } else {
                    return "\(completed) files converted successfully."
                }
            } else {
                var outcomes = [String]()
                if completed > 0 {
                    if let uniformFormat {
                        outcomes.append("\(completed) converted to \(uniformFormat)")
                    } else {
                        outcomes.append("\(completed) converted")
                    }
                }
                if failed > 0 { outcomes.append("\(failed) failed") }
                if skippedOrCancelled > 0 { outcomes.append("\(skippedOrCancelled) skipped or cancelled") }
                return outcomes.joined(separator: ", ") + "."
            }
        }
    }
}

public extension Notification.Name {
    static let fileConverterBatchCompleted = Notification.Name("io.fileconverter.batchCompleted")
}

private enum NotificationHandoffStore {
    private struct Record: Codable {
        let batchID: UUID
        let outputBookmarks: [Data]
        let createdAt: Date
    }

    private static let defaultsKey = "io.fileconverter.notificationHandoffs"
    private static let maximumRecords = 32
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    static func save(batchID: UUID, outputURLs: [URL]) {
        let bookmarks = outputURLs.compactMap(bookmarkData(for:))
        var records = loadRecords()
        records.removeAll { $0.batchID == batchID }
        records.insert(
            Record(batchID: batchID, outputBookmarks: bookmarks, createdAt: Date()),
            at: 0
        )
        persist(Array(records.prefix(maximumRecords)))
    }

    static func remove(batchID: UUID) {
        persist(loadRecords().filter { $0.batchID != batchID })
    }

    static func leases(for batchID: UUID) -> [SecurityScopedLease] {
        guard let record = loadRecords().first(where: { $0.batchID == batchID }) else {
            return []
        }
        return record.outputBookmarks.compactMap { try? SecurityScopedLease(bookmarkData: $0) }
    }

    static func isRevealable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path),
              (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else {
            return false
        }
        return true
    }

    private static func bookmarkData(for url: URL) -> Data? {
        guard isRevealable(url) else { return nil }
        return (try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? (try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))
    }

    private static func loadRecords() -> [Record] {
        guard let data = ConversionDefaults.store.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-retention)
        return records.filter { $0.createdAt >= cutoff }
    }

    private static func persist(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        ConversionDefaults.store.set(data, forKey: defaultsKey)
    }
}
