# Security & Privacy Model

**File Converter for macOS** is a local app (`io.fileconverter.app` + `io.fileconverter.app.findersync`) with native backends and optional external tools. This document describes the implemented local security boundaries; the package script uses an available Apple Development identity (or an ad-hoc fallback) for Finder registration and does not notarize or publish the app.

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

* **Zero Network Activity**: No network code, analytics SDKs, telemetry, or auto-update checkers are part of the app.
* **Local Conversion**: All processing occurs on-device. No media leaves the device.
* **Privacy-Preserving Logs**: `os.Logger` emits milestones and error codes only; never file contents, bookmark tokens, or HMAC keys.

---

## 3. IPC & Finder Isolation

* **Single App**: `io.fileconverter.app` / `io.fileconverter.app.findersync` only. Provisioned builds may use App Group `group.io.fileconverter.shared` and keychain `$(AppIdentifierPrefix)io.fileconverter.ipc`; local ad-hoc builds deliberately use the confined home-relative IPC path and file key instead, because they have no provisioning profile. There is no second “Extended” host.
* **Least-Privilege Finder**: Extension links only `FileConverterContracts` + `FileConverterFinderSupport`. No `FileConverterCore`, no backends, no `Process`. The host registers both backend catalogs, but menu entries are capability-filtered; optional-tool presets remain hidden until the required tool/encoder is available.
* **Snapshot Contract**: Host-published `finder-menu-snapshot.json` is versioned, `≤1 MiB`, duplicate-alias checked, and capability-filtered per `BackendResolver`; Finder retains last-known-good on corruption/oversize and caps selection at 100 files.
* **Authenticated Mailbox**: HMAC-SHA256 envelopes over canonical JSON, keychain key `$(AppIdentifierPrefix)io.fileconverter.ipc`, 5-minute TTL with 60 s clock skew, per-request size limits, `Pending → Processing → Rejected` lifecycle with 60 s claim lease and crash recovery, duplicate UUID rejection, and serialized actor drains.
* **Local Artifact Container**: local builds explicitly configure home-relative `/Library/Application Support/FileConverter/LocalIPC/native/`, resolved via `getpwuid` with `..` rejection. That explicit setting takes precedence because macOS may vend an unusable App Group URL to unsigned processes. Builds that omit the local override use the App Group; the local path also matches the Finder extension's narrow Personal Team exception.

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
* **Policy Enforcement**: `.skip` collisions finish as skipped without invoking a backend; stale `.replaceIfNewer` collisions surface as `outputCollision` and never silently overwrite. `.replaceIfNewer` revalidates source/destination mtimes immediately before commit. `.ask` pauses the job for an explicit batch decision.
* **Commit Atomicity**: `finalizing` is a non-cancellable MainActor commit boundary; `replaceItemAt` preserves prior output until the new file is durable.
* **Path Confinement**: `sourceSubfolder("a/b")` and traversal names are rejected; destination directories are created only after backend resolution.
