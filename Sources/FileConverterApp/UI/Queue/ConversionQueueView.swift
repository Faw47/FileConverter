import SwiftUI
import FileConverterCore

public struct ConversionQueueView: View {
    @ObservedObject var queue = ConversionQueue.shared
    @EnvironmentObject var appState: AppState

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Overall Header Bar
            if !queue.jobs.isEmpty {
                headerBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                Divider()
            }

            if queue.jobs.isEmpty {
                emptyQueueView
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.jobs) { job in
                            JobRowView(job: job)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(queue.completedCount) of \(queue.jobs.count) Completed")
                        .font(.system(size: 13, weight: .semibold))

                    if queue.failedCount > 0 {
                        Text("(\(queue.failedCount) failed)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                    if queue.cancelledCount > 0 {
                        Text("(\(queue.cancelledCount) cancelled)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: queue.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
            }

            Spacer()

            if queue.activeCount > 0 || queue.queuedCount > 0 {
                Button("Cancel All") {
                    queue.cancelAll()
                }
                .controlSize(.small)
            }

            if queue.completedCount > 0 || queue.failedCount > 0 || queue.cancelledCount > 0 {
                Button("Clear Finished") {
                    queue.clearCompleted()
                }
                .controlSize(.small)
            }
        }
    }

    private var emptyQueueView: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.6))

            VStack(spacing: 4) {
                Text("No Conversions in Progress")
                    .font(.system(size: 15, weight: .semibold))

                Text("Right-click any file in Finder and select **File Converter**, or drop files here.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
