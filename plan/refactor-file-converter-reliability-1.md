---
goal: Harden File Converter against data loss, unbounded work, stale state, and avoidable macOS workflow friction while preserving its current architecture and supported formats.
version: 1.0
date_created: 2026-09-21
last_updated: 2026-09-21
owner: File Converter maintainers
status: 'Complete'
tags: [macos, swift, reliability, data-integrity, presets, finder, accessibility, performance]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-brightgreen)

This plan merges the current adversarial review with the findings in the separately supplied review. It is deliberately sequenced around user-data safety and invariant repair, not around implementation convenience. Each phase is intended to leave the tree buildable and testable; later UX and performance work depends on the correctness contracts established earlier.

The supplied review is substantially correct, with the following qualifications:

| Supplied finding | Disposition | Plan treatment |
|---|---|---|
| H1: external tools can run forever and inherit stdin | Agree | Treat as High. Add finite, tool-specific deadlines, closed stdin, typed timeout errors, termination escalation, and shutdown coordination. |
| H2: source lease is released when a job pauses for collision | Agree with qualification | The current unsandboxed host masks the user-visible failure, and `start`/`stop` calls are balanced rather than numerically imbalanced. The real defect is that the queued job retains a lease object whose access is already inactive. Repair the ownership invariant before sandboxing or execution context changes expose it. |
| M1: imported preset fields can become arbitrary subprocess arguments | Agree | Treat imported presets as untrusted data. Replace dictionary-to-argv forwarding with typed, allowlisted options and preserve unknown JSON only as inert round-trip data. This is argument injection, not shell injection. |
| M2: text-to-PDF monopolizes the main actor | Agree, different remedy | `NSPrintOperation` is `@MainActor`, so moving it wholesale to an arbitrary background thread is not a sound fix. Replace the conversion path with a Core Text/Core Graphics PDF renderer that can run off the main actor. |
| M3: PDF/image expansion lacks practical resource bounds | Agree | Add autorelease pools and a documented resource policy with warnings and hard safety ceilings. Avoid arbitrary low limits that reject legitimate work. |
| M4: Finder and host can classify the same file differently | Agree | Keep the Finder extension metadata-only and fast; make the host authoritative and surface a specific “file contents do not match the extension” result. Do not duplicate heavyweight content probing in Finder. |
| M5: multi-output collisions show only the first conflict | Agree, stronger impact | Keep the Critical priority from the current review. Choosing Replace currently becomes a job-wide overwrite policy, so later colliding outputs can be replaced without having appeared in the dialog. Approval must bind to an exact set of destinations. |
| M6: Finder requests are acknowledged after in-memory admission | Agree | Add a durable admission journal and owned-artifact recovery. Do not blindly auto-resume conversions whose commit state is ambiguous. |
| M7: collision defaults are too aggressive | Agree | Make the scope explicit, remove destructive keyboard ambiguity, and default bulk application off. |
| L1: keep-both and replace-if-newer decisions have TOCTOU windows | Agree | Recheck and, where needed, retry inside coordinated commit operations. |
| L2: packages are admitted inconsistently | Agree with qualification | Do not blanket-reject every package. Model directory-package capability per backend and reject unsupported packages with a specific message. |
| L3: source validity is checked too weakly at execution | Agree | Revalidate type, readability, package/directory policy, size, and source fingerprint immediately before conversion. |
| C11: package modules are not proven under Swift 6 strict concurrency | Agree | Move the package to Swift 6 language mode and add CI that builds both SwiftPM and the real Xcode products under the same concurrency expectations. |
| UX/QoL items 1–4, 6–8 | Agree | Include sheet command-state feedback, FIFO workflow coordination, cancellable discovery, editable PDF batches, visible reveal/notification state, terminology cleanup, and fingerprinted detection/probe reuse. |
| UX/QoL item 5: always confirm Cancel All | Partly agree | Confirmation is warranted when the command will stop multiple active jobs, not when it merely clears terminal rows. Preserve failure context and make retry discoverable. |

The supplied report’s unconfirmed items are not silently promoted into implementation work. Symlink lease identity, rapid dialog replacement, a regular-file “custom folder,” double-opening PDFs, entitlement string spelling, and split storage identities need dedicated reproductions first. Likewise, this plan does not adopt the supplied suggestion to run `NSPrintOperation` from a background thread, does not reduce the collision issue to a consent-only defect, and does not reject all file packages indiscriminately.

## 1. Requirements & Constraints

### Functional Requirements

- **REQ-001**: Preset loading must fail closed: a decode/read failure must never expose an apparently empty writable library or permit a destructive save until the user explicitly recovers, replaces, or exports the damaged data.
- **REQ-002**: Every overwrite, skip, or keep-both decision must apply only to destinations that were actually evaluated and, for destructive choices, explicitly presented to the user.
- **REQ-003**: Multi-output jobs must discover and display the complete collision set before asking for a batch decision; destinations that appear or change after approval must trigger a new decision or a safe retry.
- **REQ-004**: Imported preset data must not directly synthesize arbitrary command-line flags, output containers, or Ghostscript compatibility values.
- **REQ-005**: Every external process execution must have closed stdin, a finite deadline, cancellation propagation, termination escalation, and a user-visible typed failure.
- **REQ-006**: App termination must wait for bounded converter shutdown and must leave neither running descendants nor untracked temporary/staging files.
- **REQ-007**: Text-to-PDF conversion must not perform document pagination and PDF rendering on the main actor.
- **REQ-008**: Image and PDF conversions must enforce explicit frame/page/pixel/output-count policies, use bounded autorelease scopes, and report limit violations before partial commit.
- **REQ-009**: PDF option dialogs must round-trip every saved option they present, and batch dialogs must validate and preview every input that contributes to the planned output set.
- **REQ-010**: Effective conversion settings must come from one documented resolver with explicit inheritance semantics; global defaults must not unexpectedly override preset-specific values.
- **REQ-011**: Jobs must revalidate source existence, readability, file/package kind, zero-byte policy, and source fingerprint immediately before backend execution.
- **REQ-012**: Directory packages must be accepted only when the selected backend explicitly supports that package type; Finder, in-app admission, and execution must explain mismatches consistently.
- **REQ-013**: Finder requests must become durable before acknowledgement, survive host crashes, and recover without duplicating outputs whose commit state is uncertain.
- **REQ-014**: Rejected, completed, or abandoned Finder requests and bookmarks must be removed under a bounded retention policy.
- **REQ-015**: The Finder extension must launch its actual containing app whenever possible rather than selecting an arbitrary installed bundle with the same identifier.
- **REQ-016**: Queue progress must distinguish current-file progress from batch progress and must never label an incomplete batch “100% Completed.”
- **REQ-017**: Collision sheets, queue actions, settings controls, and workflow dialogs must have unambiguous keyboard behavior and meaningful accessibility labels, values, and hints.
- **REQ-018**: Mixed-format batches must explain compatibility before enqueue and offer a fast path to group files by compatible preset or omit incompatible files.
- **REQ-019**: Add-file, workflow, backend-discovery, reveal, notification, retry, and filtered-preset states must provide visible feedback instead of silently ignoring input or hiding consequences.
- **REQ-020**: Detection and probing must be reused only while a source fingerprint remains unchanged; stale cached results must never cross a file-content change.
- **REQ-021**: Exported preset files must omit machine-local paths and security-scoped bookmarks by default and require an explicit, clearly labeled choice to include portable directory intent where possible.
- **REQ-022**: SwiftPM modules, Xcode app, Finder extension, Debug, Release, and packaging paths must share an explicit Swift 6/concurrency baseline and be validated independently.
- **REQ-023**: Existing supported workflows and the current 256-test baseline must remain intact unless a test asserts behavior deliberately changed by this plan.

### Security Requirements

- **SEC-001**: No existing destination may be replaced without an exact, current authorization for that canonical destination identity.
- **SEC-002**: Untrusted imported data may influence subprocess arguments only through typed values that pass backend-specific allowlists and range validation.
- **SEC-003**: Persistent IPC and preset data must minimize local paths and bookmark lifetimes, and logs/notifications must avoid exposing full paths unless needed for a direct user action.
- **SEC-004**: Startup cleanup may delete only artifacts named in a File Converter-owned manifest; it must never sweep broad filename patterns or unrelated temporary directories.
- **SEC-005**: Durable recovery records must be authenticated or stored inside the existing trusted app-group boundary and must never be interpreted as permission to access a resource without a currently valid bookmark or user grant.

### Constraints

- **CON-001**: Preserve the macOS 14 deployment target and the current SwiftUI/AppKit, SwiftPM, and Xcode-project structure unless a specific task proves that a change is necessary.
- **CON-002**: Prefer targeted model and boundary changes over a broad rewrite of `ConversionQueue`, the preset model, or Finder IPC.
- **CON-003**: Preserve backward decoding of existing user presets and Finder snapshot/request formats; migrations must be additive, versioned, and tested.
- **CON-004**: Keep Finder menu construction metadata-only, deterministic, and fast enough for synchronous Finder callbacks.
- **CON-005**: Do not claim sandbox correctness from the current unsandboxed host; add focused sandbox/security-scope validation before changing entitlements.
- **CON-006**: Do not add third-party dependencies unless the standard macOS frameworks cannot meet a measured requirement and the dependency is separately approved.
- **CON-007**: Each phase must compile and pass its targeted tests before dependent phases begin; never defer a known data-loss regression to final integration.

### Guidelines

- **GUD-001**: Add a failing characterization or reproduction test before each correctness fix, then retain it as a regression test.
- **GUD-002**: Perform final destination existence, identity, modification-date, and authorization checks at coordinated commit time, not only during planning.
- **GUD-003**: Keep SwiftUI/AppKit state on the main actor, but move CPU-heavy parsing, rendering, probing, and filesystem enumeration into Sendable worker boundaries.
- **GUD-004**: Keep user decisions reversible and explicit: Cancel must never mean Skip, and Apply to All must state its exact scope.
- **GUD-005**: Use structured, typed errors from core/backend layers and translate them into actionable user language at the app boundary.
- **GUD-006**: Treat expected output sets, temporary artifacts, source access, and process handles as owned resources with one explicit lifecycle owner.

### Patterns

- **PAT-001**: Introduce an `EffectivePresetResolver` as the single source of truth for global-versus-preset inheritance.
- **PAT-002**: Represent collision authorization as a destination-keyed `CollisionResolutionPlan`, never as a job-wide overwrite boolean.
- **PAT-003**: Use a `SourceFingerprint` value (canonical identity when available, size, modification date, and relevant package metadata) to validate cached detection and probe results.
- **PAT-004**: Use a durable job/request journal with explicit `admitted`, `running`, `committing`, and `finished` states; recovery must treat `committing` as ambiguous and require review.
- **PAT-005**: Preserve forward-compatible unknown preset JSON in an inert opaque field that encoding can round-trip but no backend can execute.
- **PAT-006**: Route all subprocesses through one supervisor that owns stdin, deadlines, cancellation, process-group termination, and diagnostics.

## 2. Implementation Steps

### Phase 0: Freeze Behavior and Build a Reproducible Safety Baseline

- **GOAL-001**: Convert the two audits into executable regression contracts before changing production behavior.

#### Tasks

Primary implementation surface: `Tests/FileConverterTests/{PresetEngineTests,OutputNamingTests,ConversionQueueTests,ExternalBackendProcessTests,PDFWorkflowTests,FormatDetectionEdgeCaseTests}.swift`; new deterministic fixtures under `Tests/FileConverterTests/Fixtures/`; baseline commands `swift build`, `swift test`, `xcodebuild -project FileConverter.xcodeproj -scheme FileConverter`, and `Scripts/package_app.sh`. This phase declares tests around current symbols `PresetStore`, `OutputNamingEngine.reserveOutputs`, `ConversionQueue.executeJob`, `ExternalProcessAttempt`, `PDFKitBackend`, and `FormatDetector` before production changes.

- **TASK-001**: Record the implementation baseline and validation matrix.
  - Capture toolchain versions, `swift build`, `swift test`, Xcode Debug/Release app builds, Finder extension builds, and the packaging script result without installing the artifact.
  - Record the actual discovered test count rather than copying the supplied report’s approximate count.
  - Save no generated logs in source control unless they are sanitized, stable fixtures.
  - Covers: `REQ-022`, `REQ-023`.
  - Exit: every validation lane has a command, expected artifact, and current pass/fail state.

- **TASK-002**: Add preset-corruption characterization tests.
  - Cover malformed JSON, unreadable files, schema mismatch, interrupted atomic-save recovery, backup discovery, and mutation attempts after load failure.
  - Assert that current corrupt data is preserved byte-for-byte until an explicit recovery action.
  - Covers: `REQ-001`, `CON-003`, `GUD-001`.
  - Exit: tests fail against the current writable-empty fallback and identify every mutating entry point.

- **TASK-003**: Add deterministic multi-output collision fixtures and a fake backend.
  - Produce two or more outputs where only later outputs collide, where a destination appears after preflight, and where another process takes a keep-both candidate.
  - Capture current `.overwrite` escalation as an expected failing test without weakening the assertion.
  - Covers: `REQ-002`, `REQ-003`, `SEC-001`.
  - Exit: the unreviewed-overwrite path is reproduced without invoking a real converter.

- **TASK-004**: Add controllable external-process fixtures.
  - Provide test executables or scripts that wait on stdin, ignore `SIGTERM`, spawn a child, exceed a deadline, exit nonzero, and emit bounded/unbounded stderr.
  - Ensure fixtures are invoked only from tests and do not depend on locally installed ImageMagick, LibreOffice, Ghostscript, Calibre, or FFmpeg.
  - Covers: `REQ-005`, `REQ-006`, `PAT-006`.
  - Exit: process cleanup and timeout behavior can be tested in seconds.

- **TASK-005**: Add representative image, PDF, text, package, and source-mutation fixtures.
  - Include a two-frame GIF, a large-dimension image header, a multi-page PDF, a PDF with many pages but small bytes, a zero-byte file, a package directory, and a file that changes between admission and execution.
  - Generate fixtures deterministically in tests when practical; commit only small, license-clear binaries.
  - Covers: `REQ-008`, `REQ-011`, `REQ-012`.
  - Exit: each resource and source-validity policy has an executable fixture.

- **TASK-006**: Establish UI and accessibility test seams.
  - Extract pure presentation-state builders for collision copy, queue summary, disabled-command reasons, batch compatibility, and notification/reveal status.
  - Add accessibility-identifier conventions for later XCUITest or Accessibility Inspector checks without redesigning views yet.
  - Covers: `REQ-016`, `REQ-017`, `REQ-019`.
  - Exit: later UI phases can be tested without brittle pixel assertions.

### Phase 1: Protect Presets and Close the Imported-Data Execution Boundary

- **GOAL-002**: Ensure damaged or imported presets cannot erase user data or execute unvalidated backend options.

#### Tasks

Primary implementation surface: `Sources/FileConverterCore/Presets/{PresetStore,PresetExchange,PresetValidator}.swift`, `Sources/FileConverterCore/Models/ConversionPreset.swift`, `Sources/FileConverterCore/Presets/PresetEditorStateController.swift`, and `Sources/FileConverterApp/{AppState,Settings/PresetEditorView}.swift`. Modify `PresetStore.loadPresets`, `PresetStore.savePresets`, and every add/update/delete/import/reset call path; add proposed types `PresetStoreState`, `PresetOpaqueFields`, and typed backend option values consumed by the existing backend argument builders.

- **TASK-007**: Model preset-store availability explicitly.
  - Replace the writable-empty fallback with states equivalent to `loading`, `ready`, and `recoveryRequired(error, sourceURL, backupCandidates)`.
  - Keep the last successfully decoded in-memory snapshot only when its provenance is known; do not substitute built-ins and then save over the corrupt file.
  - Covers: `REQ-001`.
  - Exit: a load error cannot be mistaken for a legitimate empty library.

- **TASK-008**: Make every preset mutation report persistence failure.
  - Convert add, update, delete, duplicate, reset, import, reorder, and save operations to throwing or result-bearing APIs.
  - Update every caller to show a nonmodal error with Retry, Export Raw Data, Restore Backup, and Choose Replacement as applicable.
  - Covers: `REQ-001`, `GUD-005`.
  - Depends on: `TASK-007`.
  - Exit: no public mutation path can change the cache while disk state is unavailable or unknown.

- **TASK-009**: Implement explicit preset recovery and backup selection.
  - Enumerate only File Converter-owned backups, validate them before offering restore, and preserve the damaged primary file under a timestamped recovery name.
  - Make “Start Fresh” a separately confirmed action that never deletes the retained damaged copy.
  - Covers: `REQ-001`, `SEC-004`.
  - Depends on: `TASK-008`.
  - Exit: corrupt primary, valid backup, no backup, and failed restore all have deterministic outcomes.

- **TASK-010**: Split executable preset options from forward-compatible JSON.
  - Add a Codable inert opaque-field representation for unknown imported properties.
  - Stop merging unknown top-level keys into `extraBackendOptions`.
  - Migrate existing encoded presets without losing known settings; unknown data may round-trip but remains unreachable by builders.
  - Covers: `REQ-004`, `CON-003`, `PAT-005`.
  - Exit: an unknown JSON key survives export/import but cannot appear in any process argument array.

- **TASK-011**: Replace arbitrary backend-option dictionaries with typed validated options.
  - Define the minimal set of advanced FFmpeg/ImageMagick/Ghostscript/LibreOffice options the product genuinely supports.
  - Validate enum membership, numeric ranges, string length, output-container compatibility, and prohibited option prefixes at both import and execution boundaries.
  - Reject unsupported keys with a list of exact fields instead of silently dropping them.
  - Covers: `REQ-004`, `SEC-002`.
  - Depends on: `TASK-010`.
  - Exit: crafted keys such as an unrecognized JSON property cannot synthesize `-<key>` arguments.

- **TASK-012**: Validate output containers and Ghostscript compatibility against backend registries.
  - Resolve container aliases through `FormatRegistry` and backend capability tables.
  - Limit PDF compatibility to the exact Ghostscript values implemented and reject newline/control characters in all imported strings.
  - Covers: `REQ-004`, `SEC-002`.
  - Depends on: `TASK-011`.
  - Exit: malformed presets fail before enqueue with a field-specific message.

- **TASK-013**: Make preset export privacy-preserving by default.
  - Strip custom output URLs, local absolute paths, security-scoped bookmark blobs, last-used file names, and other machine-specific values from normal exports.
  - If directory intent is exportable, represent only a portable semantic choice such as “same as source” or “ask each time.”
  - Covers: `REQ-021`, `SEC-003`.
  - Exit: a default exported JSON file contains no local home path or bookmark data.

### Phase 2: Make Output Planning and Commit Authorization Exact

- **GOAL-003**: Eliminate unreviewed replacement, incomplete collision discovery, and commit-time races.

#### Tasks

Primary implementation surface: `Sources/FileConverterCore/Files/{OutputNamingEngine,SecurityScopedLease,FileAccessManager}.swift`, `Sources/FileConverterCore/Models/ConversionJob.swift`, `Sources/FileConverterCore/Conversion/ConversionQueue.swift`, and `Sources/FileConverterApp/AppState.swift`. Modify `OutputNamingEngine.reserveOutputs`, `OutputNamingEngine.finalizeConversionOutputs`, `ConversionQueue.executeJob`, `ConversionQueue.markAwaitingCollision`, and `AppState.resolveCollision`; add proposed values `CanonicalDestinationKey`, `DestinationFingerprint`, and `CollisionResolutionPlan`.

- **TASK-014**: Introduce canonical destination keys and complete collision collection.
  - Normalize case/Unicode according to the destination volume, resolve parent-directory identity, and retain the display URL separately.
  - Change reservation planning to collect all conflicts in a job instead of throwing on the first existing destination.
  - Covers: `REQ-002`, `REQ-003`, `SEC-001`.
  - Exit: one planning pass reports every current conflict with a stable internal key.

- **TASK-015**: Replace job-wide `collisionOverride` with an exact resolution plan.
  - Store a decision per canonical destination key, plus the observed destination fingerprint used when the decision was made.
  - Scope “Apply to all” to the displayed conflict set only; never reinterpret it as authorization for outputs not in that set.
  - Covers: `REQ-002`, `REQ-003`, `PAT-002`.
  - Depends on: `TASK-014`.
  - Exit: a later colliding output cannot inherit a Replace decision it was not shown under.

- **TASK-016**: Redesign the collision sheet around exact consequences.
  - Show the number of conflicts, expandable destination list, whether each file exists or is reserved by another queued job, and the source/preset producing it.
  - Default bulk application off; keep Cancel distinct from Skip; do not assign Escape to Skip All; require explicit activation for Replace.
  - Covers: `REQ-003`, `REQ-017`, `GUD-004`.
  - Depends on: `TASK-015`.
  - Exit: keyboard-only and VoiceOver users can review the same set and choose the same scoped action.

- **TASK-017**: Revalidate replacement authorization inside coordinated commit.
  - Inside the `NSFileCoordinator` accessor, re-read destination identity and compare it with the approved fingerprint.
  - If the destination is new or changed, abort that output without deleting it and return a fresh conflict to the queue.
  - Use the URL delivered by the coordinator block.
  - Covers: `REQ-002`, `SEC-001`, `GUD-002`.
  - Depends on: `TASK-015`.
  - Exit: an external destination change between dialog and commit cannot be overwritten under stale approval.

- **TASK-018**: Make keep-both allocation race tolerant.
  - Resolve a candidate, coordinate its creation, and retry with the next suffix if the path is taken before the move.
  - Bound retries and report a typed “destination changing too quickly” error rather than replacing or looping forever.
  - Covers: `REQ-002`, `GUD-002`.
  - Exit: concurrent creators produce unique results or a bounded failure, never an accidental replace.

- **TASK-019**: Move replace-if-newer comparison into coordinated commit.
  - Compare source and destination modification metadata inside a read/write coordination scope.
  - Define equal/missing/unreliable timestamp behavior explicitly; default to no replacement when “newer” cannot be established.
  - Covers: `REQ-002`, `SEC-001`, `GUD-002`.
  - Exit: the policy cannot delete a destination whose timestamp changed after preflight.

- **TASK-020**: Return actual committed URLs from finalization.
  - Make finalization return the destination chosen after any keep-both retry and update job output URLs, notifications, reveal actions, and receipts from that result.
  - Covers: `REQ-002`, `REQ-019`.
  - Depends on: `TASK-018`.
  - Exit: UI and IPC receipts never point at a preflight name that was not committed.

- **TASK-021**: Repair collision-pause lease ownership.
  - Give the executing attempt an explicit ownership token for its security-scoped lease.
  - On pause, either transfer an active lease to the queued job without executing the local release, or deliberately release and clear it so retry must resolve and reacquire.
  - Add an `isActive` observation for assertions, not as a substitute for ownership.
  - Covers: `REQ-011`, `CON-005`, `GUD-006`.
  - Exit: an awaiting-collision job never stores a non-nil inactive lease.

- **TASK-022**: Reacquire and revalidate all source access on retry.
  - Resolve stale bookmarks, refresh them when allowed, reacquire scope, and rerun source fingerprint/type checks before the backend starts.
  - Preserve the original admission error context if reacquisition fails.
  - Covers: `REQ-011`, `SEC-005`, `PAT-003`.
  - Depends on: `TASK-021`.
  - Exit: collision retries work in a sandboxed test host and fail clearly when access has been revoked.

### Phase 3: Bound External Processes, Cancellation, and Temporary Artifacts

- **GOAL-004**: Make every converter process and staging artifact terminate under one bounded lifecycle.

#### Tasks

Primary implementation surface: `Sources/FileConverterExternalBackends/ExternalProcessRunner.swift`, every backend `convert`/probe launch site under `Sources/FileConverterExternalBackends/`, `Sources/FileConverterCore/Conversion/ConversionQueue.swift`, and `Sources/FileConverterApp/AppMain.swift`. Replace direct `ExternalProcessAttempt` construction with proposed `ExternalProcessSupervisor.run`, add `ConversionQueue.cancelAllAndWait`, and connect AppKit termination through `applicationShouldTerminate`/reply-based shutdown.

- **TASK-023**: Add a central external-process supervisor.
  - Route launch, environment construction, stdout/stderr capture, cancellation, and process registration through one Sendable owner.
  - Prevent backend code from starting unmanaged `Process` instances.
  - Covers: `REQ-005`, `REQ-006`, `PAT-006`.
  - Exit: tests can enumerate and cancel every File Converter-launched process.

- **TASK-024**: Close stdin and apply finite tool-specific deadlines.
  - Set standard input to the null device before launch.
  - Define explicit probe deadlines and conversion deadlines for FFmpeg, ImageMagick, LibreOffice, Ghostscript, and Calibre; expose any user-adjustable long-job setting with a safe finite maximum.
  - Covers: `REQ-005`.
  - Depends on: `TASK-023`.
  - Exit: no production subprocess call uses a nil/infinite timeout or inherited interactive stdin.

- **TASK-025**: Implement deterministic timeout and cancellation escalation.
  - On timeout/cancel, send graceful termination, wait a short bounded grace period, then terminate the process group if it remains alive.
  - Reap descendants and close every pipe; cap captured diagnostic bytes while retaining the most relevant tail.
  - Covers: `REQ-005`, `REQ-006`.
  - Depends on: `TASK-023`.
  - Exit: the ignore-signal and child-process fixtures leave no live processes or blocked pipe readers.

- **TASK-026**: Add typed external-tool failures and recovery actions.
  - Distinguish missing tool, launch failure, deadline exceeded, user cancellation, signal termination, unsupported input, and ordinary nonzero exit.
  - Include tool name, bounded duration, and a concise diagnostic without exposing unnecessary full paths.
  - Covers: `REQ-005`, `SEC-003`, `GUD-005`.
  - Exit: UI and logs no longer collapse timeout into a generic conversion failure.

- **TASK-027**: Journal every owned staging artifact.
  - Record hidden output, temporary input, intermediate output, and backend work-directory paths before creation, keyed by job and app session.
  - Update journal state atomically and remove entries only after confirmed deletion or successful move.
  - Covers: `REQ-006`, `SEC-004`, `GUD-006`.
  - Exit: a crash leaves enough trusted metadata to identify only this app’s abandoned artifacts.

- **TASK-028**: Add a conservative startup artifact sweeper.
  - Delete only manifest-listed artifacts from a prior session after validating containment, ownership markers, age, and absence of an active matching job.
  - Quarantine or report ambiguous entries instead of deleting them.
  - Covers: `REQ-006`, `SEC-004`.
  - Depends on: `TASK-027`.
  - Exit: seeded unrelated dotfiles and sibling temp directories survive cleanup untouched.

- **TASK-029**: Coordinate application termination with queue shutdown.
  - Change termination handling to request cancellation, await the process supervisor and artifact cleanup for a bounded interval, then reply to AppKit termination.
  - If cleanup cannot finish, persist the journal and terminate without claiming completion.
  - Covers: `REQ-006`.
  - Depends on: `TASK-025`, `TASK-027`.
  - Exit: Quit during the process-tree fixture leaves no converter alive and a recoverable artifact journal.

### Phase 4: Enforce Conversion Semantics and Resource Budgets

- **GOAL-005**: Prevent accidental format loss, unbounded expansion, and stale-source execution.

#### Tasks

Primary implementation surface: `Sources/FileConverterNativeBackends/ImageIO/ImageIOBackend.swift`, `Sources/FileConverterNativeBackends/PDFKit/PDFKitBackend.swift`, `Sources/FileConverterCore/Formats/{FormatDetection,FormatRegistry}.swift`, and `Sources/FileConverterCore/Conversion/{BackendEvaluation,BackendResolver,ConversionQueue}.swift`. Modify ImageIO destination creation/frame loops, `PDFKitBackend.renderTextToPDF`, PDF page loops, `FormatDetector.detect`, and backend capability evaluation; add proposed `ConversionResourcePolicy`, `SourceFingerprint`, and `InputKind`.

- **TASK-030**: Define and enforce ImageIO frame semantics.
  - Classify outputs as single-frame or multi-frame-capable.
  - For animated/multi-page input to a single-frame format, either require an explicit first-frame policy or reject with guidance; never pass multiple frames to a single-frame destination accidentally.
  - Covers: `REQ-008`.
  - Exit: the two-frame GIF-to-JPEG fixture has a deterministic, documented result.

- **TASK-031**: Add image decode and encode safety checks.
  - Inspect width, height, frame count, bits per component, estimated decoded bytes, and aggregate pixel work before decoding all frames.
  - Use a warning tier for unusually large legitimate work and a high hard ceiling for memory-exhaustion risk.
  - Covers: `REQ-008`.
  - Exit: oversized fixtures fail before an unbounded allocation and ordinary large photos still convert.

- **TASK-032**: Add PDF page/output planning limits.
  - Compute page count and expected output count before rasterization, split, or per-page export.
  - Require explicit confirmation above a documented warning threshold and refuse only at a separately documented safety ceiling.
  - Covers: `REQ-008`, `REQ-009`.
  - Exit: a high-page-count split cannot create thousands of outputs without clear consent.

- **TASK-033**: Bound PDF loop memory with autorelease scopes.
  - Wrap each rendered page and each output-document iteration in an autorelease pool and release page-local images/data before continuing.
  - Keep progress and cancellation checks between pages.
  - Covers: `REQ-008`.
  - Exit: a multi-page stress test shows bounded resident-memory growth rather than roughly linear accumulation.

- **TASK-034**: Replace main-actor text printing with a worker-safe PDF renderer.
  - Parse text and layout immutable attributed content, paginate with Core Text, and write pages through Core Graphics/PDF APIs from a worker actor.
  - Preserve current paper size, margins, wrapping, font fallback, and text encoding behavior with golden-content tests.
  - Covers: `REQ-007`, `GUD-003`.
  - Exit: long text conversion leaves a main-actor responsiveness probe running while output remains semantically equivalent.

- **TASK-035**: Revalidate source properties immediately before backend resolution.
  - Verify existence, readability, regular-file or supported-package kind, nonzero size where the backend requires it, and the admission fingerprint.
  - If changed, redetect format and recompute compatibility instead of proceeding with stale assumptions.
  - Covers: `REQ-011`, `PAT-003`.
  - Exit: replace/delete/truncate/type-change fixtures fail or redetect before converter launch.

- **TASK-036**: Add explicit package capability to formats and backends.
  - Distinguish regular files, directory packages, and ordinary directories in detection and backend evaluation.
  - Mark only backends with a verified package input contract as supporting a given package type.
  - Covers: `REQ-012`, `CON-004`.
  - Exit: unsupported packages are rejected consistently, while an explicitly supported package path remains eligible.

### Phase 5: Unify Effective Settings and Repair PDF Workflows

- **GOAL-006**: Make saved options, global defaults, and per-job dialogs describe the same effective conversion.

#### Tasks

Primary implementation surface: `Sources/FileConverterCore/Models/ConversionPreset.swift`, new `Sources/FileConverterCore/Presets/EffectivePresetResolver.swift`, `Sources/FileConverterCore/Conversion/ConversionCoordinator.swift`, `Sources/FileConverterApp/AppState.swift`, and `Sources/FileConverterApp/UI/Dialogs/{PDFSplitDialogView,PDFCompressDialogView}.swift`. Add `EffectivePresetResolver.resolve(global:preset:context:)`, `ResolvedConversionSettings`, `SettingProvenance`, and `PDFBatchItem`; replace dialog submit paths and coordinator fallback logic with the resolved object.

- **TASK-037**: Define versioned inheritance semantics for preset fields.
  - Add explicit per-field states such as inherit, override(value), and automatic where three-state behavior is needed.
  - Migrate old presets using rules that preserve their observed behavior; record the schema version.
  - Covers: `REQ-010`, `CON-003`.
  - Exit: no `nil` or default value has an undocumented meaning.

- **TASK-038**: Implement the single effective-preset resolver.
  - Centralize resolution of output location, collision policy, metadata, quality, PDF options, backend selection, and performance settings.
  - Return both effective values and provenance so UI can say “From General settings” or “Overridden by this preset.”
  - Covers: `REQ-010`, `PAT-001`.
  - Depends on: `TASK-037`.
  - Exit: queue admission, preview, Finder request handling, and backend builders consume the same resolved object.

- **TASK-039**: Remove ad hoc General-versus-preset precedence from callers.
  - Delete duplicated fallback logic from app state, coordinator, queue, PDF dialogs, and backend builders after moving it to the resolver.
  - Add matrix tests for legacy, inherited, and explicit override combinations.
  - Covers: `REQ-010`.
  - Depends on: `TASK-038`.
  - Exit: there is one tested code path for every effective setting.

- **TASK-040**: Make PDF compression dialogs round-trip saved configuration.
  - Initialize every visible control from the effective preset, including compatibility and any advanced options the dialog exposes.
  - Preserve untouched values on submit and show inherited provenance without forcing a rewrite.
  - Covers: `REQ-009`, `REQ-010`.
  - Depends on: `TASK-038`.
  - Exit: open-and-confirm with no edits produces an equivalent resolved preset.

- **TASK-041**: Replace first-file-only PDF split state with a batch model.
  - Store per-input URL, page count, validity, selected ranges, expected outputs, and validation error.
  - Do not preview the first file as if it describes the whole batch.
  - Covers: `REQ-009`.
  - Exit: two PDFs with different page counts display and validate independently.

- **TASK-042**: Add editable PDF batch membership and per-file ranges.
  - Allow removal before enqueue, Select All/Clear, shared-range application only when valid for every target, and per-file override.
  - Preserve original file ordering.
  - Covers: `REQ-009`, `REQ-019`.
  - Depends on: `TASK-041`.
  - Exit: a user can exclude one accidental drop without cancelling the entire workflow.

- **TASK-043**: Add output-count and destination previews to PDF dialogs.
  - Show expected file count, naming examples, duplicate-name warnings, destination, and resource-limit warnings before conversion.
  - Recompute as ranges or naming options change.
  - Covers: `REQ-003`, `REQ-008`, `REQ-009`.
  - Depends on: `TASK-032`, `TASK-041`.
  - Exit: the dialog’s preview matches the output planner for every file in the batch.

- **TASK-044**: Consolidate PDF workflow validation and enqueue.
  - Validate all files, resolve effective settings once, generate the complete planned output set, and enqueue atomically only after confirmation.
  - If one input becomes invalid before enqueue, retain the dialog and identify that row.
  - Covers: `REQ-009`, `REQ-010`, `REQ-011`.
  - Depends on: `TASK-038`, `TASK-043`.
  - Exit: no subset is silently enqueued from a failed mixed-validity dialog.

### Phase 6: Make Finder IPC Durable, Bounded, and Host-Specific

- **GOAL-007**: Ensure Finder requests survive failures without leaking paths, launching the wrong app, or duplicating work.

#### Tasks

Primary implementation surface: `Sources/FileConverterCore/IPC/ConversionRequest.swift`, `Sources/FileConverterContracts/ConversionRequest.swift`, `Sources/FileConverterFinderSupport/{FinderRequestClient,FinderMenuCatalog}.swift`, `Sources/FileConverterFinderSync/FileConverterFinderSync.swift`, and `Sources/FileConverterCore/Conversion/ConversionCoordinator.swift`. Add proposed `ConversionJournal`, `JournalEntry`, `JournalState`, and `FinderHostResolver`; change `ConversionCoordinator.prepareFinderRequests`, request acknowledgement/receipt calls, relaunch drain, and Finder host-open logic.

- **TASK-045**: Define a versioned durable admission journal.
  - Record request ID, authenticated request digest, source bookmark references, resolved preset ID/version, job IDs, expected outputs, timestamps, and explicit lifecycle state.
  - Store atomically inside the existing shared trust boundary and cap record count/bytes.
  - Covers: `REQ-013`, `SEC-005`, `PAT-004`.
  - Exit: journal decode, migration, corruption, and capacity behavior are tested.

- **TASK-046**: Make admission durable before acknowledging the Finder request.
  - Write the admitted record and queue payload durably, then emit the processed receipt.
  - On write failure, leave the request pending or rejected with an actionable reason rather than acknowledging in-memory work.
  - Covers: `REQ-013`.
  - Depends on: `TASK-045`.
  - Exit: a crash injected after acknowledgement cannot erase the only record of accepted work.

- **TASK-047**: Persist job state transitions around execution and commit.
  - Mark `running` before backend launch, `committing` before final destination mutation, and `finished` only after outputs and receipts are durable.
  - Treat journal failure as a reliability error, not a logging-only event.
  - Covers: `REQ-013`, `PAT-004`.
  - Depends on: `TASK-045`.
  - Exit: crash injection at every transition produces a defined recovery state.

- **TASK-048**: Add conservative relaunch recovery.
  - Auto-restore `admitted` jobs only after source/bookmark revalidation.
  - Present `running` and `committing` jobs for review with discovered output evidence; never auto-run an ambiguous commit again.
  - Covers: `REQ-013`, `SEC-001`, `SEC-005`.
  - Depends on: `TASK-047`.
  - Exit: recovery avoids both silent loss and duplicate output generation.

- **TASK-049**: Enforce bounded request and bookmark retention.
  - Give pending, rejected, processed, expired, and recovery records explicit age/count/size limits.
  - Remove bookmarks as soon as no queued, recovery, or receipt action needs them; surface aggregate cleanup diagnostics without file paths.
  - Covers: `REQ-014`, `SEC-003`.
  - Exit: repeated unsupported Finder requests cannot grow storage without bound.

- **TASK-050**: Launch the extension’s containing host app deterministically.
  - Derive the enclosing `.app` from the running extension bundle and validate the host bundle identifier before opening it.
  - Use bundle-ID lookup only as a documented fallback when the extension is not embedded; detect and report ambiguity rather than picking an arbitrary copy.
  - Covers: `REQ-015`.
  - Exit: with two host copies installed, a request from one embedded extension opens that same containing copy.

- **TASK-051**: Align Finder and host classification messages.
  - Keep Finder’s fast extension/UTType eligibility as a preliminary filter.
  - When host content inspection disagrees, produce a stable rejection reason that names the mismatch and leaves the file untouched.
  - Covers: `REQ-012`, `CON-004`.
  - Exit: spoofed extensions and ambiguous files produce consistent, actionable feedback.

### Phase 7: Repair Queue, Workflow, Keyboard, and Accessibility Friction

- **GOAL-008**: Make common batch workflows legible, interruptible, and efficient for mouse, keyboard, and assistive-technology users.

#### Tasks

Primary implementation surface: `Sources/FileConverterApp/AppState.swift`, `Sources/FileConverterApp/UI/FileConverterMainView.swift`, `Sources/FileConverterApp/UI/Queue/{ConversionQueueView,JobRowView}.swift`, `Sources/FileConverterApp/Settings/{GeneralSettingsView,PresetEditorView}.swift`, and `Sources/FileConverterApp/Resources/Localizable.xcstrings`. Add proposed `WorkflowPresentationCoordinator`, queue presentation-state builders, SwiftUI `Commands`, accessibility modifiers, and notification/reveal result state; replace `openFilesDialog`'s silent guard and inconsistent pending-batch insertion.

- **TASK-052**: Split current-file progress from batch summary.
  - Show current item number/name and its progress separately from completed/total/failed/cancelled batch counts.
  - Reserve 100% Completed for a fully terminal successful batch; use “1 of 3 complete” during partial progress.
  - Covers: `REQ-016`.
  - Exit: all queue state combinations render mathematically consistent copy.

- **TASK-053**: Add semantic accessibility to settings and status controls.
  - Label sliders, steppers, pickers, toggles, icon-only buttons, progress views, and inherited-setting indicators.
  - Expose units, min/max/current values, consequences, and help text where the visible label is insufficient.
  - Covers: `REQ-017`.
  - Exit: Accessibility Inspector reports no unlabeled interactive controls in main, settings, collision, and PDF workflows.

- **TASK-054**: Add queue selection and keyboard actions.
  - Support row selection, arrow navigation, Return to reveal/open the primary output when safe, Command-R to retry eligible failures, Delete to remove terminal rows, and Escape to cancel only the explicitly selected active item after confirmation where warranted.
  - Never overload Escape as a collision resolution.
  - Covers: `REQ-017`, `REQ-019`.
  - Exit: a representative queue can be operated without a pointer.

- **TASK-055**: Centralize workflow presentation in a FIFO coordinator.
  - Replace front insertion for interrupted picker flows and append for normal flows with one documented queueing rule.
  - Preserve batch order and prevent a new sheet/dialog from replacing an active one.
  - Covers: `REQ-019`.
  - Exit: concurrent Add Files, drag/drop, Finder, and PDF-workflow events appear in stable order without loss.

- **TASK-056**: Make Add Files and related commands explain their disabled state.
  - Bind menu/toolbar enablement to active sheet, pending workflow, and discovery state.
  - If a menu command can still arrive, queue it or show the reason; never silently return.
  - Covers: `REQ-019`.
  - Depends on: `TASK-055`.
  - Exit: repeated Add Files activation during another workflow is either queued or visibly unavailable.

- **TASK-057**: Make backend discovery cancellable and observable.
  - Run discovery in a cancellable task, show which capability is being checked, allow returning to file selection without losing it, and cache the result only for the tool-installation fingerprint.
  - Covers: `REQ-019`, `REQ-020`.
  - Exit: Cancel during discovery promptly restores interactive state with no jobs admitted.

- **TASK-058**: Improve mixed-format batch admission.
  - Before preset selection, group inputs by detected category/compatible presets.
  - Offer one-click compatible subsets, “apply where compatible,” and explicit exclusion counts; retain a clear path to separate conversions.
  - Covers: `REQ-018`.
  - Exit: a mixed image/video/document drop does not require repeated trial-and-error dialogs.

- **TASK-059**: Make Cancel All and retry behavior proportionate.
  - Confirm only when the command will interrupt multiple active jobs or discard unresolved recovery decisions.
  - Clearing terminal jobs stays immediate and reversible where possible; failed rows retain error details and a labeled Retry action.
  - Covers: `REQ-019`, `GUD-004`.
  - Exit: destructive interruption is confirmed, while harmless cleanup is not burdened by a modal.

- **TASK-060**: Surface reveal and notification outcomes.
  - Show whether a notification was delivered, denied, or replaced by in-app status.
  - Provide per-file and per-batch Reveal actions based on actual committed URLs; if Finder activation fails, show a retryable error.
  - Covers: `REQ-019`, `SEC-003`.
  - Depends on: `TASK-020`.
  - Exit: users can always locate successful outputs without guessing whether a preference worked.

- **TASK-061**: Add notification-permission recovery in Settings.
  - Show authorization state and, when denied, a button that opens the app’s Notifications settings or explains how to restore permission.
  - Do not repeatedly prompt when the system will not show another prompt.
  - Covers: `REQ-019`.
  - Exit: denied users have an actionable recovery path.

- **TASK-062**: Expose hidden preset-filter selection and normalize terminology.
  - When filtering hides the active preset, show its name and a Clear Filter or Show Selected action.
  - Perform a localization-key audit so source file, input file, output file, destination, preset, skipped, cancelled, and waiting have stable meanings.
  - Covers: `REQ-017`, `REQ-019`.
  - Exit: filters never make selection state invisible, and equivalent states use the same term throughout.

### Phase 8: Reuse Detection and Probing Without Creating Stale State

- **GOAL-009**: Remove repeated expensive work while preserving correctness when files or tools change.

#### Tasks

Primary implementation surface: `Sources/FileConverterCore/Formats/FormatDetection.swift`, `Sources/FileConverterCore/Models/ConversionJob.swift`, `Sources/FileConverterCore/Conversion/BackendEvaluation.swift`, `Sources/FileConverterExternalBackends/FFmpeg/FFmpegBackend.swift`, `Sources/FileConverterFinderSupport/FinderMenuCatalog.swift`, and `Sources/FileConverterCore/Logging/AppLogger.swift`. Add proposed `DetectionSnapshot`, actor-isolated `MediaProbeCache`, snapshot modification metadata, and signpost helpers; thread snapshots through existing detect/probe callers.

- **TASK-063**: Introduce source fingerprints and detection snapshots.
  - Attach the detection result, fingerprint, and timestamp to admitted jobs.
  - Reuse it through dialogs, backend evaluation, and queue planning only while the fingerprint still matches.
  - Covers: `REQ-020`, `PAT-003`.
  - Exit: unchanged files are detected once per admission while mutated files force redetection.

- **TASK-064**: Share FFprobe/media metadata within a job lifecycle.
  - Cache stream metadata, duration, frame rate, dimensions, and codec observations in an actor keyed by source fingerprint.
  - Evict on mutation, cancellation, completion, or a small bounded LRU limit.
  - Covers: `REQ-020`.
  - Depends on: `TASK-063`.
  - Exit: backend evaluation and conversion planning do not launch duplicate probes for one unchanged source.

- **TASK-065**: Gate Finder snapshot reloads on file metadata.
  - Preserve the in-memory decoded catalog across menu requests and check cheap modification metadata before rereading/decoding the JSON snapshot.
  - Fall back to the last valid snapshot on a transient partial read and retry later.
  - Covers: `REQ-020`, `CON-004`.
  - Exit: repeated unchanged context-menu openings do not repeatedly decode the snapshot.

- **TASK-066**: Add targeted signposts and performance assertions.
  - Instrument detection, probing, PDF planning, external-tool discovery, output reservation, and main-actor stalls without logging file paths.
  - Establish batch-size and document-size scenarios that fail only on material regressions, not noisy microbenchmarks.
  - Covers: `REQ-020`, `SEC-003`.
  - Exit: optimization claims can be demonstrated with before/after measurements.

### Phase 9: Align SwiftPM, Xcode, Extension, Packaging, and Release Validation

- **GOAL-010**: Make the production build graph enforce the same language, concurrency, entitlement, and integration assumptions as tests.

#### Tasks

Primary implementation surface: `Package.swift`, `project.yml`, generated `FileConverter.xcodeproj/project.pbxproj`, app/extension entitlement files under `Sources/FileConverterApp/` and `Sources/FileConverterFinderSync/`, `.github/workflows/`, `Tests/FileConverterTests/ArchitectureBoundaryTests.swift`, and `Scripts/package_app.sh`. Modify Swift language/concurrency settings, shared schemes, test targets, entitlement checks, and packaging verification; keep `project.yml` authoritative for generated project settings.

- **TASK-067**: Move SwiftPM targets to explicit Swift 6 language mode.
  - Update the tools/language declaration and address every resulting Sendable, actor-isolation, and captured-mutable-state diagnostic without adding unsafe blanket suppressions.
  - Covers: `REQ-022`.
  - Exit: `swift build` and `swift test` compile package modules in Swift 6 mode with no new concurrency warnings.

- **TASK-068**: Align Xcode compiler settings across products and configurations.
  - Compare generated/project settings for Swift version, strict concurrency, upcoming features, deployment target, warnings-as-errors policy, optimization, and testability.
  - Keep app and extension settings intentional rather than inheriting divergent defaults.
  - Covers: `REQ-022`.
  - Exit: Debug and Release build-setting dumps document the same intended baseline.

- **TASK-069**: Add focused sandbox and security-scope integration tests.
  - Build a sandboxed test host or dedicated scheme that covers open-panel URLs, bookmarks, collision pause/retry, relaunch, stale bookmark refresh, and permission revocation.
  - Do not enable production sandboxing as a side effect of writing the test.
  - Covers: `REQ-011`, `CON-005`.
  - Exit: lease behavior is proven in an environment where scope actually matters.

- **TASK-070**: Validate entitlements and app-group contracts structurally.
  - Compare Debug/Release app and extension entitlements, application groups, signing identifiers, extension point, and shared container paths.
  - Fail packaging when host and extension disagree.
  - Covers: `REQ-013`, `REQ-015`, `REQ-022`.
  - Exit: packaged signatures and entitlements match the intended cross-process contract.

- **TASK-071**: Expand continuous integration to real Xcode products.
  - Run SwiftPM build/test plus Xcode Debug and Release builds for the shared scheme, Finder extension compilation, and package-script verification.
  - Archive logs and test results; do not treat a SwiftPM pass as proof of app validity.
  - Covers: `REQ-022`, `REQ-023`.
  - Exit: every push validates both package and application graphs.

- **TASK-072**: Add static boundary checks for dangerous regressions.
  - Fail CI if production code creates unmanaged `Process` instances, forwards arbitrary preset dictionary keys as flags, uses job-wide overwrite escalation, or saves presets from recovery state.
  - Prefer small architecture tests over brittle text matching where possible.
  - Covers: `REQ-001`, `REQ-002`, `REQ-004`, `REQ-005`.
  - Exit: the repaired invariants are difficult to bypass accidentally.

- **TASK-073**: Run packaged-artifact smoke tests without replacing the installed app.
  - Launch the newly packaged app from a unique test path and isolated data container/configuration, verify embedded extension metadata and bundled resources, and perform a non-destructive conversion matrix.
  - Installation/replacement remains a separate user-authorized operation.
  - Covers: `REQ-022`, `REQ-023`.
  - Exit: the distributable artifact, not only `.build` products, completes the smoke suite.

### Phase 10: End-to-End Qualification and Controlled Rollout

- **GOAL-011**: Prove the combined repair under realistic batch, failure, accessibility, and relaunch scenarios before distribution.

#### Tasks

Primary implementation surface: the complete test suites under `Tests/`, the packaged application under an isolated temporary output path, Accessibility Inspector/VoiceOver runtime checks, and a release-evidence document created alongside the eventual implementation change. Exercise public workflows through `AppState`, `ConversionCoordinator`, `ConversionQueue`, Finder menu callbacks, and `AppDelegate` termination; do not replace the installed app as part of this phase.

- **TASK-074**: Run the complete automated matrix.
  - Execute all tests from Section 6 across SwiftPM and Xcode lanes, including repeated race tests and process cleanup assertions.
  - Investigate any flaky result as a product defect; do not add retries to hide it.
  - Covers: `REQ-023`.
  - Exit: all deterministic suites pass from a clean derived-data/build state.

- **TASK-075**: Run runtime workflow qualification.
  - Exercise add panel, drag/drop, mixed batches, PDF dialogs, collisions, keep-both races, replace-if-newer, cancellation, retry, reveal, denied notifications, Finder menu, host launch, relaunch recovery, and Quit during conversion.
  - Capture what was actually observed and distinguish it from source inference.
  - Covers: all functional requirements.
  - Exit: every accepted finding has a runtime or focused test verification record.

- **TASK-076**: Run accessibility and keyboard qualification.
  - Use Accessibility Inspector and VoiceOver on the main window, settings, collision sheet, PDF workflows, queue, errors, and recovery UI.
  - Verify full keyboard access, focus order, Escape/Return semantics, and window resizing at the supported minimum size.
  - Covers: `REQ-017`.
  - Exit: no core workflow requires pointer-only discovery or unlabeled controls.

- **TASK-077**: Run performance and resource qualification.
  - Test large images, animated inputs, high-page-count PDFs, long text, 100-file mixed batches, slow external tools, and repeated Finder menus.
  - Record main-thread stalls, peak resident memory, process count, temp footprint, detection/probe counts, and cleanup time.
  - Covers: `REQ-007`, `REQ-008`, `REQ-020`.
  - Exit: measured budgets are met and documented.

- **TASK-078**: Perform migration and rollback rehearsal.
  - Copy representative current preset/request data into an isolated profile, launch the new build, validate migration and export, then verify the prior build can still start without having its only data copy destroyed.
  - Covers: `REQ-001`, `CON-003`.
  - Exit: migration is non-destructive and backups are discoverable.

- **TASK-079**: Produce a release decision record.
  - Summarize passed evidence, residual risks, behavior changes, migration notes, and any intentionally deferred unconfirmed investigations.
  - Block release on any unresolved data-loss, unauthorized-overwrite, process-leak, or preset-corruption regression.
  - Covers: `REQ-023`.
  - Exit: release approval is tied to evidence, not an aggregate build status.

## 3. Alternatives

- **ALT-001**: Continue using a job-wide overwrite policy and merely list all current conflicts. Rejected because destinations can appear or change after the dialog; authorization must bind to destination identity and observed state.
- **ALT-002**: Move `NSPrintOperation.run()` to a detached/background thread. Rejected because `NSPrintOperation` is main-actor isolated in the current SDK; this trades UI blocking for an unsupported isolation violation. A Core Text/Core Graphics renderer gives real off-main work.
- **ALT-003**: Sandbox the main app immediately to expose security-scope defects. Rejected as a first step because it materially changes process execution and file access at the same time. Add a sandboxed integration lane first, then decide product entitlement changes separately.
- **ALT-004**: Reject every file package at admission. Rejected because package formats can be legitimate converter inputs; capability must be explicit per format/backend.
- **ALT-005**: Let unknown preset JSON continue to populate `extraBackendOptions` after filtering suspicious characters. Rejected because character filtering cannot establish semantic safety for command-line options; use typed allowlists and inert round-tripping.
- **ALT-006**: Acknowledge Finder requests immediately and periodically serialize the in-memory queue. Rejected because there is still a crash window after acknowledgement; durable admission must precede the receipt.
- **ALT-007**: Auto-resume every journaled job after a crash. Rejected because a crash during final commit can make execution state ambiguous and auto-resume can duplicate or replace output.
- **ALT-008**: Add low universal page/file-size limits. Rejected because compressed files and legitimate technical documents vary widely. Use estimated decoded work, warnings, cancellation, and high safety ceilings.
- **ALT-009**: Run content-signature probing inside the Finder extension. Rejected because Finder callbacks should stay fast and metadata-only; authoritative validation belongs in the host.
- **ALT-010**: Add blanket confirmation to every Cancel All action. Rejected because clearing completed rows is low risk. Confirm interruption of multiple active jobs or unresolved recovery state only.
- **ALT-011**: Perform all phases as one queue/preset rewrite. Rejected because it expands regression scope and prevents phase-by-phase verification of the highest-risk invariants.

## 4. Dependencies

- **DEP-001**: Apple Foundation, `NSFileCoordinator`, URL resource values, bookmarks, and security-scoped resource APIs.
- **DEP-002**: Apple Swift Concurrency and the Swift 6 compiler/toolchain used by both SwiftPM and Xcode.
- **DEP-003**: AppKit and SwiftUI for lifecycle, sheets, settings, keyboard commands, accessibility, and notification-settings navigation.
- **DEP-004**: Core Graphics and Core Text for worker-safe text-to-PDF pagination/rendering.
- **DEP-005**: PDFKit, ImageIO, Uniform Type Identifiers, AVFoundation, and existing native conversion frameworks.
- **DEP-006**: The existing app-group IPC authentication, Finder snapshot, request, receipt, and bookmark contracts.
- **DEP-007**: Existing optional external tools: FFmpeg/FFprobe, ImageMagick, LibreOffice, Ghostscript, and Calibre; tests must substitute deterministic fixtures.
- **DEP-008**: Xcode project generation from `project.yml`, shared scheme configuration, and `Scripts/package_app.sh`.
- **DEP-009**: XCTest plus an Xcode UI/accessibility test target or equivalent test host added within the current project.
- **DEP-010**: No new third-party runtime library is planned.

## 5. Files

- **FILE-001**: `Package.swift` — Swift tools/language mode, target settings, and package test wiring.
- **FILE-002**: `project.yml` — shared Swift/concurrency settings, schemes, test host, entitlements, and generated-project source of truth.
- **FILE-003**: `FileConverter.xcodeproj/project.pbxproj` — regenerated output; verify but do not hand-edit independently of `project.yml`.
- **FILE-004**: `Sources/FileConverterCore/Presets/PresetStore.swift` — fail-closed state, mutation errors, backup recovery, and atomic persistence.
- **FILE-005**: `Sources/FileConverterCore/Presets/PresetExchange.swift` — inert unknown JSON, import validation, schema migration, and privacy-safe exports.
- **FILE-006**: `Sources/FileConverterCore/Presets/PresetValidator.swift` — typed backend/container/compatibility validation.
- **FILE-007**: `Sources/FileConverterCore/Models/ConversionPreset.swift` — explicit inheritance, typed advanced options, schema version, and opaque fields.
- **FILE-008**: `Sources/FileConverterCore/Presets/PresetEditorStateController.swift` — inherited/override state and round-trip guarantees.
- **FILE-009**: `Sources/FileConverterCore/Files/OutputNamingEngine.swift` — complete collision planning, canonical keys, coordinated commit, and actual result URLs.
- **FILE-010**: `Sources/FileConverterCore/Files/SecurityScopedLease.swift` — active-state observability and explicit ownership/transfer support.
- **FILE-011**: `Sources/FileConverterCore/Files/FileAccessManager.swift` — bookmark refresh, lease reacquisition, and source validation.
- **FILE-012**: `Sources/FileConverterCore/Models/ConversionJob.swift` — source fingerprint, exact collision plan, journal IDs, and resolved configuration.
- **FILE-013**: `Sources/FileConverterCore/Models/ConversionError.swift` — typed timeout, policy-limit, source-changed, recovery, and authorization errors.
- **FILE-014**: `Sources/FileConverterCore/Conversion/ConversionQueue.swift` — pause/retry ownership, revalidation, state transitions, cancellation, and accurate status.
- **FILE-015**: `Sources/FileConverterCore/Conversion/ConversionCoordinator.swift` — durable admission, effective settings, workflow/job creation, and Finder acknowledgement ordering.
- **FILE-016**: `Sources/FileConverterCore/Conversion/BackendEvaluation.swift` — file/package capability and cached detection/probe consumption.
- **FILE-017**: `Sources/FileConverterCore/Conversion/BackendResolver.swift` — authoritative compatibility after source mutation or Finder mismatch.
- **FILE-018**: `Sources/FileConverterCore/Formats/FormatDetection.swift` — source fingerprint and regular-file/package distinction.
- **FILE-019**: `Sources/FileConverterCore/Formats/FormatRegistry.swift` — package capability and container compatibility metadata.
- **FILE-020**: `Sources/FileConverterExternalBackends/ExternalProcessRunner.swift` — central supervision, null stdin, deadlines, signals, process trees, and bounded diagnostics.
- **FILE-021**: `Sources/FileConverterExternalBackends/ExternalToolDiscovery.swift` — cancellable discovery and tool-installation fingerprinting.
- **FILE-022**: `Sources/FileConverterExternalBackends/FFmpeg/FFmpegBackend.swift` — typed options, probe reuse, and supervisor adoption.
- **FILE-023**: `Sources/FileConverterExternalBackends/ImageMagick/ImageMagickBackend.swift` — typed options, deadline, and supervisor adoption.
- **FILE-024**: `Sources/FileConverterExternalBackends/LibreOffice/LibreOfficeBackend.swift` — deadline and supervisor adoption.
- **FILE-025**: `Sources/FileConverterExternalBackends/Ghostscript/GhostscriptBackend.swift` — compatibility allowlist, deadline, and supervisor adoption.
- **FILE-026**: `Sources/FileConverterExternalBackends/Calibre/CalibreBackend.swift` — standardized supervision and typed failures.
- **FILE-027**: `Sources/FileConverterNativeBackends/ImageIO/ImageIOBackend.swift` — frame policy, pixel/memory limits, and autorelease scopes.
- **FILE-028**: `Sources/FileConverterNativeBackends/PDFKit/PDFKitBackend.swift` — page/output policy, autorelease scopes, and Core Text/Core Graphics text rendering.
- **FILE-029**: `Sources/FileConverterApp/AppState.swift` — workflow FIFO, resolved settings, discovery task, dialogs, notification/reveal status, and recovery state.
- **FILE-030**: `Sources/FileConverterApp/AppMain.swift` — coordinated termination and app lifecycle recovery.
- **FILE-031**: `Sources/FileConverterApp/UI/FileConverterMainView.swift` — add-file command state, workflow presentation, and mixed-batch UX.
- **FILE-032**: `Sources/FileConverterApp/UI/Dialogs/PDFSplitDialogView.swift` — per-file batch state, removal, ranges, previews, and thresholds.
- **FILE-033**: `Sources/FileConverterApp/UI/Dialogs/PDFCompressDialogView.swift` — complete configuration round-trip and inheritance provenance.
- **FILE-034**: `Sources/FileConverterApp/UI/Queue/ConversionQueueView.swift` — batch/current progress, selection, keyboard actions, and bulk cancellation.
- **FILE-035**: `Sources/FileConverterApp/UI/Queue/JobRowView.swift` — accessible actions, actual output URLs, retry, and reveal status.
- **FILE-036**: `Sources/FileConverterApp/Settings/GeneralSettingsView.swift` — notification recovery and accessible settings controls.
- **FILE-037**: `Sources/FileConverterApp/Settings/PresetEditorView.swift` — explicit inheritance and filter-hidden selection feedback.
- **FILE-038**: `Sources/FileConverterApp/Resources/Localizable.xcstrings` — consistent terminology and new error/recovery strings.
- **FILE-039**: `Sources/FileConverterContracts/ConversionRequest.swift` — versioned durable request/admission metadata if the shared contract needs extension.
- **FILE-040**: `Sources/FileConverterContracts/FinderMenuSnapshot.swift` — versioned capability/package metadata if needed.
- **FILE-041**: `Sources/FileConverterCore/IPC/ConversionRequest.swift` — durable journal, retention, recovery, and receipt sequencing.
- **FILE-042**: `Sources/FileConverterFinderSupport/FinderRequestClient.swift` — containing-host launch, acknowledgement/retry, and bounded request lifecycle.
- **FILE-043**: `Sources/FileConverterFinderSupport/FinderMenuCatalog.swift` — modification-gated snapshot refresh and last-valid fallback.
- **FILE-044**: `Sources/FileConverterFinderSync/FileConverterFinderSync.swift` — metadata-only classification, host launch integration, and mismatch handoff.
- **FILE-045**: `Tests/FileConverterTests/PresetEngineTests.swift` and `PresetImportExportTests.swift` — corruption, recovery, migration, injection, and export privacy.
- **FILE-046**: `Tests/FileConverterTests/OutputNamingTests.swift` and `ConversionQueueTests.swift` — complete conflict sets, exact authorization, TOCTOU, lease ownership, and progress.
- **FILE-047**: `Tests/FileConverterTests/ExternalBackendProcessTests.swift` — stdin, timeout, process-tree, cancellation, and bounded diagnostic fixtures.
- **FILE-048**: `Tests/FileConverterTests/PDFWorkflowTests.swift` and `PDFKitBackendTextRenderingTests.swift` — batch state, limits, memory, text rendering, and main-actor responsiveness.
- **FILE-049**: `Tests/FileConverterTests/FormatDetectionEdgeCaseTests.swift` and `BackendIsolationTests.swift` — package kinds, source mutation, detection reuse, and backend capability.
- **FILE-050**: `Tests/FileConverterTests/FinderIPCDrainTests.swift`, `FinderMenuTests.swift`, and `Tests/FileConverterFinderSupportTests/FinderMenuCatalogTests.swift` — durable admission, recovery, retention, containing-host launch, and snapshot caching.
- **FILE-051**: `.github/workflows/ci.yml` or the existing workflow files — SwiftPM, Xcode app, extension, packaging, and architecture-check lanes.
- **FILE-052**: `Scripts/package_app.sh` — packaged entitlement validation and isolated smoke-test hooks.
- **FILE-053**: New focused files under existing modules — `EffectivePresetResolver`, `SourceFingerprint`, `ExternalProcessSupervisor`, `ConversionJournal`, and artifact-manifest types should each live in the narrowest existing target rather than in a new umbrella module.

## 6. Testing

- **TEST-001**: Preset fail-closed suite — corrupt, unreadable, schema-invalid, and interrupted-save primary files cannot become a writable empty store.
- **TEST-002**: Preset recovery suite — valid/invalid backup selection, retained damaged copy, failed restore, explicit Start Fresh, and relaunch.
- **TEST-003**: Preset import trust suite — unknown JSON round-trips inertly; arbitrary flags, invalid containers, control characters, and invalid PDF compatibility are rejected before enqueue.
- **TEST-004**: Preset export privacy suite — default exports contain no absolute local path, bookmark blob, or sensitive recent-file metadata.
- **TEST-005**: Collision-set suite — every existing/reserved output in a multi-output job appears in one deterministic plan.
- **TEST-006**: Exact overwrite authorization suite — only displayed, unchanged destination identities can be replaced; new or changed collisions reprompt.
- **TEST-007**: Destination race suite — concurrent keep-both creators retry safely and replace-if-newer rechecks metadata within coordination.
- **TEST-008**: Security-scope lifecycle suite — active lease transfer or clear-and-reacquire across collision pause, cancellation, retry, and sandboxed relaunch.
- **TEST-009**: External-process deadline suite — null stdin, probe/conversion timeout, typed errors, bounded stderr, and no hung pipe readers.
- **TEST-010**: Process-tree cancellation suite — graceful termination, forced escalation, child reaping, Quit, and no surviving converter PID.
- **TEST-011**: Artifact-manifest suite — success/cancel/crash bookkeeping, safe startup deletion, ambiguity quarantine, and unrelated-file preservation.
- **TEST-012**: Image frame/resource suite — animated-to-single-frame policy, supported multi-frame conversion, dimension/pixel ceilings, warning tier, cancellation, and memory behavior.
- **TEST-013**: PDF resource suite — page/output thresholds, cancellation between pages, per-page autorelease behavior, and no partial destination commit.
- **TEST-014**: Text-to-PDF equivalence/responsiveness suite — page size, margins, wrapping, Unicode/font fallback, output text extraction, and main-actor heartbeat during long input.
- **TEST-015**: Source revalidation suite — deletion, truncation, regular-file-to-directory/package change, content mutation, unreadable source, and stale bookmark.
- **TEST-016**: Package capability suite — Finder preliminary eligibility, host authoritative rejection, explicitly supported package input, and ordinary-directory rejection.
- **TEST-017**: Effective-setting matrix — global defaults, preset inheritance, explicit overrides, legacy migration, Finder execution, PDF dialogs, and backend argument equality.
- **TEST-018**: PDF batch suite — heterogeneous page counts, per-file range validation, removal, ordering, expected output count, naming collisions, and atomic enqueue.
- **TEST-019**: Durable Finder admission suite — crash before/after journal write and acknowledgement, duplicate delivery, authenticated replay, capacity, and corruption.
- **TEST-020**: Relaunch recovery suite — admitted restore, running review, ambiguous committing state, finished cleanup, revoked bookmarks, and no duplicate output.
- **TEST-021**: Finder retention/launch suite — bounded rejected-request storage, bookmark release, two installed host copies, containing-bundle selection, and ambiguous fallback.
- **TEST-022**: Queue presentation suite — current item versus batch counts, partial failure, cancellation, retry eligibility, actual committed paths, and 100% wording.
- **TEST-023**: Keyboard/accessibility suite — focus order, labels/values/hints, Return/Escape behavior, selection, retry, reveal, collision review, and minimum-window layout.
- **TEST-024**: Workflow coordinator suite — simultaneous add panel, drag/drop, Finder, PDF dialog, discovery cancellation, FIFO order, and no lost presentation.
- **TEST-025**: Mixed-batch suite — compatibility grouping, apply-where-compatible, explicit exclusion counts, and preserved source order.
- **TEST-026**: Notification/reveal suite — authorized/denied notifications, Settings recovery link, per-file and batch reveal, Finder activation failure, and no path disclosure in notification text by default.
- **TEST-027**: Detection/probe cache suite — one detection/probe for an unchanged source, invalidation on fingerprint/tool change, bounded eviction, and no cross-file collision.
- **TEST-028**: SwiftPM compiler suite — Swift 6 build/test with strict concurrency diagnostics treated according to project policy.
- **TEST-029**: Xcode product suite — Debug and Release app builds, Finder extension build, test host, build-setting audit, and unsandboxed/sandboxed lane distinction.
- **TEST-030**: Packaged-artifact suite — package script, code signatures, entitlements, embedded extension, resources/localization, isolated launch, and non-destructive conversion smoke matrix.
- **TEST-031**: Runtime adversarial suite — 100-file batches, large/animated images, high-page PDFs, very long text, slow/crashing tools, destination mutation, Quit, and relaunch.
- **TEST-032**: Regression suite — all preexisting tests remain enabled, with changed expectations justified by a named requirement rather than deleted or weakened assertions.

## 7. Risks & Assumptions

- **RISK-001**: Changing preset mutation APIs touches many UI call sites. Mitigation: land explicit store state first, then migrate one mutation family at a time while fail-closed tests stay active.
- **RISK-002**: Canonical destination identity varies by filesystem, case sensitivity, Unicode normalization, aliases, and network volumes. Mitigation: keep display paths separate, prefer filesystem resource identifiers when available, and test case-sensitive plus case-insensitive volumes.
- **RISK-003**: `NSFileCoordinator` callbacks are synchronous and can block. Mitigation: perform them off the main actor, keep accessor bodies narrow, use delivered URLs, and never nest unsupported coordination calls.
- **RISK-004**: Process-group termination behavior differs for bundled, shell-wrapped, and helper-spawning tools. Mitigation: fixture each behavior, avoid shells, record child identity where possible, and retain bounded startup cleanup.
- **RISK-005**: Resource ceilings may reject legitimate unusually large work. Mitigation: separate warning and hard tiers, base them on estimated decoded work, document them, and make only non-safety thresholds configurable.
- **RISK-006**: Replacing AppKit text printing may change typography or pagination. Mitigation: extract current behavior fixtures before replacement and compare page count, dimensions, margins, text extraction, and representative rendering.
- **RISK-007**: Durable recovery can duplicate work if commit state is inferred incorrectly. Mitigation: explicit pre/post-commit states, actual output evidence, and manual review for ambiguous `committing` records.
- **RISK-008**: Swift 6 migration may reveal broad isolation debt across test doubles and AppKit boundaries. Mitigation: separate model workers from main-actor UI, avoid `@unchecked Sendable` except for a documented audited wrapper, and keep each target green as it migrates.
- **RISK-009**: Finder host launch tests can be environment-sensitive. Mitigation: add unit-testable containing-bundle resolution and reserve multi-copy runtime validation for an isolated fixture directory.
- **RISK-010**: App-group retention cleanup could remove records another live process still needs. Mitigation: session IDs, lifecycle states, age grace periods, atomic coordination, and manifest-only deletion.
- **RISK-011**: Adding provenance/inheritance can make the preset editor visually busy. Mitigation: expose concise secondary labels and progressive disclosure rather than duplicating every global control.
- **RISK-012**: Caching can reintroduce stale-state defects. Mitigation: fingerprint every cache key, keep cache ownership bounded to batch/job/tool-installation lifetimes, and revalidate at execution.
- **ASSUMPTION-001**: The current product baseline remains macOS 14 or later and supports both Apple silicon and Intel architectures represented by the project.
- **ASSUMPTION-002**: The existing 256 tests are the current baseline observed during this review; the exact count must be recaptured at implementation start.
- **ASSUMPTION-003**: Preset files already in the field may contain unknown properties and machine-local paths, so migration must preserve opaque data while preventing execution and default re-export of sensitive values.
- **ASSUMPTION-004**: The main app remains unsandboxed for the initial phases; security-scope behavior still requires repair and a sandboxed integration lane because the current runtime masks failures.
- **ASSUMPTION-005**: External converters remain optional user-installed tools, and the app must behave correctly when any one is missing, replaced, upgraded, slow, or incompatible.
- **ASSUMPTION-006**: Finder integration uses the existing shared app-group/request architecture and can be extended compatibly rather than replaced with a new XPC service in this plan.
- **ASSUMPTION-007**: Installing or replacing the user’s current File Converter app is outside this implementation plan and requires separate explicit authorization after packaged validation.
- **ASSUMPTION-008**: The unconfirmed audit items remain investigation targets, not accepted defects, until a focused reproduction or runtime observation establishes them.

## 8. Related Specifications / Further Reading

- [Apple: NSPrintOperation](https://developer.apple.com/documentation/appkit/nsprintoperation/) — the current SDK declares the class `@MainActor`, which is why this plan replaces the rendering path instead of calling it from a detached thread.
- [Apple: Coordinating a write with NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28writingitemat%3Aoptions%3Aerror%3Abyaccessor%3A%29) — final checks and mutations must use the coordinated URL and account for synchronous execution.
- [Apple: Coordinating a read and write](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28readingitemat%3Aoptions%3Awritingitemat%3Aoptions%3Aerror%3Abyaccessor%3A%29) — basis for commit-time replace-if-newer comparison.
- [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) — bookmark resolution, stale bookmark refresh, and balanced scoped access.
- `ARCHITECTURE.md` — current module boundaries and conversion flow.
- `README.md` — currently documented user workflows and supported formats.
- `SECURITY.md` — repository security policy and trust assumptions.
- The supplied adversarial report at `/Users/fawaz/.codex/attachments/ebe7bc00-ad78-4a0a-9ddd-1a9c6b4368ba/Pasted text.txt` — source of the reconciled H/M/L/C and QoL observations.
