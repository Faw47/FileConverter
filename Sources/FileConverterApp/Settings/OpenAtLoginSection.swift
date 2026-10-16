import AppKit
import ServiceManagement
import SwiftUI

/// General › Startup: open File Converter at login, quietly in the menu bar.
struct OpenAtLoginSection: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: setEnabled
            ))
            if status == .requiresApproval {
                HStack {
                    Text("Allow File Converter in Login Items to finish turning this on.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Startup")
        } footer: {
            FooterText("File Converter opens in the menu bar without a window, so watched folders keep working.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Couldn’t change this: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}
