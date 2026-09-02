# Architecture & Technical Design

This document details the architectural design, subsystem relationships, and data flow of **File Converter for macOS** (Native App Store and Extended Developer ID editions).

---

## 1. System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Finder.app Context                             │
│                                                                          │
│  FIFinderSync (FileConverterFinderSync)                                  │
│  • Edition-specific container: Native `group.io.fileconverter.shared`     │
│    vs Extended `group.io.fileconverter.extended.shared`                  │
│  • Snapshot-only menu: FileConverterContracts + FileConverterFinderSupport│
│    `FinderMenuSnapshot` (formats, compatibleFormatIDs, section order)    │
│    validated by `FinderMenuCatalog` (size/dupe/edition, ≤100 sources)    │
│  • Handoff: ephemeral bookmark `ConversionRequest` → HMAC envelope        │
│    `IPCChannels.sendRequest()` → Pending file                            │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ Pending/Processing/Rejected + Darwin notification
                               │  (authenticated, time-boxed, duplicate-safe)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Main Host Application                             │
│                                                                          │
│  ConversionCoordinator (actor, serialized drain, dedup) ──► ConversionQueue│
│     validation: PresetValidator + BackendResolver.canResolve               │
│                                                                          │
│                        @MainActor ConversionQueue                         │
│     • @Published counts (cancelled separated) • reservedOutputURLs        │
│     • Backend resolved before any directory/temp-file creation             │
│     • Atomic commit: finalizing non-cancellable; replaceItemAt/revalidate │
│     • Thermal throttling                                                   │
│                                  │                                      │
│                ┌─────────────────┴─────────────────┐                     │
│                ▼                                   ▼                     │
│        BackendResolver                      OutputNamingEngine            │
│     ordered registry                        • number collision            │
│     isAvailable gate                        • replaceIfNewer revalidation │
│     + centralized cancel                    • atomic temp→final commit    │
│                │                                   │                     │
│   ┌────────────┴────────────┐                       │                     │
│   ▼                         ▼                       ▼                     │
│ NativeBackends          ExternalBackends     SecurityScopedLease          │
│ • ImageIO               • FFmpeg             FileAccessManager             │
│ • PDFKit (@MainActor    • ImageMagick        (scoped source + dest leases)│
│   for text/RTF)         • LibreOffice        UserNotifications             │
│ • AVFoundation            (staging+profile)  • atomic sandbox leases      │
│   VideoToolbox          • Ghostscript                                 │
│   ExternalProcessRunner (bounded drains, graceful termination)            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Module Boundaries

| Module | Dependencies | Linked Into |
|---|---|---|
| **FileConverterContracts** | none | host, Finder, backends, Core |
| **FileConverterCore** | Contracts | host, backends, tests |
| **FileConverterNativeBackends** | Core | Native + Extended hosts |
| **FileConverterExternalBackends** | Core | Extended host only |
| **FileConverterFinderSupport** | Contracts | Finder extensions only |
| **FileConverterFinderSync** | Contracts + FinderSupport | Finder appex only |

* Finder extensions never import `FileConverterCore`, `FileConverterNativeBackends`, or `FileConverterExternalBackends`. Native host never links `FileConverterExternalBackends`.
* Enforced at build by `project.yml`/`Package.swift` dependencies, `FileConverterExtended` Swift flag, and `ArchitectureBoundaryTests` (source import + manifest checks + symbol-link verification).

---

## 3. Component Breakdown

### 3.1 FileConverterContracts + FileConverterFinderSupport
* **`FinderMenuSnapshot`**: versioned, size-bounded (`≤1 MiB`), capability-filtered host export. Validates duplicate aliases, preset/format limits, and `compatibleFormatIDs` subset; load retains last-known-good on corruption/oversize.
* **`FinderMenuCatalog`**: snapshot-only classification, directory-path short-circuit, source-count cap, edition-gated.
* **`FinderRequestClient` / `IPCChannels`**: HMAC-SHA256 envelope, `ConversionRequestLimits` (100 files, 1 MiB bookmark), Pending→Processing→Rejected lifecycle with 60 s claim lease, crash recovery, duplicate rejection, atomic claim ownership, and drain serialization.

### 3.2 FileConverterCore
* **`FormatRegistry`**: canonical alias ownership, atomic duplicate rejection, MOV/QTA ownership fixes.
* **`FormatDetector`**: extension + UTType + magic-byte tiers.
* **`PresetStore`**: built-in identity via `BuiltInPresetIdentity`, ordered merge preserving enabled/sort, App Group path per edition, read-only extension guard, corrupt-file preservation, retryable `publishFinderMenuSnapshot` gated on successful load.
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
* **Release (Developer ID, non-App Store, unified)**: Both `FileConverterNative` (`io.fileconverter.app`) and `FileConverterExtended` (`io.fileconverter.app.extended`) are now unsandboxed Developer ID apps with identical capabilities — App Group `group.io.fileconverter.shared` / `group.io.fileconverter.extended.shared` via `FileConverterAppGroup` + `containerURL(forSecurityApplicationGroupIdentifier:)` (`IPCConfiguration.sharedContainerURL`), but no `com.apple.security.app-sandbox`. External tools (`ffmpeg`, `libreoffice`, `imagemagick`, `ghostscript`) are available in both editions via `FileConverterExternalBackends`.
* **Debug Personal Team**: Xcode-managed provisioning cannot vend App Groups, so `project.yml` Debug overrides set `FileConverterLocalIPCPath` (`/Library/Application Support/FileConverter/LocalIPC/native/` or `/extended/`) and `IPCConfiguration.sharedContainerURL` resolves to `getpwuid(getuid()).pw_dir` + that home-relative path with `..` traversal rejection. Production Release is unaffected and remains unsandboxed.

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
