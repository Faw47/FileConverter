import FileConverterCore
import SwiftUI

/// Lists every conversion waiting because its output already exists. It reads
/// the queue live, so each button acts on exactly the row it sits in and the
/// sheet closes itself once nothing is left to decide.
struct CollisionResolutionView: View {
    @Bindable var queue: ConversionQueue
    var onFinished: () -> Void

    @State private var confirmingReplaceAll = false

    private var conflicts: [ConversionQueue.CollisionConflict] {
        queue.pendingCollisions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflicts.count == 1 ? "A File Already Exists" : "\(conflicts.count) Files Already Exist")
                    .font(.title3.weight(.semibold))
                Text("Nothing is changed until you choose. Replaced files are moved to the Trash.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            List(conflicts) { conflict in
                CollisionRow(conflict: conflict) { decision in
                    queue.resolveCollisions(decision, jobIDs: [conflict.jobID])
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 160)
            .edgeBar(.bottom, style: .sheet) { actions }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 320)
        .onChange(of: conflicts.isEmpty) { _, isEmpty in
            if isEmpty { onFinished() }
        }
        .onAppear {
            if conflicts.isEmpty { onFinished() }
        }
        .alert(
            "Replace \(conflicts.count) existing files?",
            isPresented: $confirmingReplaceAll
        ) {
            Button("Replace All", role: .destructive) {
                queue.resolveCollisions(.replace, applyToAll: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The existing files will be moved to the Trash.")
        }
    }

    private var actions: some View {
        HStack {
            // Says what it does: these conversions stop. Nothing on disk
            // changes either way. No shortcut: Esc must not stop anything.
            Button(conflicts.count == 1 ? "Cancel Conversion" : "Cancel Conversions") {
                for conflict in conflicts {
                    queue.cancelJob(id: conflict.jobID)
                }
                onFinished()
            }
            .help("Stop converting these files; existing files are left as they are")

            Spacer()

            // Esc skips: the existing files stay and nothing new is written.
            Button(conflicts.count == 1 ? "Skip" : "Skip All") {
                queue.resolveCollisions(.skip, applyToAll: true)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(conflicts.count == 1 ? "Skip this file" : "Skip all conflicting files")

            if conflicts.count > 1 {
                Button("Keep Both for All") {
                    queue.resolveCollisions(.keepBoth, applyToAll: true)
                }
                .accessibilityLabel("Keep both files for all conflicts")
                Button("Replace All…") {
                    confirmingReplaceAll = true
                }
                .accessibilityLabel("Replace all existing files")
            }
        }
        .edgeBarButtonStyle()
    }
}

private struct CollisionRow: View {
    let conflict: ConversionQueue.CollisionConflict
    let decide: (ConversionQueue.CollisionDecision) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conflict.sourceFilename)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ForEach(conflict.conflictingURLs, id: \.self) { url in
                    Text(existsText(for: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
            }
            Spacer(minLength: 8)
            Button("Skip") { decide(.skip) }
                .accessibilityLabel("Skip \(conflict.sourceFilename)")
            Button("Keep Both") { decide(.keepBoth) }
                .accessibilityLabel("Keep both files for \(conflict.sourceFilename)")
            Button("Replace") { decide(.replace) }
                .accessibilityLabel("Replace the existing file for \(conflict.sourceFilename)")
        }
        .controlSize(.small)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conflict for \(conflict.sourceFilename)")
    }

    private func existsText(for url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return "“\(url.lastPathComponent)” already exists in \(folder)"
    }
}
