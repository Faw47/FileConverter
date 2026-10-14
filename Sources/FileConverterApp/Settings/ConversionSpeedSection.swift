import FileConverterCore
import SwiftUI

/// How many files convert at once. Shown as a section of General settings.
struct ConversionSpeedSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    /// 0 stands for "Automatic".
    private var selection: Binding<Int> {
        Binding(
            get: { settings.concurrencyIsAutomatic ? 0 : settings.maxConcurrentJobs },
            set: { value in
                if value == 0 {
                    settings.concurrencyIsAutomatic = true
                    settings.maxConcurrentJobs = AppSettings.systemDefaultConcurrency
                } else {
                    settings.concurrencyIsAutomatic = false
                    settings.maxConcurrentJobs = value
                }
            }
        )
    }

    private var isHot: Bool {
        thermalState == .serious || thermalState == .critical
    }

    var body: some View {
            Section {
                Picker("Simultaneous conversions", selection: selection) {
                    Text("Automatic (\(AppSettings.systemDefaultConcurrency))").tag(0)
                    Divider()
                    ForEach(1...16, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                if isHot {
                    Label("Converting one file at a time while your Mac cools down.", systemImage: "thermometer.high")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Converting")
            } footer: {
                FooterText("More conversions at once can finish a batch sooner but makes the Mac work harder. Automatic uses half of this Mac's \(ProcessInfo.processInfo.activeProcessorCount) processor cores.")
            }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            Task { @MainActor in thermalState = ProcessInfo.processInfo.thermalState }
        }
    }
}
