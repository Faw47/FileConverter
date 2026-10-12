import XCTest
@testable import FileConverterCore
@testable import FileConverterNativeBackends

final class NativeAudioOutputTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try BackendHarness.makeTempDirectory("NativeAudio")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testALACPresetProducesLosslessALACWithSourceBitDepth() async throws {
        let source = try TestFixtures.copy("sine_48k_24bit.wav", to: directory)
        let preset = try BackendHarness.builtIn("audio.alac")
        let (outputs, _) = try await BackendHarness.convert(
            backend: AVFoundationBackend(), source: source, preset: preset, into: directory
        )
        let audio = try XCTUnwrap(try MediaAssertions.probe(try XCTUnwrap(outputs.first)).audioStreams.first)
        XCTAssertEqual(audio.codecName, "alac")
        XCTAssertEqual(audio.bitsPerRawSample, 24)
        XCTAssertEqual(audio.sampleRate, 48_000)
    }

    func testFLACToALACKeepsLosslessCodec() async throws {
        let source = try TestFixtures.copy("sine_44k_16bit.flac", to: directory)
        let preset = try BackendHarness.builtIn("audio.alac")
        let (outputs, _) = try await BackendHarness.convert(
            backend: AVFoundationBackend(), source: source, preset: preset, into: directory
        )
        let audio = try XCTUnwrap(try MediaAssertions.probe(try XCTUnwrap(outputs.first)).audioStreams.first)
        XCTAssertEqual(audio.codecName, "alac")
        XCTAssertEqual(audio.bitsPerRawSample, 16)
    }

    func testAACPresetHonorsRequestedBitrateSampleRateAndChannels() async throws {
        let source = try TestFixtures.copy("noise_48k_stereo.wav", to: directory)
        var preset = try BackendHarness.builtIn("audio.aac-256")
        preset.audioBitrateKbps = 96
        preset.audioSampleRate = 44_100
        preset.audioChannels = 1
        let (outputs, _) = try await BackendHarness.convert(
            backend: AVFoundationBackend(), source: source, preset: preset, into: directory
        )
        let audio = try XCTUnwrap(try MediaAssertions.probe(try XCTUnwrap(outputs.first)).audioStreams.first)
        XCTAssertEqual(audio.codecName, "aac")
        XCTAssertEqual(audio.sampleRate, 44_100)
        XCTAssertEqual(audio.channels, 1)
        let bitRate = try XCTUnwrap(audio.bitRate)
        XCTAssertEqual(Double(bitRate), 96_000, accuracy: 96_000 * 0.2)
    }

    func testAACClampsSettingsTheEncoderCannotAccept() {
        XCTAssertEqual(AVFoundationBackend.aacSampleRate(for: 96_000), 48_000)
        XCTAssertEqual(AVFoundationBackend.aacSampleRate(for: 44_100), 44_100)
        XCTAssertEqual(AVFoundationBackend.aacBitRate(requestedKbps: 320, channels: 1), 160_000)
        XCTAssertEqual(AVFoundationBackend.aacBitRate(requestedKbps: 16, channels: 2), 64_000)
    }

    func testPCMWAVStillWritesRequestedBitDepth() async throws {
        let source = try TestFixtures.copy("sine_44k_16bit.flac", to: directory)
        var preset = try BackendHarness.builtIn("audio.wav-pcm")
        preset.audioBitDepth = .bit24
        let (outputs, _) = try await BackendHarness.convert(
            backend: AVFoundationBackend(), source: source, preset: preset, into: directory
        )
        let audio = try XCTUnwrap(try MediaAssertions.probe(try XCTUnwrap(outputs.first)).audioStreams.first)
        XCTAssertEqual(audio.codecName, "pcm_s24le")
    }
}
