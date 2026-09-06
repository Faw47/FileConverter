import FileConverterCore
import SwiftUI

public struct PerformanceSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var queue = ConversionQueue.shared
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    public init() {}

    public var body: some View {
        ScrollView {
            LiquidGlassContainer(spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    // Header
                    headerView

                    // Parallel Concurrency
                    concurrencySection

                    // Thermal Adaptive Management
                    thermalSection

                    // Live System Telemetry
                    telemetrySection

                    // Queue Actions
                    queueActionsSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 14) {
            SettingsIconBadge(
                systemImage: "gauge.with.dots.needle.67percent",
                color: .teal,
                size: .header
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Performance")
                    .font(.title2.weight(.bold))

                Text("Optimize multi-core conversion throughput and intelligent thermal adaptation.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Concurrency Section

    private var concurrencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Concurrency Limit", accessory: "1 to 16 Parallel Jobs")

            SettingsCard {
                VStack(spacing: 14) {
                    // Slider & Stepper Row
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Maximum Parallel Conversions")
                                .font(.body.weight(.medium))

                            Text("Controls how many files convert simultaneously across available CPU cores.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        // Count Badge
                        Text("\(settings.maxConcurrentJobs) jobs")
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }

                    // Native Slider & Stepper
                    HStack(spacing: 16) {
                        Image(systemName: "tortoise.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        Slider(
                            value: Binding(
                                get: { Double(settings.maxConcurrentJobs) },
                                set: { settings.maxConcurrentJobs = Int($0) }
                            ),
                            in: 1...16,
                            step: 1
                        )
                        .applySliderThumbVisibility()

                        Image(systemName: "hare.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        Stepper(
                            "",
                            value: $settings.maxConcurrentJobs,
                            in: 1...16
                        )
                        .labelsHidden()
                    }

                    Divider()

                    // Concurrency Health & Recommendation Action
                    HStack(spacing: 10) {
                        if queue.effectiveMaxConcurrency < settings.maxConcurrentJobs {
                            StatusBadge(
                                "Throttled to \(queue.effectiveMaxConcurrency) jobs",
                                icon: "exclamationmark.triangle.fill",
                                style: .warning
                            )

                            Text("Mac thermal sensors indicate elevated heat. Speed will restore automatically once cooled.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            StatusBadge(
                                "Running at full capacity",
                                icon: "checkmark.circle.fill",
                                style: .success
                            )

                            Spacer()

                            Button("Use Recommended (\(AppSettings.systemDefaultConcurrency))") {
                                settings.maxConcurrentJobs = AppSettings.systemDefaultConcurrency
                            }
                            .glassAction()
                            .controlSize(.small)
                            .disabled(settings.maxConcurrentJobs == AppSettings.systemDefaultConcurrency)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Thermal Section

    private var thermalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Intelligent Thermal Protection", accessory: "macOS Adaptive Sensors")

            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    // Segmented Thermal Indicator
                    HStack(spacing: 6) {
                        thermalSegment(state: .nominal, label: "Nominal", color: .green)
                        thermalSegment(state: .fair, label: "Fair", color: .blue)
                        thermalSegment(state: .serious, label: "Serious", color: .orange)
                        thermalSegment(state: .critical, label: "Critical", color: .red)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: thermalStateIcon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(thermalStateColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current State: \(thermalStateName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(thermalStateColor)

                            Text(thermalStateDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func thermalSegment(state: ProcessInfo.ThermalState, label: String, color: Color) -> some View {
        let isCurrent = thermalState == state
        return VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isCurrent ? color : color.opacity(0.18))
                .frame(height: 6)

            Text(label)
                .font(.system(size: 10, weight: isCurrent ? .bold : .regular))
                .foregroundStyle(isCurrent ? color : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var thermalStateName: String {
        switch thermalState {
        case .nominal: return "Nominal (Cool)"
        case .fair: return "Fair (Normal Operating Heat)"
        case .serious: return "Serious (Elevated Temperature)"
        case .critical: return "Critical (Maximum Heat Limit)"
        @unknown default: return "Unknown"
        }
    }

    private var thermalStateDescription: String {
        switch thermalState {
        case .nominal:
            return "Thermal conditions are optimal. Conversions run uninhibited at your chosen concurrency setting."
        case .fair:
            return "Operating temperatures are within normal limits. Background jobs continue normally."
        case .serious:
            return "Elevated thermal pressure detected. New conversions are limited to one active job until macOS reports cooler conditions."
        case .critical:
            return "Critical hardware temperature reported by macOS. New work is limited to one active job; macOS remains responsible for system protection."
        @unknown default:
            return "Monitoring macOS thermal state notifications."
        }
    }

    private var thermalStateIcon: String {
        switch thermalState {
        case .nominal: return "checkmark.shield.fill"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "exclamationmark.triangle.fill"
        @unknown default: return "questionmark.circle"
        }
    }

    private var thermalStateColor: Color {
        switch thermalState {
        case .nominal: return .green
        case .fair: return .blue
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    // MARK: - Telemetry Section

    private var telemetrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Live System Telemetry")

            HStack(spacing: 12) {
                telemetryCard(
                    title: "Active Jobs",
                    value: "\(queue.activeCount)",
                    icon: "play.circle.fill",
                    color: .accentColor
                )

                telemetryCard(
                    title: "Queued Jobs",
                    value: "\(queue.queuedCount)",
                    icon: "clock.fill",
                    color: .purple
                )

                telemetryCard(
                    title: "CPU Cores",
                    value: "\(ProcessInfo.processInfo.activeProcessorCount)",
                    icon: "cpu.fill",
                    color: .indigo
                )
            }
        }
    }

    private func telemetryCard(title: String, value: String, icon: String, color: Color) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Queue Actions Section

    private var queueActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Quick Queue Maintenance")

            SettingsCard {
                HStack(spacing: 12) {
                    Button {
                        queue.clearCompleted()
                    } label: {
                        Label("Clear Finished Jobs", systemImage: "trash")
                    }
                    .glassAction()
                    .controlSize(.small)
                    .disabled(queue.completedCount == 0 && queue.failedCount == 0 && queue.cancelledCount == 0)

                    Button(role: .destructive) {
                        queue.cancelAll()
                    } label: {
                        Label("Cancel All Active Jobs", systemImage: "xmark.circle")
                    }
                    .glassActionDestructive()
                    .controlSize(.small)
                    .disabled(queue.activeCount == 0 && queue.queuedCount == 0)

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}
