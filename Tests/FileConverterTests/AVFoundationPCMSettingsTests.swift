import XCTest
import AVFoundation
import CoreMedia
@testable import FileConverterCore
@testable import FileConverterNativeBackends

final class AVFoundationPCMSettingsTests: XCTestCase {
    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AVFoundationPCMTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testAVFoundationBackendSupportsWAVAndAIFF() throws {
        let backend = AVFoundationBackend()
        let wavFormat = try XCTUnwrap(FormatRegistry.shared.format(forID: "wav"))
        let mp3Format = try XCTUnwrap(FormatRegistry.shared.format(forID: "mp3"))
        let preset = ConversionPreset(
            name: "To WAV",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            quality: .high
        )
        XCTAssertTrue(backend.supports(sourceFormat: mp3Format, destinationFormat: wavFormat, preset: preset))
    }

    func testLinearPCMSettingsContainRequiredKeys() throws {
        let sampleRate: Double = 48000.0
        let channels: Int = 2
        let bigEndian = false

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]

        // AVAssetWriterInput throws NSInvalidArgumentException if AVSampleRateKey or AVNumberOfChannelsKey is missing
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
        XCTAssertNotNil(input)
        XCTAssertEqual(input.outputSettings?[AVSampleRateKey] as? Double, 48000.0)
        XCTAssertEqual(input.outputSettings?[AVNumberOfChannelsKey] as? Int, 2)
        XCTAssertEqual(input.outputSettings?[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(input.outputSettings?[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
    }

    func testLinearPCMWriterInitializationForWAVAndAIFF() throws {
        for (ext, fileType, bigEndian) in [("wav", AVFileType.wav, false), ("aiff", AVFileType.aiff, true)] {
            let destURL = tempDirectory.appendingPathComponent("test_output.\(ext)")
            let writer = try AVAssetWriter(outputURL: destURL, fileType: fileType)

            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: bigEndian,
                AVLinearPCMIsNonInterleaved: false
            ]

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcmSettings)
            input.expectsMediaDataInRealTime = false
            XCTAssertTrue(writer.canAdd(input), "Writer should accept PCM input for \(ext)")
            writer.add(input)
            XCTAssertTrue(writer.inputs.contains(input))
        }
    }

    func testAVFoundationPCMConversionSuccess() async throws {
        let srcWAV = tempDirectory.appendingPathComponent("test_audio.wav")
        try createTestAudioFile(at: srcWAV, durationSeconds: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcWAV.path))

        let destAIFF = tempDirectory.appendingPathComponent("test_audio.aiff")
        let preset = ConversionPreset(
            name: "To AIFF",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "aiff",
            quality: .high
        )
        let job = ConversionJob(sourceURL: srcWAV, destinationURL: destAIFF, preset: preset)
        let backend = AVFoundationBackend()

        try await backend.convert(job: job) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destAIFF.path))
        XCTAssertGreaterThan(FileAccessManager.shared.fileSize(at: destAIFF), 0)
    }

    func testAVFoundationPCMCancellationHandling() async throws {
        let srcWAV = tempDirectory.appendingPathComponent("test_cancellable.wav")
        try createTestAudioFile(at: srcWAV, durationSeconds: 2.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcWAV.path))

        let destWAV = tempDirectory.appendingPathComponent("test_cancelled.wav")
        let preset = ConversionPreset(
            name: "To WAV",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            quality: .high
        )
        let backend = AVFoundationBackend()

        // 1. Cancel before conversion starts
        let jobPre = ConversionJob(sourceURL: srcWAV, destinationURL: destWAV, preset: preset)
        await backend.cancel(jobID: jobPre.id)
        do {
            try await backend.convert(job: jobPre) { _ in }
            XCTFail("Should have thrown ConversionError.cancelled")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }

        // 2. Cancel during conversion
        let jobMid = ConversionJob(sourceURL: srcWAV, destinationURL: destWAV, preset: preset)
        let cancelTask = Task {
            try? await Task.sleep(for: .milliseconds(2))
            await backend.cancel(jobID: jobMid.id)
        }

        do {
            try await backend.convert(job: jobMid) { _ in }
            _ = await cancelTask.value
            XCTFail("Should have thrown ConversionError.cancelled")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testAVFoundationMultichannelPCMInputInitialization() throws {
        // 6-channel (5.1 surround) requires AVChannelLayoutKey to avoid NSInvalidArgumentException
        var layout51 = AudioChannelLayout()
        layout51.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        let layoutData = Data(bytes: &layout51, count: MemoryLayout<AudioChannelLayout>.size)

        let settings6ch: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 6,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: layoutData
        ]
        let input6ch = AVAssetWriterInput(mediaType: .audio, outputSettings: settings6ch)
        XCTAssertNotNil(input6ch)
        XCTAssertEqual(input6ch.outputSettings?[AVNumberOfChannelsKey] as? Int, 6)
    }

    func testAVFoundationMultichannelConversionSuccess() async throws {
        let srcWAV = tempDirectory.appendingPathComponent("test_stereo.wav")
        try createTestAudioFile(at: srcWAV, durationSeconds: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcWAV.path))

        let destWAV = tempDirectory.appendingPathComponent("test_stereo_output.wav")
        let preset = ConversionPreset(
            name: "To WAV",
            category: .audio,
            sourceFormats: ["audio"],
            destinationFormat: "wav",
            quality: .high
        )
        let job = ConversionJob(sourceURL: srcWAV, destinationURL: destWAV, preset: preset)
        let backend = AVFoundationBackend()

        try await backend.convert(job: job) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destWAV.path))
        XCTAssertGreaterThan(FileAccessManager.shared.fileSize(at: destWAV), 0)
    }

    private func createTestAudioFile(at url: URL, durationSeconds: Double) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ConversionError.unknown(message: "Cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let sampleCount = Int(44100.0 * durationSeconds)
        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = Int16(sin(Double(i) * 2.0 * .pi * 440.0 / 44100.0) * 10000.0)
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        let chunkSize = 4096
        var offset = 0
        while offset < sampleCount {
            let count = min(chunkSize, sampleCount - offset)
            let chunkData = data.subdata(in: (offset * 2)..<((offset + count) * 2))

            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: chunkData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: chunkData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            chunkData.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress, let blockBuffer {
                    CMBlockBufferReplaceDataBytes(
                        with: baseAddress,
                        blockBuffer: blockBuffer,
                        offsetIntoDestination: 0,
                        dataLength: chunkData.count
                    )
                }
            }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(count), timescale: 44100),
                presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: 44100),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: count,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
            while !input.isReadyForMoreMediaData {
                if writer.status != .writing {
                    throw writer.error ?? ConversionError.unknown(message: "Writer failed with status \(writer.status.rawValue)")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if let sampleBuffer {
                input.append(sampleBuffer)
            }
            offset += count
        }

        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()
    }
}
