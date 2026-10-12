# File Converter Release Decision Record (RDR)

**Version**: 1.0.0 (Hardened)  
**Date**: 2026-09-21  
**Status**: Approved / Ready for Deployment  
**Target Platform**: macOS 14.0+ (Universal: Apple Silicon arm64 & Intel x86_64)

---

## 1. Executive Summary

This Release Decision Record confirms the successful execution, adversarial code review reconciliation, and comprehensive qualification of the 11-phase reliability and security hardening plan (`plan/refactor-file-converter-reliability-1.md`). 

All primary safety invariants and secondary review findings have been verified through automated regression suites (325 tests across host application and Finder extension components), static architectural boundary checks, and production archive builds (`Debug` and `Release`) verified by Apple codesigning tooling.

---

## 2. Invariant Verification & Architectural Guarantees

| Area | Former Vulnerability | Hardened Invariant & Mechanism | Verification Evidence |
| :--- | :--- | :--- | :--- |
| **Presets & Security** | Corrupt/empty primary file overwrote user library; arbitrary JSON keys injected process flags; sensitive local paths leaked. | Fail-closed `PresetStoreState`; immutable inert opaque fields; typed/validated backend options (`isAllowlistedFFmpegOption`); privacy-preserving sanitization on export. | `PresetEngineTests`, `PresetImportExportTests`, `PresetCorruptionAndRecoveryTests` (100% pass) |
| **Output & File Safety** | Race conditions during output file creation; stale collision decisions caused unintended overwrites. | Canonical destination keys (`CanonicalDestinationKey`); coordinated commit via `NSFileCoordinator` with fingerprint revalidation; keep-both collision retry loops with bounded backoff. | `OutputNamingTests`, `ConversionQueueTests` (100% pass) |
| **Process Supervision** | Orphaned external converter child processes; unbounded execution. | `ExternalProcessSupervisor` wrapping Darwin `proc_listpids`; timed SIGTERM → SIGKILL escalation; dead-pipe handling with bounded diagnostic buffers. | `ExternalBackendProcessTests` (100% pass) |
| **Memory & Resources** | Out-of-memory crashes on giant images/PDFs; main-thread lockups during text-to-PDF. | ImageIO downsampling budgets; PDFKit 1000-page thresholds with autorelease pools; off-main Core Text / Core Graphics pagination. | `PDFKitBackendTextRenderingTests`, `PDFWorkflowTests` (100% pass) |
| **Finder Extension IPC** | Lost requests on crash; unauthenticated replay; race conditions; unbounded `Rejected/` directory growth. | Durable journaled admissions before IPC receipt generation; host app enclosing-`.app` derivation with ambiguity diagnostics; `sweepRejectedRequests` enforcing age/count retention limits. | `FinderIPCDrainTests`, `FinderHostResolverTests`, `FinderMenuCatalogTests` (100% pass) |
| **PDF Workflows & Round-Trip** | PDF compress dialog overwrote preset options with hardcoded defaults; split dialog forced source subfolders and lacked per-file ranges. | Compress dialog initializes `@State` from preset and preserves untouched policies; split dialog supports per-file custom ranges and preserves preset directory policies. | `AccessibilityAuditTests`, `PDFWorkflowTests` (100% pass) |
| **Queue UX & Accessibility** | Conflicting modal sheets; lost dropped files; missing keyboard navigation; missing accessibility labels. | `WorkflowPresentationCoordinator` providing central FIFO modal presentation; full keyboard navigation (Return, ⌘R, Delete, Esc); comprehensive accessibility labels/hints/values across settings, dialogs, queue, and collision sheets; interactive interrupted-conversion recovery banner. | `WorkflowPresentationCoordinatorTests`, `AccessibilityAuditTests`, `QoLBugsRegressionTests` (100% pass) |
| **Performance & Caching** | Redundant disk I/O and ffprobe spawning on every UI redraw. | `SourceFingerprint` with `DetectionSnapshot` caching; actor-isolated `MediaProbeCache` with automated mutation eviction; `os_signpost` telemetry without privacy leakage. | `SourceFingerprintTests` (100% pass) |
| **Architecture Boundaries** | Accidental leaks of `Process()` into Core or forbidden modules into FinderSync. | Static AST/source boundary tests ensuring strict separation between Core, FinderSupport, and ExternalBackends. | `ArchitectureBoundaryTests` (100% pass) |

---

## 3. Automated Test Results

### SwiftPM Test Suite (`swift test`)
- **FileConverterTests**: 310 executed, 0 failures, 0 unexpected.
- **FileConverterFinderSupportTests**: 15 executed, 0 failures, 0 unexpected.
- **Total Executed**: 325 tests passing (0 failures).

### Xcode Test Suite (`xcodebuild test`)
- Scheme `FileConverter` on destination `platform=macOS`
- **FileConverterTests**: 310 executed, 0 failures.
- **FileConverterFinderSupportTests**: 15 executed, 0 failures.
- Result: `** TEST SUCCEEDED **` (325/325 passing).

### Static Boundary & Concurrency Tests
- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) validated with zero concurrency warnings.
- Architecture boundary tests verified zero unmanaged `Process()` calls in `FileConverterCore`.
- Finder extension imports strictly isolated from Core, NativeBackends, and ExternalBackends.

---

## 4. Application Packaging & Codesign Verification

Packaged via `./Scripts/package_app.sh Release`:
- **Artifact**: `dist/File Converter.app`
- **Embedded Extension**: `dist/File Converter.app/Contents/PlugIns/FileConverterFinderExtension.appex`
- **Debug Symbols**: `dist/File Converter.app.dSYM`
- **Metadata Linting**:
  - App `Info.plist`: OK
  - Finder Extension `Info.plist`: OK (`NSExtensionAttributes` verified, principal class module-qualified and verified via `nm` demangle)
- **Codesigning**:
  - Apple Development signed with local entitlement profiles (`FileConverterAppLocal.entitlements`, `FileConverterFinderLocal.entitlements`).
  - Strict verification: `codesign --verify --deep --strict --verbose=2 "dist/File Converter.app"` passed.

---

## 5. Residual Risks & Rollout Notes

1. **System Requirements**: macOS 14.0 or newer.
2. **Third-Party Backends**: External tools (`ffmpeg`, `magick`, `soffice`, `gs`) remain optional dependencies installed via Homebrew or system paths; app gracefully falls back and reports missing capabilities without crashing.
3. **Distribution**: The distributable bundle is isolated in `dist/`. Per safety policy, installation into `/Applications` is left to deployment automation or explicit user action.
