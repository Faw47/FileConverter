# Security & Privacy Model

**File Converter for macOS** is a single unsandboxed Developer ID app (`io.fileconverter.app` + `io.fileconverter.app.findersync`) with full native + Homebrew backend access and strict privacy guarantees.

---

## 1. Zero Full Disk Access Requirement

* **Explicit User Intent Only**: The application **never requests Full Disk Access**. Conversions run only on:
  1. Files explicitly selected by the user in Finder via the `FIFinderSync` context menu (ephemeral bookmark handoff).
  2. Files selected via `NSOpenPanel`/`NSSavePanel`.
  3. Files explicitly dragged and dropped.
* **No Plain-Path Authority**: The host never treats `lastKnownPath` or display paths as authorization. Finder requests are accepted only as bookmarks resolved under `SecurityScopedLease` (`withSecurityScope` first, ephemeral Finder fallback with balanced `start/stopAccessingSecurityScopedResource`).
* **Scoped Lifetimes**: Each source (and, for `.customFolder`, destination) `SecurityScopedLease` is held for the full conversion job and released exactly once; `clearCompleted` never releases active jobs' leases.

---

## 2. 100% Offline & Private (No Telemetry)

* **Zero Network Activity**: No network code, analytics SDKs, telemetry, or auto-update checkers.
* **Local Conversion**: All processing occurs on-device. No media leaves the device.
* **Privacy-Preserving Logs**: `os.Logger` emits milestones and error codes only; never file contents, bookmark tokens, or HMAC keys.

---

## 3. IPC & Finder Isolation

* **Single App**: `io.fileconverter.app` / `group.io.fileconverter.shared` + keychain `$(AppIdentifierPrefix)io.fileconverter.ipc` only. No Extended split remains.
* **Least-Privilege Finder**: Extension links only `FileConverterContracts` + `FileConverterFinderSupport`. No `FileConverterCore`, no backends, no `Process`. Host links both backend catalogs (`NativeBackendCatalog + ExternalBackendCatalog` always), so every preset (`MP3`, `FLAC`, `Opus`, `OGG`, `MKV`, `WebM`, Office docs, `QTA→MP3`) is visible.
* **Snapshot Contract**: Host-published `finder-menu-snapshot.json` is versioned, `≤1 MiB`, duplicate-alias checked, and capability-filtered per `BackendResolver`; Finder retains last-known-good on corruption/oversize and caps selection at 100 files.
* **Authenticated Mailbox**: HMAC-SHA256 envelopes over canonical JSON, keychain key `$(AppIdentifierPrefix)io.fileconverter.ipc`, 5-minute TTL with 60 s clock skew, per-request size limits, `Pending → Processing → Rejected` lifecycle with 60 s claim lease and crash recovery, duplicate UUID rejection, and serialized actor drains.
* **Personal Team Debug Fallback**: Release uses App Group container; Debug Personal Team cannot vend `com.apple.security.application-groups`, so `IPCConfiguration.sharedContainerURL` falls back to home-relative `/Library/Application Support/FileConverter/LocalIPC/native/` resolved via `getpwuid` with `..` rejection. Debug-only (`project.yml` Debug `FILE_CONVERTER_LOCAL_IPC_PATH`).

---

## 4. Subprocess Execution Security

* **No Shell Interpolation**: `Process` is invoked with discrete `[String]` argv; `/bin/sh` is never used. Paths with `$`, `` ` ``, `&`, etc. are not shell-parsed.
* **Bounded Drains**: `ExternalProcessRunner` drains stdout/stderr concurrently into `≤64 KiB` captured stderr, never `waitUntilExit` before draining.
* **Cancellation-Coupled Lifetime**: Each attempt registers for its `jobID`; `cancel(jobID:)` terminates only launched processes and escalates `SIGTERM → SIGKILL` after a grace period; registrations persist until termination.
* **LibreOffice Staging**: Unique staging/output/profile directories per job; `--outdir` points at staging output, expected file verified, then throwing move into `temporaryOutputURL`; never writes directly to the destination-derived path.
* **Temporary Output Isolation**: Every job writes to a hidden `.\(basename).converting-\(UUID).\(ext)` temp file and commits atomically via `replaceItemAt`/`moveItem` only after backend success and policy revalidation.

---

## 5. Output Safety

* **Directory Guard**: Resolve and finalization reject existing directories/packages, never `replaceItemAt` a directory tree.
* **Reservation**: `ConversionQueue.reservedOutputURLs` prevents concurrent jobs from colliding on the same ideal name; number-append policy falls back to UUID after 9999 collisions.
* **Policy Enforcement**: `.skip`/`.replaceIfNewer` stale-date collisions surface as `outputCollision` → `.failed` (not `.skipped`); `.replaceIfNewer` revalidates source/destination mtimes immediately before commit.
* **Commit Atomicity**: `finalizing` is a non-cancellable MainActor commit boundary; `replaceItemAt` preserves prior output until the new file is durable.
* **Path Confinement**: `sourceSubfolder("a/b")` and traversal names are rejected; destination directories are created only after backend resolution.
