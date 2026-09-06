import Foundation
import FileConverterContracts

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
        AppLogger.conversion.notice(
            "Admitting Finder request: id=\(request.id.uuidString, privacy: .public), preset=\(request.presetID.uuidString, privacy: .public), sourceCount=\(request.sources.count, privacy: .public)"
        )
        guard let preset = PresetStore.shared.preset(forID: request.presetID) else {
            throw ConversionCoordinatorError.unknownPreset
        }

        let jobs = try request.sources.map { source in
            let lease = try SecurityScopedLease(bookmarkData: source.bookmarkData)
            return ConversionJob(
                sourceURL: lease.url,
                sourceBookmarkData: source.bookmarkData,
                sourceAccessLease: lease,
                preset: preset
            )
        }

        try validateAdmission(urls: jobs.map(\.sourceURL), preset: preset)
        await ConversionQueue.shared.addJobs(jobs)
        AppLogger.conversion.notice(
            "Finder request admitted to conversion queue: id=\(request.id.uuidString, privacy: .public)"
        )

        // Finder-initiated work is admitted in the background. The host app is
        // only brought forward by an explicit setup/error action.
    }

    public func convertFiles(urls: [URL], preset: ConversionPreset) async throws {
        try validateAdmission(urls: urls, preset: preset)
        let jobs = urls.map { ConversionJob(sourceURL: $0, preset: preset) }
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
        let compatible = PresetValidator.compatiblePresets(
            forURLs: urls,
            from: [preset],
            resolver: .shared
        )
        guard compatible.first?.id == preset.id else {
            throw ConversionCoordinatorError.incompatiblePreset
        }
    }
}

public enum ConversionCoordinatorError: LocalizedError, Sendable {
    case unknownPreset
    case incompatiblePreset

    public var errorDescription: String? {
        switch self {
        case .unknownPreset:
            return "The requested conversion preset is unavailable."
        case .incompatiblePreset:
            return "The selected preset cannot convert every selected file in this edition."
        }
    }
}
