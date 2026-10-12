import Foundation
import FileConverterContracts
import UserNotifications

public actor ConversionCoordinator {
    public static let shared = ConversionCoordinator()

    private var isDrainingPendingRequests = false
    private var shouldDrainPendingRequestsAgain = false
    private var admittedRequestExpirations: [UUID: Date] = [:]

    public init() {
        do {
            try IPCChannels.prepareHost()
        } catch {
            AppLogger.conversion.error("Finder integration setup failed: \(error.localizedDescription, privacy: .public)")
        }
        startListeningForIPCRequests()
    }

    public func handleConversionRequest(_ request: ConversionRequest) async throws {
        // Resolve the preset before the optional host configuration lookup so
        // direct/test calls preserve the useful unknown-preset error. A known
        // preset still fails closed when no product bundle configuration is
        // available; the request's declared edition is never trusted as a
        // fallback authority.
        guard let preset = PresetStore.shared.preset(forID: request.presetID) else {
            throw ConversionCoordinatorError.unknownPreset
        }

        // Defense-in-depth at the coordinator boundary: IPC claim decoding
        // already validates expiry, but direct calls must also validate
        // edition, lifetime, source count, and bookmark limits.
        let configuration: IPCConfiguration
        do {
            configuration = try IPCConfiguration.current()
        } catch {
            throw ConversionCoordinatorError.missingBuildConfiguration
        }
        try request.validate(expectedEdition: configuration.edition)

        // After a cold launch, optional tools may still be under discovery.
        // Wait for it rather than rejecting a preset that will be usable in
        // a moment.
        if !Self.isGuaranteedNative(preset) {
            let ready = await BackendReadinessGate.shared.waitUntilReady(timeout: .seconds(30))
            if !ready {
                AppLogger.conversion.notice("Tool discovery still running after 30 s; admitting with current results.")
            }
        }
        AppLogger.conversion.notice(
            "Admitting Finder request: id=\(request.id.uuidString, privacy: .public), preset=\(request.presetID.uuidString, privacy: .public), sourceCount=\(request.sources.count, privacy: .public)"
        )

        if preset.isInteractiveWorkflow {
            let leases = try request.sources.map { source in
                do {
                    return try SecurityScopedLease(bookmarkData: source.bookmarkData)
                } catch {
                    throw ConversionError.sandboxAccessFailure(path: source.lastKnownPath)
                }
            }
            let urls = leases.map(\.url)
            try validateAdmission(urls: urls, preset: preset)

            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("FileConverterActivateApp"),
                    object: nil
                )
                NotificationCenter.default.post(
                    name: NSNotification.Name("OpenFileConverterWorkflowDialog"),
                    object: nil,
                    userInfo: [
                        "preset": preset,
                        "urls": urls,
                        "leases": leases
                    ]
                )
            }
            AppLogger.conversion.notice(
                "Finder request routed to interactive workflow dialog: id=\(request.id.uuidString, privacy: .public)"
            )
            return
        }

        let jobs = try request.sources.map { source in
            let lease: SecurityScopedLease
            do {
                lease = try SecurityScopedLease(bookmarkData: source.bookmarkData)
            } catch {
                throw ConversionError.sandboxAccessFailure(path: source.lastKnownPath)
            }
            return ConversionJob(
                sourceURL: lease.url,
                sourceBookmarkData: source.bookmarkData,
                sourceAccessLease: lease,
                preset: preset,
                detectionSnapshot: FormatDetector.snapshot(for: lease.url)
            )
        }

        try validateAdmission(urls: jobs.map(\.sourceURL), preset: preset)
        await ConversionQueue.shared.addJobs(jobs)
        AppLogger.conversion.notice(
            "Finder request admitted to conversion queue: id=\(request.id.uuidString, privacy: .public)"
        )
        postUserNotification(
            title: "Conversion Started",
            body: jobs.count == 1
                ? "Queued \(jobs.first?.sourceURL.lastPathComponent ?? "file") for \(preset.name)."
                : "Queued \(jobs.count) files for \(preset.name)."
        )
    }

    /// Presets that never need optional command-line tools.
    static func isGuaranteedNative(_ preset: ConversionPreset) -> Bool {
        [.imageIO, .pdfKit, .avFoundation].contains(preset.backend)
    }

    public func convertFiles(
        urls: [URL],
        preset: ConversionPreset,
        leases: [SecurityScopedLease]? = nil
    ) async throws {
        try validateAdmission(urls: urls, preset: preset)
        let leasesByURL = Dictionary(
            (leases ?? []).map { ($0.url.resolvingSymlinksInPath().standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var jobs: [ConversionJob] = []
        jobs.reserveCapacity(urls.count)
        for url in urls {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path
            let lease = leasesByURL[key] ?? (leases?.count == 1 && urls.count == 1 ? leases?.first : nil)
            let bookmark: Data?
            do {
                bookmark = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                // A retained lease is sufficient for this in-process call, but
                // a URL without either a bookmark or a lease would otherwise
                // enter the queue and fail later with less useful context.
                guard lease != nil else {
                    throw ConversionError.sandboxAccessFailure(path: url.path)
                }
                bookmark = nil
            }
            jobs.append(ConversionJob(
                sourceURL: url,
                sourceBookmarkData: bookmark,
                sourceAccessLease: lease,
                preset: preset,
                detectionSnapshot: FormatDetector.snapshot(for: url)
            ))
        }
        await ConversionQueue.shared.addJobs(jobs)
    }

    public func checkAndDrainPendingRequests() async {
        guard !isDrainingPendingRequests else {
            shouldDrainPendingRequestsAgain = true
            return
        }

        isDrainingPendingRequests = true
        defer { isDrainingPendingRequests = false }

        repeat {
            shouldDrainPendingRequestsAgain = false
            await drainPendingRequests()
        } while shouldDrainPendingRequestsAgain
    }

    private func drainPendingRequests() async {
        do {
            let claims = try IPCChannels.claimPendingRequests()
            if !claims.isEmpty {
                AppLogger.conversion.notice(
                    "Claimed \(claims.count, privacy: .public) Finder request(s)"
                )
            }
            let now = Date()
            admittedRequestExpirations = admittedRequestExpirations.filter { $0.value >= now }

            var requestIDs = Set<UUID>()
            var uniqueClaims: [ClaimedConversionRequest] = []
            var duplicateClaims: [ClaimedConversionRequest] = []
            for claim in claims {
                if requestIDs.insert(claim.request.id).inserted {
                    uniqueClaims.append(claim)
                } else {
                    duplicateClaims.append(claim)
                }
            }

            for claim in duplicateClaims {
                try? IPCChannels.reject(claim)
            }

            for claim in uniqueClaims {
                if admittedRequestExpirations[claim.request.id] != nil {
                    do {
                        try IPCChannels.acknowledge(claim)
                    } catch {
                        try? IPCChannels.reject(claim)
                        AppLogger.conversion.error(
                            "Could not clean up duplicate Finder request: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    continue
                }

                do {
                    try await handleConversionRequest(claim.request)
                    admittedRequestExpirations[claim.request.id] = claim.request.expiresAt
                } catch {
                    try? IPCChannels.reject(claim)
                    AppLogger.conversion.error(
                        "Finder request rejected: id=\(claim.request.id.uuidString, privacy: .public), error=\(error.localizedDescription, privacy: .public)"
                    )
                    let rejectedSources = claim.request.sources.map { (displayName: $0.displayName, path: $0.lastKnownPath) }
                    let rejectedPreset = PresetStore.shared.preset(forID: claim.request.presetID)
                    let reason = error.localizedDescription
                    await ConversionQueue.shared.recordRejectedRequest(
                        sources: rejectedSources,
                        preset: rejectedPreset,
                        reason: reason
                    )
                    continue
                }

                do {
                    try IPCChannels.acknowledge(claim)
                } catch {
                    try? IPCChannels.reject(claim)
                    AppLogger.conversion.error(
                        "Finder request was admitted but its receipt could not be removed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        } catch {
            AppLogger.conversion.error("Could not receive Finder requests: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private func startListeningForIPCRequests() {
        guard let configuration = try? IPCConfiguration.current() else { return }
        let notificationName = IPCChannels.notificationName(configuration: configuration)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, _, name, _, _ in
                guard let configuration = try? IPCConfiguration.current() else { return }
                if name?.rawValue as String? == IPCChannels.notificationName(configuration: configuration) {
                    Task {
                        await ConversionCoordinator.shared.checkAndDrainPendingRequests()
                    }
                }
            },
            notificationName as CFString,
            nil,
            .deliverImmediately
        )

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            await self?.checkAndDrainPendingRequests()

            // A second launch pass lets a just-abandoned receipt age out of its claim lease.
            try? await Task.sleep(
                for: .seconds(Int64(IPCChannels.processingClaimLeaseDuration))
            )
            await self?.checkAndDrainPendingRequests()
        }
    }

    private func validateAdmission(urls: [URL], preset: ConversionPreset) throws {
        let report = PresetValidator.admissionReport(forURLs: urls, preset: preset, resolver: .shared)
        guard report.isFullyAdmissible else {
            let reasons = report.rejectedSources.compactMap(\.rejectionReason).joined(separator: " ")
            AppLogger.conversion.error("Admission rejected \(report.rejectedSources.count, privacy: .public) source(s): \(reasons, privacy: .public)")
            throw ConversionCoordinatorError.incompatiblePresetWithReason(reasons)
        }
    }
}

func postUserNotification(title: String, body: String) {
    let enabled = UserDefaults.standard.object(forKey: "enableNotifications") as? Bool ?? false
    guard enabled else { return }
    guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return }

    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(request, withCompletionHandler: nil)
}

public enum ConversionCoordinatorError: LocalizedError, Sendable {
    case unknownPreset
    case missingBuildConfiguration
    case incompatiblePreset
    case incompatiblePresetWithReason(String)

    public var errorDescription: String? {
        switch self {
        case .unknownPreset:
            return "The requested conversion preset is unavailable."
        case .missingBuildConfiguration:
            return "File Converter is not configured for this product edition. Reopen the app to finish setup."
        case .incompatiblePreset:
            return "The selected preset cannot convert every selected file in this edition."
        case .incompatiblePresetWithReason(let reason):
            return reason.isEmpty
                ? "The selected preset cannot convert every selected file in this edition."
                : reason
        }
    }
}
