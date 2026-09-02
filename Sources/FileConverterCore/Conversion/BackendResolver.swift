import Foundation

public final class BackendResolver: @unchecked Sendable {
    public static let shared = BackendResolver()

    private let lock = NSLock()
    private var orderedBackends: [any ConversionBackend]
    private var backendsByType: [BackendType: any ConversionBackend]

    public init(backends: [any ConversionBackend] = []) {
        self.orderedBackends = []
        self.backendsByType = [:]
        configure(backends: backends)
    }

    public func configure(backends: [any ConversionBackend]) {
        var byType: [BackendType: any ConversionBackend] = [:]
        for backend in backends {
            precondition(backend.backendType != .auto, "Auto is a resolution policy, not a backend")
            precondition(byType[backend.backendType] == nil, "Duplicate backend registration: \(backend.backendType)")
            byType[backend.backendType] = backend
        }

        lock.withLock {
            orderedBackends = backends
            backendsByType = byType
        }
    }

    public var registeredBackendTypes: [BackendType] {
        lock.withLock { [.auto] + orderedBackends.map(\.backendType) }
    }

    public func backend(for type: BackendType) -> (any ConversionBackend)? {
        lock.withLock { backendsByType[type] }
    }

    public func resolveBackend(for job: ConversionJob) throws -> any ConversionBackend {
        guard let sourceFormat = FormatRegistry.shared.format(forURL: job.sourceURL) else {
            throw ConversionError.unsupportedInputFormat(
                path: job.sourceURL.path,
                detectedType: job.sourceURL.pathExtension
            )
        }
        guard let destinationFormat = FormatRegistry.shared.format(forID: job.preset.destinationFormat) else {
            throw ConversionError.unsupportedOutputFormat(targetFormat: job.preset.destinationFormat)
        }

        if job.preset.backend != .auto {
            guard let backend = backend(for: job.preset.backend) else {
                throw ConversionError.backendUnavailable(backend: job.preset.backend.displayName)
            }
            guard backend.supports(
                sourceFormat: sourceFormat,
                destinationFormat: destinationFormat,
                preset: job.preset
            ) else {
                throw ConversionError.incompatibleConversion(
                    sourceFormat: sourceFormat.id,
                    targetFormat: destinationFormat.id
                )
            }
            guard backend.isAvailable else {
                throw unavailableError(for: backend.backendType)
            }
            return backend
        }

        let backends = lock.withLock { orderedBackends }
        var firstUnavailableError: ConversionError?
        for backend in backends where backend.supports(
            sourceFormat: sourceFormat,
            destinationFormat: destinationFormat,
            preset: job.preset
        ) {
            if backend.isAvailable {
                return backend
            }
            firstUnavailableError = firstUnavailableError ?? unavailableError(for: backend.backendType)
        }

        if let firstUnavailableError {
            throw firstUnavailableError
        }
        throw ConversionError.incompatibleConversion(
            sourceFormat: sourceFormat.id,
            targetFormat: destinationFormat.id
        )
    }

    public func canResolve(preset: ConversionPreset, sourceFormat: FormatDefinition) -> Bool {
        guard let destinationFormat = FormatRegistry.shared.format(forID: preset.destinationFormat) else {
            return false
        }

        let candidates: [any ConversionBackend]
        if preset.backend == .auto {
            candidates = lock.withLock { orderedBackends }
        } else if let backend = backend(for: preset.backend) {
            candidates = [backend]
        } else {
            return false
        }

        return candidates.contains { backend in
            backend.supports(
                sourceFormat: sourceFormat,
                destinationFormat: destinationFormat,
                preset: preset
            )
        }
    }

    public func supportsAnySource(for preset: ConversionPreset) -> Bool {
        FormatRegistry.shared.allFormats().contains { format in
            presetAccepts(format: format, preset: preset) && canResolve(preset: preset, sourceFormat: format)
        }
    }

    public func cancel(jobID: UUID, backendType: BackendType?) async {
        guard let backendType, let backend = backend(for: backendType) else { return }
        await backend.cancel(jobID: jobID)
    }

    private func presetAccepts(format: FormatDefinition, preset: ConversionPreset) -> Bool {
        let sources = Set(preset.sourceFormats.map { $0.lowercased() })
        return sources.contains("*")
            || sources.contains(format.id.lowercased())
            || sources.contains(format.primaryExtension.lowercased())
            || sources.contains(format.category.rawValue.lowercased())
    }

    private func unavailableError(for type: BackendType) -> ConversionError {
        switch type {
        case .ffmpeg:
            return .dependencyMissing(dependencyName: "FFmpeg", installCommand: "brew install ffmpeg")
        case .imageMagick:
            return .dependencyMissing(dependencyName: "ImageMagick", installCommand: "brew install imagemagick")
        case .libreOffice:
            return .dependencyMissing(
                dependencyName: "LibreOffice",
                installCommand: "brew install --cask libreoffice"
            )
        case .ghostscript:
            return .dependencyMissing(dependencyName: "Ghostscript", installCommand: "brew install ghostscript")
        case .auto, .avFoundation, .imageIO, .pdfKit:
            return .backendUnavailable(backend: type.displayName)
        }
    }
}
