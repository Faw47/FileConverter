import XCTest
@testable import FileConverterCore

final class EffectivePresetResolverTests: XCTestCase {

    private func makeCustomPreset(
        outputPolicy: OutputDirectoryPolicy = .sameAsSource,
        overwritePolicy: OverwritePolicy = .appendNumber,
        filenamePattern: String = "{name}",
        inheritance: PresetInheritance
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
            isBuiltIn: false,
            inheritance: inheritance
        )
    }

    private let globals = ConversionDefaults(
        outputDirectoryPolicy: .downloads,
        overwritePolicy: .ask,
        filenamePattern: "{name}_converted",
        preserveCreationDate: true,
        preserveModificationDate: false,
        removeLocationData: true
    )

    func testInheritedValuesComeFromGeneralSettings() {
        let preset = makeCustomPreset(
            outputPolicy: .sourceSubfolder(subfolderName: "Out"),
            overwritePolicy: .overwrite,
            filenamePattern: "{name}_mine",
            inheritance: .inheritAll
        )
        let resolved = EffectivePresetResolver.resolve(preset: preset, defaults: globals)
        XCTAssertEqual(resolved.outputDirectoryPolicy.value, .downloads)
        XCTAssertEqual(resolved.outputDirectoryPolicy.provenance, .globalDefault)
        XCTAssertEqual(resolved.overwritePolicy.value, .ask)
        XCTAssertEqual(resolved.filenamePattern.value, "{name}_converted")
        XCTAssertTrue(resolved.preserveCreationDate.value)
        XCTAssertFalse(resolved.preserveModificationDate.value)
        XCTAssertTrue(resolved.removeLocationData.value)
    }

    func testPresetValuesWinWhenNotInherited() {
        var preset = makeCustomPreset(
            outputPolicy: .sameAsSource,
            overwritePolicy: .appendNumber,
            filenamePattern: "{name}",
            inheritance: .inheritNone
        )
        preset.preserveCreationDate = false
        preset.preserveModificationDate = true
        preset.removeLocationData = false
        let resolved = EffectivePresetResolver.resolve(preset: preset, defaults: globals)
        // "Same folder as source" is an explicit choice now, not a sentinel.
        XCTAssertEqual(resolved.outputDirectoryPolicy.value, .sameAsSource)
        XCTAssertEqual(resolved.outputDirectoryPolicy.provenance, .presetOverride)
        XCTAssertEqual(resolved.overwritePolicy.value, .appendNumber)
        XCTAssertEqual(resolved.filenamePattern.value, "{name}")
        XCTAssertFalse(resolved.preserveCreationDate.value)
        XCTAssertTrue(resolved.preserveModificationDate.value)
        XCTAssertFalse(resolved.removeLocationData.value)
    }

    func testCollisionOverrideBeatsEverything() {
        let preset = makeCustomPreset(overwritePolicy: .skip, inheritance: .inheritAll)
        let resolved = EffectivePresetResolver.resolve(preset: preset, defaults: globals, collisionOverride: .overwrite)
        XCTAssertEqual(resolved.overwritePolicy.value, .overwrite)
        XCTAssertEqual(resolved.overwritePolicy.provenance, .explicitContext)
    }

    func testEachFlagIsIndependent() {
        var inheritance = PresetInheritance.inheritNone
        inheritance.collisionPolicy = true
        let preset = makeCustomPreset(
            outputPolicy: .sameAsSource,
            overwritePolicy: .overwrite,
            inheritance: inheritance
        )
        let resolved = EffectivePresetResolver.resolve(preset: preset, defaults: globals)
        XCTAssertEqual(resolved.outputDirectoryPolicy.value, .sameAsSource)
        XCTAssertEqual(resolved.overwritePolicy.value, .ask)
    }

    func testBuiltInsFollowGeneralSettingsIncludingDates() throws {
        let builtIn = try XCTUnwrap(BuiltInPresets.makeDefaultPresets().first)
        XCTAssertEqual(builtIn.inheritance, .inheritAll)
        var noDates = globals
        noDates.preserveCreationDate = false
        let resolved = EffectivePresetResolver.resolve(preset: builtIn, defaults: noDates)
        XCTAssertFalse(resolved.preserveCreationDate.value, "the General date toggle must reach built-in presets")
        XCTAssertEqual(resolved.overwritePolicy.value, .ask)
    }

    func testLegacyRulesReproduceOldBehavior() {
        var custom = makeCustomPreset(
            outputPolicy: .sameAsSource,
            overwritePolicy: .ask,
            filenamePattern: "{name}_x",
            inheritance: .inheritAll
        )
        custom.inheritance = nil
        let legacy = custom.resolvedInheritance
        XCTAssertTrue(legacy.outputLocation)
        XCTAssertFalse(legacy.filenamePattern)
        XCTAssertTrue(legacy.collisionPolicy)
        XCTAssertFalse(legacy.creationDate)

        var editedBuiltIn = BuiltInPresets.makeDefaultPresets()[0]
        editedBuiltIn.inheritance = nil
        editedBuiltIn.outputDirectoryPolicy = .sourceSubfolder(subfolderName: "Mine")
        XCTAssertFalse(editedBuiltIn.resolvedInheritance.outputLocation, "an edited built-in keeps its own folder")
        XCTAssertTrue(editedBuiltIn.resolvedInheritance.collisionPolicy)
    }

    func testAppliedPresetCannotReinherit() {
        let preset = makeCustomPreset(inheritance: .inheritAll)
        let resolved = EffectivePresetResolver.resolve(preset: preset, defaults: globals)
        let applied = resolved.applied(to: preset)
        XCTAssertEqual(applied.inheritance, .inheritNone)
        let again = EffectivePresetResolver.resolve(preset: applied, defaults: ConversionDefaults())
        XCTAssertEqual(again.outputDirectoryPolicy.value, .downloads)
        XCTAssertEqual(again.overwritePolicy.value, .ask)
        XCTAssertEqual(again.filenamePattern.value, "{name}_converted")
    }

    func testDefaultsMigrateLegacyTimestampToggle() throws {
        let suite = "ResolverTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ConversionDefaults.load(from: defaults).preserveCreationDate)
        XCTAssertFalse(ConversionDefaults.load(from: defaults).preserveModificationDate)
        XCTAssertTrue(ConversionDefaults.load(from: defaults).removeLocationData)

        defaults.set(false, forKey: ConversionDefaults.Keys.legacyPreserveTimestamps)
        XCTAssertFalse(ConversionDefaults.load(from: defaults).preserveCreationDate)
        defaults.set(true, forKey: ConversionDefaults.Keys.preserveCreationDate)
        XCTAssertTrue(ConversionDefaults.load(from: defaults).preserveCreationDate)
    }
}
