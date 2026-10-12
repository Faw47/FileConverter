import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends
@testable import FileConverterExternalBackends

final class IgnoredSettingsTests: XCTestCase {
    func testAppleEncoderReportsCRFAsUnused() throws {
        let preset = try BackendHarness.builtIn("video.mp4-balanced")
        let mp4 = try XCTUnwrap(FormatRegistry.shared.format(forID: "mp4"))
        XCTAssertTrue(AVFoundationBackend().ignoredSettings(for: preset, source: mp4).contains(.crf))
    }

    func testResolverListsAffectedSourceFormats() throws {
        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends())
        let preset = try BackendHarness.builtIn("video.mp4-balanced")
        let affected = resolver.ignoredSettings(for: preset).filter { $0.keys.contains(.crf) }
        XCTAssertTrue(affected.contains { $0.format.id == "mp4" && $0.backend == .avFoundation }, "\(affected.map(\.format.id))")
    }

    func testFFmpegHardwareEncoderIgnoresCRFSoftwareDoesNot() throws {
        guard ExternalToolDiscovery.shared.availableFFmpegEncoders().contains("h264_videotoolbox") else {
            throw XCTSkip("No VideoToolbox H.264 encoder in this FFmpeg build.")
        }
        var preset = try BackendHarness.builtIn("video.mp4-balanced")
        let mkv = try XCTUnwrap(FormatRegistry.shared.format(forID: "mkv"))
        XCTAssertEqual(FFmpegBackend().ignoredSettings(for: preset, source: mkv), [.crf])
        preset.hardwareAcceleration = .softwareOnly
        XCTAssertEqual(FFmpegBackend().ignoredSettings(for: preset, source: mkv), [.videoBitrate])
    }
}
