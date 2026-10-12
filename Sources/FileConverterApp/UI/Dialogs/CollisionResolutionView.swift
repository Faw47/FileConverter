import FileConverterCore
import SwiftUI

/// Lists every conversion waiting because its output already exists. It reads
/// the queue live, so each button acts on exactly the row it sits in and the
/// sheet closes itself once nothing is left to decide.
struct CollisionResolutionView: View {
    @ObservedObject var queue: ConversionQueue
    var onFinished: () -> Void

    @State private var confirmingReplaceAll = false

    private var conflicts: [ConversionQueue.CollisionConflict] {
        queue.pendingCollisions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflicts.count == 1 ? "A File Already Exists" : "\(conflicts.count) Files Already Exist")
                    .font(.title3.weight(.semibold))
                Text("Nothing is changed until you choose. Replaced files are moved to the Trash.")
                    .foregroundStyle(.secondary)
            }

            List(conflicts) { conflict in
                CollisionRow(conflict: conflict) { decision in
                    queue.resolveCollisions(decision, jobIDs: [conflict.jobID])
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 160)

            HStack {
                Button("Cancel") {
                    for conflict in conflicts {
                        queue.cancelJob(id: conflict.jobID)
                    }
                    onFinished()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel collision resolution")
                .help("Cancel these conversions")

                Spacer()

                if conflicts.count > 1 {
                    Button("Skip All") {
                        queue.resolveCollisions(.skip, applyToAll: true)
                    }
                    .accessibilityLabel("Skip all conflicting files")
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
        }
        .padding(20)
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
