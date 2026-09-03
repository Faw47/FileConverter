import FileConverterCore
import SwiftUI

public struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingResetConfirmation = false

    public init() {}

    public var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Defaults for new presets and what happens after conversion.",
            systemImage: "gearshape"
        ) {
            Form {
                Section("New Preset Defaults") {
                    Picker("Output location", selection: $settings.defaultOutputPolicyRaw) {
                        Text("Same folder as source").tag("sameAsSource")
                        Text("Downloads folder").tag("downloads")
                    }
                    .pickerStyle(.radioGroup)

                    Picker("If a file already exists", selection: $settings.defaultOverwritePolicyRaw) {
                        ForEach(OverwritePolicy.allCases, id: \.rawValue) { policy in
                            Text(policy.displayName).tag(policy.rawValue)
                        }
                    }

                    TextField("Filename pattern", text: $settings.defaultFilenamePattern, prompt: Text("{name}"))
                        .font(.system(.body, design: .monospaced))
                        .help("Tokens: {name}, {preset}, {date}, {time}, and {ext}.")

                    Text("Example: {name} keeps the source name. These defaults only affect presets created later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("File Attributes") {
                    Toggle("Preserve creation and modification dates", isOn: $settings.preserveTimestamps)
                        .help("New presets copy source timestamps to converted files.")
                }

                Section("After Conversion") {
                    Toggle("Notify when a batch finishes", isOn: $settings.enableNotifications)
                        .onChange(of: settings.enableNotifications) { _, enabled in
                            if enabled {
                                ConversionQueue.shared.requestNotificationAuthorizationIfNeeded()
                            }
                        }

                    Toggle("Reveal completed files in Finder", isOn: $settings.revealInFinder)
                        .help("Selects the converted files in Finder when the batch finishes.")
                }

                Section {
                    Button("Reset General Settings...", role: .destructive) {
                        showingResetConfirmation = true
                    }
                } footer: {
                    Text("Resetting these settings does not delete or modify your existing presets.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .confirmationDialog(
            "Reset general settings to their defaults?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Settings", role: .destructive) {
                settings.resetAllToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Output defaults, notifications, Finder reveal behavior, and performance settings return to their original values. Presets are untouched.")
        }
    }
}
