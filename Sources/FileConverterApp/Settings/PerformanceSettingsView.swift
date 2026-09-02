import SwiftUI
import FileConverterCore

public struct PerformanceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var queue = ConversionQueue.shared
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    public init() {}

    public var body: some View {
        Form {
            Section {
                Stepper(
                    "Maximum parallel conversions: \(settings.maxConcurrentJobs)",
                    value: $settings.maxConcurrentJobs,
                    in: 1...16
                )
                .accessibilityLabel("Maximum parallel conversions")
                .help("How many files convert at once. Video work is additionally capped to protect the GPU.")

                HStack {
                    Text("Running right now")
                    Spacer()
                    Text(effectiveText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Effective concurrency: \(effectiveText)")
                }

                Text("Mac CPU cores: \(ProcessInfo.processInfo.activeProcessorCount) · System default: \(AppSettings.systemDefaultConcurrency). Heavy video jobs are capped separately and throttle to 1 under Serious or Critical heat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Use System Default (\(AppSettings.systemDefaultConcurrency))") {
                    settings.maxConcurrentJobs = AppSettings.systemDefaultConcurrency
                }
                .controlSize(.small)
                .accessibilityLabel("Reset concurrency to system default")
            } header: {
                Text("Concurrency").font(.headline)
            } footer: {
                Text("Lower this if fans spin up or the Mac feels sluggish. Changes apply to queued work immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Heat")
                    Spacer()
                    Text(thermalStateName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(thermalColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Thermal state: \(thermalStateName)")

                HStack {
                    Text("Queue")
                    Spacer()
                    Text("\(queue.activeCount) active · \(queue.queuedCount) waiting")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Text("Under Serious or Critical heat File Converter automatically runs one job at a time until the system cools, then resumes your setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Thermals & Queue").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Performance")
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var effectiveText: String {
        let effective = queue.effectiveMaxConcurrency
        if effective < settings.maxConcurrentJobs {
            return "\(effective) (throttled by heat)"
        }
        return "\(effective)"
    }

    private var thermalStateName: String {
        switch thermalState {
        case .nominal: return "Nominal — full speed"
        case .fair: return "Fair — slightly warm"
        case .serious: return "Serious — throttled to 1"
        case .critical: return "Critical — throttled to 1"
        @unknown default: return "Unknown"
        }
    }

    private var thermalColor: Color {
        switch thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .primary
        }
    }
}
