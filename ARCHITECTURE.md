# Architecture & Technical Design

This document details the architectural design, subsystem relationships, and data flow of **File Converter for macOS** (unified Developer ID, unsandboxed — former Native + Extended merged).

---

## 1. System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Finder.app Context                             │
│  FIFinderSync (FileConverterFinderExtension) `io.fileconverter.app.findersync` │
│  • Container `group.io.fileconverter.shared` (`IPCConfiguration.sharedContainerURL`, Debug fallback `~/Library/Application Support/FileConverter/LocalIPC/native/`) │
│  • Snapshot: FileConverterContracts + FinderSupport `FinderMenuSnapshot` │
│    validated by `FinderMenuCatalog` (size/dupe/edition, ≤100 sources)    │
│  • Handoff: ephemeral bookmark `ConversionRequest` → HMAC envelope        │
│    `FinderRequestClient.send` → Pending file                             │
└──────────────────────────────┬──────────────────────────────────────────┘
                                │ Pending/Processing/Rejected + Darwin notification
                                │  (authenticated, time-boxed, duplicate-safe)
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        File Converter.app (unified, unsandboxed)         │
│  io.fileconverter.app • `FileConverter` + `FileConverterFinderExtension` │
│  ConversionCoordinator (actor, serialized drain, dedup) ──► ConversionQueue│
│     validation: PresetValidator + BackendResolver.canResolve (always     │
│                  Native+External)                                        │
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
| **FileConverterExternalBackends** | Core | host (always) |
| **FileConverterFinderSupport** | Contracts | host (Settings status) + Finder extension |
| **FileConverterFinderSync** | Contracts + FinderSupport | Finder appex |

* Finder extension never imports `FileConverterCore`/`NativeBackends`/`ExternalBackends`. Host links both backend catalogs (`BackendResolver` = `NativeBackendCatalog + ExternalBackendCatalog` always) plus `FinderSupport` for live Finder status in Settings.
* Enforced by `Package.swift` deps and `ArchitectureBoundaryTests` (Core has no `Process`, Finder has no `FileConverterCore`).

## 5. Settings (redesigned)

* **`AppSettings`** (`ObservableObject`, `MainActor`): typed `UserDefaults` store with registration, clamping, and reset. Owns output/conflict/filename defaults for new presets, notification + reveal switches, and `maxConcurrentJobs` (pushes into `ConversionQueue`). Every control writes here — no dead toggles.
* **`AppState.SettingsTab`**: 5 tabs (General, Presets, External Tools, Performance, Finder). Dead Video/Audio cases removed. Selection persists via `fc.selectedSettingsTab`; `openSettings(tab:)` is the single entry point (menu, toolbar, `fileconverter://settings?tab=` with fuzzy matching).
* **`SettingsView`**: `NavigationSplitView` sidebar (source-list style, collapsible via ⌃⌘S) + detail. No `TabView`.
* **Presets**: sidebar search + category filter + availability badges (`Off`, `Needs tool` via `supportsAnySource`), context menu, Delete key, explicit Save/Discard editor with validation (non-empty names, known writable extension via `FormatRegistry`, non-empty pattern, single-folder subfolder rule), live filename preview, custom-folder bookmark picker, Export/Import (merge or replace) with error alerts, Reset with confirmation. New customs inherit `AppSettings` defaults.
* **Performance**: stepper 1…16 bound to `AppSettings` (live `ConversionQueue` sync), effective concurrency display (thermal throttling to 1 under Serious/Critical), system-default reset, live queue counts.
* **Tools**: background `Task.detached` rescan (never blocks UI), sorted list, copyable install commands, last-checked footer.
* **Finder**: live `FinderRequestClient.isReady()` + snapshot readiness + snapshot age, reveal IPC folder, relaunch Finder, enable steps.
* **Queue wiring**: `ConversionQueue` reads `maxConcurrentJobs` on init, exposes `current/effectiveMaxConcurrency`, gates notifications on `enableNotifications` (defaults true), and posts `.fileConverterBatchCompleted` with output URLs; `AppState` reveals them when `revealInFinder` is on.

---

## 3. Component Breakdown

### 3.1 FileConverterContracts + FileConverterFinderSupport
* **`FinderMenuSnapshot`**: versioned, size-bounded (`≤1 MiB`), capability-filtered host export. Validates duplicate aliases, preset/format limits, and `compatibleFormatIDs` subset; load retains last-known-good on corruption/oversize.
* **`FinderMenuCatalog`**: snapshot-only classification, directory-path short-circuit, source-count cap, edition-gated.
* **`FinderRequestClient` / `IPCChannels`**: HMAC-SHA256 envelope, `ConversionRequestLimits` (100 files, 1 MiB bookmark), Pending→Processing→Rejected lifecycle with 60 s claim lease, crash recovery, duplicate rejection, atomic claim ownership, and drain serialization.

### 3.2 FileConverterCore
* **`FormatRegistry`**: canonical alias ownership, atomic duplicate rejection, MOV/QTA ownership fixes.
* **`FormatDetector`**: extension + UTType + magic-byte tiers.
* **`PresetStore`**: built-in identity via `BuiltInPresetIdentity`, ordered merge preserving enabled/sort, shared-container path (`IPCConfiguration.sharedContainerURL`), read-only extension guard, corrupt-file preservation, retryable `publishFinderMenuSnapshot` gated on successful load.
* **`PresetValidator`**: resolver-aware intersection — a preset is compatible only if enabled, source-compatible **and** `BackendResolver.canResolve` for every selected file.
* **`ConversionQueue`**: `@MainActor` state, nonisolated `executeJob`. Backend resolved before output reservation; concurrent destinations reserved via `reservedOutputURLs`; `clearCompleted` never releases active leases; `finalizing` is non-cancellable commit boundary with `replaceIfNewer` revalidation and `replaceItemAt` atomic commit.
* **`OutputNamingEngine`**: per-preset policy, directory-traversal guard, custom-folder lease requirement (no fallback path), numbered collision with in-flight reservation, atomic commit via `replaceItemAt`/`moveItem` with directory guard.
* **`BackendResolver`**: ordered registry, `canResolve`/`supportsAnySource`, `backendUnavailable`/`incompatibleConversion` errors, delegated cancel.
* **`SecurityScopedLease` / `FileAccessManager`**: `withSecurityScope` first with ephemeral fallback, balanced `start/stopAccessingSecurityScopedResource`, stale-rejection, destination-lease held for full job lifetime.

### 3.3 Conversion Backends
* **Native (`FileConverterNativeBackends`)**: `ImageIOBackend`, `PDFKitBackend` (`@MainActor` `renderTextToPDF` for `NSTextView`/`NSPrintOperation`), `AVFoundationBackend`.
* **External (`FileConverterExternalBackends`)**: `FFmpegBackend` (ffprobe + encoder probing), `ImageMagickBackend`, `GhostscriptBackend`, `LibreOfficeBackend` (per-job staging/output/profile + throwing move). All use `ExternalProcessRunner`/`ExternalProcessRegistry`: bounded concurrent stdout/stderr drains, launch-state guard, graceful `terminate`→`SIGKILL` escalation, full-lifetime registration, cancellation coupling, and isolated LibreOffice profiles.

### 3.4 Finder Sync Extension
* `FIFinderSync` monitoring `/` with snapshot-only menu; setup/readiness gate requiring both keychain and snapshot; `listenForPresetChanges` via snapshot Darwin notification; `conversionPresetSelected` builds ephemeral bookmarks and sends via `FinderRequestClient`.

### 3.5 Signing & Local IPC
* **Release (Developer ID, unsandboxed, single app)**: `File Converter.app` `io.fileconverter.app` + `io.fileconverter.app.findersync` — no `com.apple.security.app-sandbox`, no `ENABLE_USER_SCRIPT_SANDBOXING`. App Group `group.io.fileconverter.shared` + `keychain-access-groups` `$(AppIdentifierPrefix)io.fileconverter.ipc` for Finder IPC; all `ExternalBackends` (FFmpeg, LibreOffice, ImageMagick, Ghostscript) linked. Former `FileConverterExtended` (`io.fileconverter.app.extended`) removed.
* **Debug Personal Team**: Xcode-managed Personal Team cannot vend App Groups, so `project.yml` Debug `FILE_CONVERTER_LOCAL_IPC_PATH=/Library/Application Support/FileConverter/LocalIPC/native/` and `IPCConfiguration.sharedContainerURL` resolves via `getpwuid` + home-relative path with `..` rejection. Release unaffected.

---

## 4. Concurrency & Thermal Management

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
