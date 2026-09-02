import SwiftUI
import FileConverterCore

public struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingResetConfirm = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                Picker("New presets save to", selection: $settings.defaultOutputPolicyRaw) {
                    Text("Same folder as source").tag("sameAsSource")
                    Text("Downloads folder").tag("downloads")
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Default output location for new presets")

                Text("Applies to presets you create. Built-in presets keep their own locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("If the file already exists", selection: $settings.defaultOverwritePolicyRaw) {
                    ForEach(OverwritePolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                .accessibilityLabel("Default conflict policy for new presets")

                TextField("Filename pattern", text: $settings.defaultFilenamePattern, prompt: Text("{name}"))
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Default filename pattern for new presets")
                    .help("Tokens: {name} source name, {preset} preset, {date} yyyy-MM-dd, {time} HH-mm-ss, {ext} extension.")

                Text("Example: {name} → Report.pdf · {preset} adds the preset name · {date} adds today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Defaults for New Presets").font(.headline)
            } footer: {
                Text("Changing defaults never touches existing presets. Edit a preset to override its own output, conflicts, or naming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Preserve creation & modification dates", isOn: $settings.preserveTimestamps)
                    .help("New presets copy the source dates onto the output. Existing presets keep their own switch.")
                    .accessibilityLabel("Preserve file dates on new presets")
            } header: {
                Text("File Attributes").font(.headline)
            }

            Section {
                Toggle("Notify when a batch finishes", isOn: $settings.enableNotifications)
                    .onChange(of: settings.enableNotifications) { _, enabled in
                        if enabled {
                            ConversionQueue.shared.requestNotificationAuthorizationIfNeeded()
                        }
                    }
                    .accessibilityLabel("Show system notification when batch completes")
                Toggle("Reveal completed files in Finder", isOn: $settings.revealInFinder)
                    .help("Selects finished outputs in Finder when a batch completes.")
                    .accessibilityLabel("Automatically reveal output files in Finder")
            } header: {
                Text("Notifications & Workflow").font(.headline)
            }

            Section {
                Button("Reset All Settings to Defaults...") {
                    showingResetConfirm = true
                }
                .accessibilityLabel("Reset all settings to defaults")
                .confirmationDialog(
                    "Reset every setting to its original value?",
                    isPresented: $showingResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset Everything", role: .destructive) {
                        settings.resetAllToDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Output defaults, notifications, performance, and sidebar selection return to factory values. Your presets are untouched.")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("General")
    }
}
