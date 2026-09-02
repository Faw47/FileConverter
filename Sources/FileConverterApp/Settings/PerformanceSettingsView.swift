import SwiftUI
import FileConverterCore

public struct PerformanceSettingsView: View {
    @AppStorage("maxConcurrentJobs") private var maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    @State private var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    public init() {}

    public var body: some View {
        Form {
            Section {
                Stepper("Maximum Concurrent Conversions: \(maxConcurrency)", value: $maxConcurrency, in: 1...16)
                    .onChange(of: maxConcurrency) { _, newVal in
                        ConversionQueue.shared.setMaxConcurrency(newVal)
                    }

                Text("System CPU Cores Detected: \(ProcessInfo.processInfo.activeProcessorCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Concurrency & CPU Allocation").font(.headline)
            }

            Section {
                HStack {
                    Text("Current Thermal State:")
                    Spacer()
                    Text(thermalStateName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(thermalColor)
                }

                Text("When the system experiences high thermal pressure or enters Low Power Mode, File Converter automatically throttles background workers to prevent fan noise and battery drain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Thermal & Energy Management").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    private var thermalStateName: String {
        switch thermalState {
        case .nominal: return "Nominal (Optimal)"
        case .fair: return "Fair (Elevated)"
        case .serious: return "Serious (Throttled)"
        case .critical: return "Critical"
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
