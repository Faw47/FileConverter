import FileConverterCore
import SwiftUI

public struct PerformanceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var queue = ConversionQueue.shared
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    public init() {}

    public var body: some View {
        SettingsPage(
            title: "Performance",
            subtitle: "Control parallel work while File Converter adapts to system heat.",
            systemImage: "gauge.with.dots.needle.67percent"
        ) {
            Form {
                Section("Concurrency") {
                    Stepper(
                        "Maximum parallel conversions: \(settings.maxConcurrentJobs)",
                        value: $settings.maxConcurrentJobs,
                        in: 1...16
                    )
                    .help("Video work may be capped further to protect the GPU and system responsiveness.")

                    LabeledContent("Effective limit") {
                        Text(effectiveConcurrencyText)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("System default") {
                        Text("\(AppSettings.systemDefaultConcurrency) jobs")
                            .foregroundStyle(.secondary)
                    }

                    Button("Use System Default") {
                        settings.maxConcurrentJobs = AppSettings.systemDefaultConcurrency
                    }
                    .controlSize(.small)
                    .disabled(settings.maxConcurrentJobs == AppSettings.systemDefaultConcurrency)
                }

                Section {
                    LabeledContent("Thermal state") {
                        Label(thermalStateName, systemImage: thermalStateIcon)
                            .foregroundStyle(thermalStateColor)
                    }

                    LabeledContent("Conversion queue") {
                        Text("\(queue.activeCount) active, \(queue.queuedCount) waiting")
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("CPU cores") {
                        Text("\(ProcessInfo.processInfo.activeProcessorCount)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("System Load")
                } footer: {
                    Text("When macOS reports Serious or Critical thermal pressure, File Converter temporarily reduces work to one conversion at a time. Your chosen limit returns automatically after the Mac cools down.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var effectiveConcurrencyText: String {
        let effective = queue.effectiveMaxConcurrency
        if effective < settings.maxConcurrentJobs {
            return "\(effective) jobs (thermally limited)"
        }
        return "\(effective) jobs"
    }

    private var thermalStateName: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalStateIcon: String {
        switch thermalState {
        case .nominal: return "checkmark.circle.fill"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        @unknown default: return "questionmark.circle"
        }
    }

    private var thermalStateColor: Color {
        switch thermalState {
        case .nominal: return .green
        case .fair: return .secondary
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}
