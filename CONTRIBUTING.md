# Contributing to File Converter

File Converter is a macOS Swift app with a Finder Sync extension, native conversion backends, optional external tools, and a shared package test suite. Focused bug reports, reproducible conversion cases, documentation fixes, and small pull requests are welcome.

## Before you start

1. Search the existing issues before opening a new one.
2. For a bug, include the macOS version, app version or commit, source and destination formats, entry point, and reproducible steps.
3. Never include private filenames, security-scoped bookmark data, IPC keys, credentials, or unredacted logs.
4. Read [SECURITY.md](SECURITY.md) before changing file access, subprocess execution, IPC, or output finalization.

## Local setup

Requirements:

- macOS 14.0 or newer
- Xcode 16 or newer (Swift 6 toolchain)
- XcodeGen only when regenerating the project from `project.yml`
- Homebrew only for optional conversion tools; `brew install ffmpeg ghostscript` before running the media tests

Clone the repository and verify the package targets:

```bash
git clone https://github.com/Faw47/FileConverter.git
cd FileConverter
swift build
swift test
```

Tests that inspect real media outputs need fixtures. Generate them once (they are git-ignored); tests whose fixture or tool is missing are skipped, not failed:

```bash
Scripts/make_test_fixtures.sh
```

### Trying a build in Finder

macOS uses only one registered copy of the app for Open With, Services, and the Finder menu. With several copies on disk (an installed one, Xcode builds, `dist/` backups) Finder may load an old extension. After packaging, make your build the one in use:

```bash
Scripts/package_app.sh --no-backup Debug
```

```bash
Scripts/use_build.sh
```

`use_build.sh` unregisters every other copy, including one in /Applications; run it with that copy's path to switch back. `package_app.sh` keeps only the most recent previous build in `dist/`; `--no-backup` keeps none.

After changing files in `project.yml` or adding source files, run `xcodegen generate` and commit the project; CI fails when it is out of date.

The package tests cover the core conversion model, format detection, preset behavior, output naming, external-process safety, Finder contracts, and architecture boundaries. Use the Xcode project for the host app and Finder extension.

## Project boundaries

- `FileConverterContracts` contains shared request, snapshot, and IPC types.
- `FileConverterCore` contains format detection, presets, validation, naming, queue, and file-access policy.
- `FileConverterNativeBackends` contains Apple-framework conversion paths.
- `FileConverterExternalBackends` contains integrations with optional tools.
- `FileConverterFinderSupport` contains the Finder catalog and request client.
- `FileConverterFinderSync` contains the embedded Finder extension.

Keep the Finder extension independent from `FileConverterCore` and conversion backends. The architecture tests enforce this boundary.

## Making a change

Prefer a narrow change with a test that demonstrates the behavior. When adding or changing a conversion recipe:

1. Update the format or preset registry.
2. Update backend capability checks and output requirements as needed.
3. Add or update tests for the source, destination, unavailable-tool, and collision cases.
4. Update the README when the supported format or installation behavior changes.

When changing `project.yml`, regenerate and review `FileConverter.xcodeproj`:

```bash
xcodegen generate
git diff --check
```

Do not hand-edit generated project settings unless the change is intentional and reproducible from the project definition.

## Pull requests

Pull requests should explain the user-visible result, include the verification performed, and keep unrelated formatting or refactors out of the diff. UI changes should include a screenshot when practical. Security-sensitive changes should explain the new boundary and the tests that protect it.

The CI workflow runs `swift build` and `swift test --parallel` on macOS for pushes and pull requests. Local tests are still important for faster feedback, especially for Finder and external-tool behavior that CI cannot fully exercise.

## External tools

Optional tools are discovered at runtime and must be invoked with discrete arguments. Do not add shell interpolation or assume a Homebrew path is the only valid installation path. Keep tool failures actionable and make unavailable capabilities visible through diagnostics rather than silently selecting a different backend.

## License and contributions

The repository does not currently publish a license file. Do not assume that code may be redistributed or relicensed. If a contribution depends on specific licensing terms, raise that before opening a pull request.
