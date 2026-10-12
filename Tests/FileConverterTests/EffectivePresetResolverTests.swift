import XCTest
@testable import FileConverterCore

final class EffectivePresetResolverTests: XCTestCase {

    private func makeBasePreset(
        outputPolicy: OutputDirectoryPolicy = .sameAsSource,
        overwritePolicy: OverwritePolicy = .ask,
        filenamePattern: String = "{name}"
    ) -> ConversionPreset {
        ConversionPreset(
            id: UUID(),
            name: "Test Preset",
            category: .audio,
            sourceFormats: ["wav"],
            destinationFormat: "mp3",
            videoCodec: .none,
            audioCodec: .mp3,
            quality: .high,
            outputDirectoryPolicy: outputPolicy,
            filenamePattern: filenamePattern,
            overwritePolicy: overwritePolicy,
            isBuiltIn: false
        )
    }

    func testResolveOutputDirectoryInheritance() {
        // Case 1: Preset specifies sameAsSource; global specifies downloads -> inherits global
        let preset1 = makeBasePreset(outputPolicy: .sameAsSource)
        let resolved1 = EffectivePresetResolver.resolve(
            preset: preset1,
            globalOutputPolicy: .downloads
        )
        XCTAssertEqual(resolved1.outputDirectoryPolicy.value, .downloads)
        XCTAssertEqual(resolved1.outputDirectoryPolicy.provenance, .globalDefault)

        // Case 2: Preset overrides output directory (e.g. sourceSubfolder) -> preset overrides global
        let subfolderPolicy = OutputDirectoryPolicy.sourceSubfolder(subfolderName: "Converted")
        let preset2 = makeBasePreset(outputPolicy: subfolderPolicy)
        let resolved2 = EffectivePresetResolver.resolve(
            preset: preset2,
            globalOutputPolicy: .downloads
        )
        XCTAssertEqual(resolved2.outputDirectoryPolicy.value, subfolderPolicy)
        XCTAssertEqual(resolved2.outputDirectoryPolicy.provenance, .presetOverride)
    }

    func testResolveOverwritePolicyInheritance() {
        // Case 1: Explicit collision override takes top precedence
        let preset = makeBasePreset(overwritePolicy: .appendNumber)
        let resolvedOverride = EffectivePresetResolver.resolve(
            preset: preset,
            collisionOverride: .overwrite,
            globalOverwritePolicy: .ask
        )
        XCTAssertEqual(resolvedOverride.overwritePolicy.value, .overwrite)
        XCTAssertEqual(resolvedOverride.overwritePolicy.provenance, .explicitContext)

        // Case 2: Preset has .ask, global has .appendNumber -> inherits global
        let presetAsk = makeBasePreset(overwritePolicy: .ask)
        let resolvedGlobal = EffectivePresetResolver.resolve(
            preset: presetAsk,
            collisionOverride: nil,
            globalOverwritePolicy: .appendNumber
        )
        XCTAssertEqual(resolvedGlobal.overwritePolicy.value, .appendNumber)
        XCTAssertEqual(resolvedGlobal.overwritePolicy.provenance, .globalDefault)

        // Case 3: Preset specifies .overwrite explicitly -> preset overrides
        let presetExplicit = makeBasePreset(overwritePolicy: .overwrite)
        let resolvedPreset = EffectivePresetResolver.resolve(
            preset: presetExplicit,
            collisionOverride: nil,
            globalOverwritePolicy: .appendNumber
        )
        XCTAssertEqual(resolvedPreset.overwritePolicy.value, .overwrite)
        XCTAssertEqual(resolvedPreset.overwritePolicy.provenance, .presetOverride)
    }

    func testResolveFilenamePatternInheritance() {
        // Case 1: Preset has default "{name}"; global has custom pattern -> inherits global
        let presetDefault = makeBasePreset(filenamePattern: "{name}")
        let resolvedGlobal = EffectivePresetResolver.resolve(
            preset: presetDefault,
            globalFilenamePattern: "{name}_converted"
        )
        XCTAssertEqual(resolvedGlobal.filenamePattern.value, "{name}_converted")
        XCTAssertEqual(resolvedGlobal.filenamePattern.provenance, .globalDefault)

        // Case 2: Preset has custom pattern -> preset overrides global
        let presetCustom = makeBasePreset(filenamePattern: "{name}_custom_{date}")
        let resolvedPreset = EffectivePresetResolver.resolve(
            preset: presetCustom,
            globalFilenamePattern: "{name}_converted"
        )
        XCTAssertEqual(resolvedPreset.filenamePattern.value, "{name}_custom_{date}")
        XCTAssertEqual(resolvedPreset.filenamePattern.provenance, .presetOverride)
    }

    func testResolveOverwritePolicyInheritanceForBuiltInPreset() {
        var builtIn = BuiltInPresets.makeDefaultPresets().first!
        builtIn.overwritePolicy = .appendNumber
        XCTAssertTrue(builtIn.isBuiltIn)

        let resolved = EffectivePresetResolver.resolve(
            preset: builtIn,
            collisionOverride: nil,
            globalOverwritePolicy: .overwrite
        )
        XCTAssertEqual(resolved.overwritePolicy.value, .overwrite)
        XCTAssertEqual(resolved.overwritePolicy.provenance, .globalDefault)
    }
}
