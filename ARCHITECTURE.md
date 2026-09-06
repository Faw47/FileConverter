# Architecture & Technical Design

This document details the architectural design, subsystem relationships, and data flow of **File Converter for macOS**. The app is one host application with an embedded Finder extension; optional external backends are capability-gated at runtime.

---

## 1. System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Finder.app Context                             │
│  FIFinderSync (FileConverterFinderExtension) `io.fileconverter.app.findersync` │
│  • Container: configured local IPC path for unsigned artifacts; App Group when no local override is present                         │
│  • Snapshot: FileConverterContracts + FinderSupport `FinderMenuSnapshot` │
│    validated by `FinderMenuCatalog` (size/dupe/edition, ≤100 sources)    │
│  • Handoff: ephemeral bookmark `ConversionRequest` → HMAC envelope        │
│    `FinderRequestClient.send` → Pending file                             │
└──────────────────────────────┬──────────────────────────────────────────┘
                                │ Pending/Processing/Rejected + Darwin notification
                                │  (authenticated, time-boxed, duplicate-safe)
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                             File Converter.app                           │
│  io.fileconverter.app • `FileConverter` + `FileConverterFinderExtension` │
│  ConversionCoordinator (actor, serialized drain, dedup) ──► ConversionQueue│
│     validation: PresetValidator + BackendResolver.evaluate                │
│                  (source, encoder, and tool availability)                │
│                        @MainActor ConversionQueue                         │
│     • Backend resolved before any directory/temp-file creation             │
│     • Atomic commit: finalizing non-cancellable; replaceItemAt/revalidate │
│                ┌─────────────────┴─────────────────┐                     │
│                ▼                                   ▼                     │
│        BackendResolver                      OutputNamingEngine            │
│     [ImageIO, PDFKit, AVFoundation] + [FFmpeg, ImageMagick, LibreOffice, Ghostscript] │
│   ExternalProcessRunner (bounded drains, graceful termination, staging)  │
│   SecurityScopedLease (ephemeral bookmark fallback, still balanced)       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Module Boundaries

| Module | Dependencies | Linked Into |
|---|---|---|
| **FileConverterContracts** | none | host, Finder, backends, Core |
| **FileConverterCore** | Contracts | host, backends, tests |
| **FileConverterNativeBackends** | Core | host |
| **FileConverterExternalBackends** | Core | host (optional capabilities) |
| **FileConverterFinderSupport** | Contracts | host (Settings status) + Finder extension |
| **FileConverterFinderSync** | Contracts + FinderSupport | Finder appex |

* Finder extension never imports `FileConverterCore`/`NativeBackends`/`ExternalBackends`. The host registers both catalogs, while `BackendResolver` reports a preset as usable only when its backend and required encoder/tool are available. `FinderSupport` supplies live Finder status in Settings.
* Enforced by `Package.swift` deps and `ArchitectureBoundaryTests` (Core has no `Process`, Finder has no `FileConverterCore`).

## 3. Settings

* **`AppSettings`** (`ObservableObject`, `MainActor`): typed `UserDefaults` store with registration, clamping, and reset. Owns output/conflict/filename defaults for new presets, notification + reveal switches, and `maxConcurrentJobs` (pushes into `ConversionQueue`). Every control writes here — no dead toggles.
* **`AppState.SettingsTab`**: 5 tabs (General, Presets, External Tools, Performance, Finder). Dead Video/Audio cases removed. Selection persists via `fc.selectedSettingsTab`; `openSettings(tab:)` is the single entry point (menu, toolbar, `fileconverter://settings?tab=` with fuzzy matching).
* **`SettingsView`**: Native `TabView` Settings scene with the standard five toolbar panes (General, Presets, External Tools, Performance, Finder), minimum window size, and system Settings commands such as Cmd-,.
* **Presets**: sidebar search + category filter + availability badges (`Off`, `Needs tool` via `supportsAnySource`), context menu, Delete key, explicit Save/Revert editor with validation (non-empty names, known writable extension via `FormatRegistry`, non-empty pattern, single-folder subfolder rule), a discard guard when switching away from an edited draft, live filename preview, custom-folder bookmark picker, Export/Import (merge or replace) with error alerts, Reset with confirmation. New customs inherit `AppSettings` defaults.
* **Performance**: stepper 1…16 bound to `AppSettings` (live `ConversionQueue` sync), effective concurrency display (thermal throttling to 1 under Serious/Critical), system-default reset, live queue counts.
* **Tools**: startup and manual scans run in `Task.detached` without holding the discovery cache lock; FFmpeg encoder probing completes before optional presets are republished, while the UI remains responsive. The pane shows a sorted list, copyable install commands, and last-checked status.
* **Finder**: live `FinderRequestClient.isReady()` + snapshot readiness + snapshot age, extension-enabled status, reveal IPC folder, relaunch Finder, and a link to Apple's extension-management UI.
* **Queue wiring**: `ConversionQueue` reads `maxConcurrentJobs` on init, exposes `current/effectiveMaxConcurrency`, gates notifications on `enableNotifications` (defaults true), coalesces progress updates, pauses Ask collisions in a batch conflict sheet, and posts `.fileConverterBatchCompleted` with all output URLs; `AppState` reveals them when `revealInFinder` is on.

---

## 4. Component Breakdown

### 4.1 FileConverterContracts + FileConverterFinderSupport
* **`FinderMenuSnapshot`**: versioned, size-bounded (`≤1 MiB`), capability-filtered host export. Validates duplicate aliases, preset/format limits, and `compatibleFormatIDs` subset; load retains last-known-good on corruption/oversize.
* **`FinderMenuCatalog`**: snapshot-only classification, directory-path short-circuit, source-count cap, edition-gated.
* **`FinderRequestClient` / `IPCChannels`**: HMAC-SHA256 envelope, `ConversionRequestLimits` (100 files, 1 MiB bookmark), Pending→Processing→Rejected lifecycle with 60 s claim lease, crash recovery, duplicate rejection, atomic claim ownership, and drain serialization.

### 4.2 FileConverterCore
* **`FormatRegistry`**: canonical alias ownership, atomic duplicate rejection, MOV/QTA ownership fixes.
* **`FormatDetector`**: content-first magic bytes, filesystem UTType, then extension fallback; zero-byte and directory inputs are explicit validation failures.
* **`PresetStore`**: schema-versioned document with legacy-array migration, five rotating backups, built-in identity via `BuiltInPresetIdentity`, ordered merge preserving edited fields/enabled/sort, shared-container path (`IPCConfiguration.sharedContainerURL`), read-only extension guard, corrupt-file preservation, and retryable `publishFinderMenuSnapshot` gated on successful load. Built-ins disable/restore rather than disappear.
* **`PresetValidator`**: resolver-aware intersection — a preset is compatible only if enabled, source-compatible **and** `BackendResolver.canResolve` for every selected file.
* **`ConversionQueue`**: `@MainActor` state, nonisolated `executeJob`. Backend resolved before output reservation; multi-output requirements are reserved as a unit; concurrent destinations reserved via `reservedOutputURLs`; `clearCompleted` never releases active leases; `finalizing` is a non-cancellable commit boundary with `replaceIfNewer` revalidation and `replaceItemAt` atomic commit. Batch counts and completion notifications are scoped to the submitted batch.
* **`OutputNamingEngine`**: per-preset policy, directory-traversal guard, custom-folder lease requirement (no fallback path), numbered collision with in-flight reservation, atomic commit via `replaceItemAt`/`moveItem` with directory guard.
* **`BackendResolver`**: content-first source resolution through `FormatDetector`, ordered registry, `canResolve`/`supportsAnySource`, `backendUnavailable`/`incompatibleConversion` errors, delegated cancel.
* **`SecurityScopedLease` / `FileAccessManager`**: `withSecurityScope` first with ephemeral fallback, balanced `start/stopAccessingSecurityScopedResource`, stale-rejection, destination-lease held for full job lifetime.

### 4.3 Conversion Backends
* **Native (`FileConverterNativeBackends`)**: `ImageIOBackend`, `PDFKitBackend` (text/RTF/HTML rendering and one-image-per-PDF-page output), and `AVFoundationBackend` (AV container export plus PCM WAV/AIFF via reader/writer).
* **External (`FileConverterExternalBackends`)**: `FFmpegBackend` (ffprobe + encoder probing), `ImageMagickBackend`, `GhostscriptBackend`, `LibreOfficeBackend` (per-job staging/output/profile + throwing move). All use `ExternalProcessRunner`/`ExternalProcessRegistry`: bounded concurrent stdout/stderr drains, launch-state guard, graceful `terminate`→`SIGKILL` escalation, full-lifetime registration, cancellation coupling, and isolated LibreOffice profiles.

### 4.4 Finder Sync Extension
* `FIFinderSync` monitoring `/` with snapshot-only menu; setup/readiness gate requiring both keychain and snapshot; `listenForPresetChanges` via snapshot Darwin notification; `conversionPresetSelected` builds ephemeral bookmarks and sends via `FinderRequestClient`. The root monitor remains deliberate for global Finder-menu coverage.

### 4.5 Signing & Local IPC
* **Local artifact**: `File Converter.app` (`io.fileconverter.app`) embeds `FileConverterFinderExtension` (`io.fileconverter.app.findersync`). `Scripts/package_app.sh` archives a universal app and matching dSYM, then signs the nested Finder extension with the local sandbox/file entitlements (preferring an Apple Development identity and falling back to ad-hoc) and seals the app before copying them to `dist`; it does not notarize, publish, register the `dist` copy, or enable the extension. Xcode may index its temporary archive product with Launch Services during the standard archive action.
* **IPC container selection**: `FILE_CONVERTER_LOCAL_IPC_PATH=/Library/Application Support/FileConverter/LocalIPC/native/` explicitly selects the local artifact container for both the host and Finder extension. It is resolved relative to the current user's home via `getpwuid`, with `..` rejected. Builds that omit this override use App Group `group.io.fileconverter.shared`; signed builds can therefore opt into App Group and keychain access through their build configuration.
* **No App Store assumptions**: Distribution, Developer ID identity, notarization, and extension approval are external concerns and are not represented as verified build outcomes here.

---

## 5. Concurrency & Thermal Management

```
Total Active CPU Cores (N)
  └── Default Worker Concurrency = max(2, N / 2)
  └── Heavy Video Worker Cap     = max(1, min(2, N / 4))

Thermal State Transitions:
  • Nominal / Fair  ──► Normal Concurrency
  • Serious / Critical ──► Throttles Concurrency to 1

Queue: @MainActor published state; detached UserInitiated conversion tasks
       progress via MainActor hops; thermal observer hops to MainActor;
       cancellation ignored during finalizing commit.
```
