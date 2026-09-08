import XCTest
@testable import FileConverterCore
import FileConverterContracts
import FileConverterNativeBackends

final class BackendIsolationTests: XCTestCase {
    func testNativeCatalogContainsOnlyAppleBackends() {
        let types = NativeBackendCatalog.makeBackends().map(\.backendType)

        XCTAssertEqual(types, [.imageIO, .pdfKit, .avFoundation])
        XCTAssertTrue(Set(types).isDisjoint(with: [.ffmpeg, .imageMagick, .libreOffice, .ghostscript]))
    }

    func testNativeResolverRejectsExternalPreset() throws {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        let preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "video.av1" }
        )
        let job = ConversionJob(sourceURL: URL(fileURLWithPath: "/tmp/source.mkv"), preset: preset)

        XCTAssertThrowsError(try resolver.resolveBackend(for: job)) { error in
            XCTAssertEqual(
                error as? ConversionError,
                .backendUnavailable(backend: BackendType.ffmpeg.displayName)
            )
        }
    }

    func testFinderSnapshotReflectsEditionBackendCapabilities() throws {
        let presets = BuiltInPresets.makeDefaultPresets()
        let externalPreset = try XCTUnwrap(presets.first { $0.builtInKey == "video.av1" })
        let nativeResolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        let extendedResolver = BackendResolver(
            backends: NativeBackendCatalog.makeBackends() + [AvailableMediaBackendStub()]
        )

        let nativeSnapshot = FinderMenuSnapshotWriter.makeSnapshot(
            presets: presets,
            resolver: nativeResolver,
            edition: .native
        )
        let extendedSnapshot = FinderMenuSnapshotWriter.makeSnapshot(
            presets: presets,
            resolver: extendedResolver,
            edition: .extended
        )

        XCTAssertFalse(nativeSnapshot.presets.contains { $0.id == externalPreset.id })
        XCTAssertTrue(extendedSnapshot.presets.contains { $0.id == externalPreset.id })
    }

    func testNativePresetSelectionExcludesExternalOnlyConversions() {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        let presets = BuiltInPresets.makeDefaultPresets()

        let qtaPresets = PresetValidator.compatiblePresets(
            forURLs: [URL(fileURLWithPath: "/tmp/recording.qta")],
            from: presets,
            resolver: resolver
        )
        let qtaMenuNames = Set(qtaPresets.map(\.menuName))
        XCTAssertTrue(qtaMenuNames.contains("M4A"))
        XCTAssertTrue(qtaMenuNames.contains("WAV"))
        if #available(macOS 26.0, *) {
            XCTAssertTrue(qtaMenuNames.contains("QTA"))
        } else {
            XCTAssertFalse(qtaMenuNames.contains("QTA"))
        }
        XCTAssertFalse(qtaMenuNames.contains("MP3"))
        XCTAssertFalse(qtaMenuNames.contains("FLAC"))
        XCTAssertFalse(qtaMenuNames.contains("Opus"))
        XCTAssertFalse(qtaMenuNames.contains("OGG"))

        XCTAssertTrue(PresetValidator.compatiblePresets(
            forURLs: [URL(fileURLWithPath: "/tmp/video.mkv")],
            from: presets,
            resolver: resolver
        ).isEmpty)
        XCTAssertTrue(PresetValidator.compatiblePresets(
            forURLs: [URL(fileURLWithPath: "/tmp/document.docx")],
            from: presets,
            resolver: resolver
        ).isEmpty)
    }

    func testResolverAwareSelectionRejectsDisabledPreset() throws {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends())
        var preset = try XCTUnwrap(
            BuiltInPresets.makeDefaultPresets().first { $0.builtInKey == "image.jpeg" }
        )
        preset.isEnabled = false

        let compatible = PresetValidator.compatiblePresets(
            forURLs: [URL(fileURLWithPath: "/tmp/image.png")],
            from: [preset],
            resolver: resolver
        )

        XCTAssertTrue(compatible.isEmpty)
    }
}

/// Deterministic stand-in for optional media tooling. Capability-selection
/// tests must not depend on what happens to be installed on the test Mac.
struct AvailableMediaBackendStub: ConversionBackend {
    let backendType: BackendType = .ffmpeg
    let isAvailable = true

    func supports(
        sourceFormat: FormatDefinition,
        destinationFormat: FormatDefinition,
        preset: ConversionPreset
    ) -> Bool {
        let mediaSource = sourceFormat.category == .audio || sourceFormat.category == .video
        let mediaDestination = destinationFormat.category == .audio
            || destinationFormat.category == .video
            || destinationFormat.id == "gif"
        return mediaSource && mediaDestination
    }

    func convert(
        job: ConversionJob,
        progressHandler: @escaping @Sendable (ConversionProgress) -> Void
    ) async throws {
        throw ConversionError.backendUnavailable(backend: "Test stub")
    }

    func cancel(jobID: UUID) async {}
}
