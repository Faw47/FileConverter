import XCTest
@testable import FileConverterCore
import FileConverterNativeBackends
@testable import FileConverterExternalBackends

final class WebPEncodingTests: XCTestCase {
    func testRegistryDoesNotClaimNativeWebPEncoding() throws {
        let webp = try XCTUnwrap(FormatRegistry.shared.format(forID: "webp"))
        XCTAssertFalse(webp.nativeEncoderAvailable)
        XCTAssertFalse(NativeImageCodecs.canEncode(webp), "macOS ImageIO is not expected to write WebP")
    }

    func testNativeEncoderFlagsMatchImageIOForEveryImageFormat() {
        for format in FormatRegistry.shared.allFormats() where format.category == .image && format.nativeEncoderAvailable {
            XCTAssertTrue(NativeImageCodecs.canEncode(format), "\(format.id) is marked natively encodable but ImageIO cannot write it")
        }
    }

    func testImageIOBackendDoesNotSupportWebPOutput() throws {
        let png = try XCTUnwrap(FormatRegistry.shared.format(forID: "png"))
        let webp = try XCTUnwrap(FormatRegistry.shared.format(forID: "webp"))
        let preset = try BackendHarness.builtIn("image.webp")
        XCTAssertFalse(ImageIOBackend().supports(sourceFormat: png, destinationFormat: webp, preset: preset))
    }

    func testWebPPresetsAreNotPinnedToImageIO() throws {
        XCTAssertEqual(try BackendHarness.builtIn("image.webp").backend, .auto)
        XCTAssertEqual(try BackendHarness.builtIn("image.webp-lossless").backend, .auto)
        XCTAssertEqual(try BackendHarness.builtIn("image.avif").backend, .auto)
    }

    func testPNGToWebPResolvesToImageMagickAndProducesWebP() async throws {
        guard ExternalToolDiscovery.shared.executablePath(for: "magick") != nil else {
            throw XCTSkip("ImageMagick is not installed.")
        }
        let directory = try BackendHarness.makeTempDirectory("WebP")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try TestFixtures.copy("transparent_256.png", to: directory)

        let resolver = BackendResolver(backends: NativeBackendCatalog.makeBackends() + ExternalBackendCatalog.makeBackends())
        for key in ["image.webp", "image.webp-lossless"] {
            let preset = try BackendHarness.builtIn(key)
            let job = ConversionJob(sourceURL: source, preset: preset)
            let backend = try resolver.resolveBackend(for: job)
            XCTAssertEqual(backend.backendType, .imageMagick, key)

            let (outputs, _) = try await BackendHarness.convert(
                backend: backend, source: source, preset: preset, into: directory, baseName: key
            )
            let info = try ImageAssertions.info(try XCTUnwrap(outputs.first))
            XCTAssertEqual(info.typeIdentifier, "org.webmproject.webp", key)
            XCTAssertEqual(info.width, 256, key)
        }
    }

    func testStoredBuiltInWithOldImageIOBackendIsUpgraded() throws {
        var stored = try BackendHarness.builtIn("image.webp")
        stored.backend = .imageIO
        stored.factoryRevision = nil
        let upgraded = BuiltInPresetUpgrades.upgrade(stored)
        XCTAssertEqual(upgraded.backend, .auto)
        XCTAssertEqual(upgraded.factoryRevision, BuiltInPresetUpgrades.currentRevision)
    }

    func testUserEditedBuiltInIsNotOverwrittenByUpgrade() throws {
        var stored = try BackendHarness.builtIn("image.webp")
        stored.backend = .imageMagick
        stored.factoryRevision = nil
        XCTAssertEqual(BuiltInPresetUpgrades.upgrade(stored).backend, .imageMagick)
    }
}
