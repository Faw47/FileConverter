import AppKit
import FileConverterCore
import SwiftUI

public struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var patternField = PatternFieldController()
    @State private var draftPattern = AppSettings.shared.defaultFilenamePattern
    @State private var showingResetConfirmation = false

    public init() {}

    public var body: some View {
        Form {
            savingSection
            fileNameSection
            fileDetailsSection
            afterConvertingSection
            openingFilesSection
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults…") {
                        showingResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Restore General settings to their defaults?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                settings.resetAllToDefaults()
                draftPattern = settings.defaultFilenamePattern
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your presets are not changed.")
        }
        .onChange(of: settings.defaultFilenamePattern) { _, newValue in
            draftPattern = newValue
        }
    }

    // MARK: - Saving

    private enum LocationChoice: Hashable {
        case sameAsSource, downloads, custom
    }

    private var locationSelection: Binding<LocationChoice> {
        Binding(
            get: {
                switch settings.defaultOutputPolicyRaw {
                case "downloads": return .downloads
                case "custom": return .custom
                default: return .sameAsSource
                }
            },
            set: { choice in
                switch choice {
                case .sameAsSource: settings.defaultOutputPolicyRaw = "sameAsSource"
                case .downloads: settings.defaultOutputPolicyRaw = "downloads"
                case .custom:
                    if settings.customOutputFolderPath.isEmpty {
                        chooseCustomFolder()
                    } else {
                        settings.defaultOutputPolicyRaw = "custom"
                    }
                }
            }
        )
    }

    private var savingSection: some View {
        Section("Saving") {
            Picker("Save converted files to", selection: locationSelection) {
                Text("The same folder as the original").tag(LocationChoice.sameAsSource)
                Text("Downloads").tag(LocationChoice.downloads)
                Text(customFolderLabel).tag(LocationChoice.custom)
            }
            .pickerStyle(.radioGroup)

            if settings.defaultOutputPolicyRaw == "custom" || !settings.customOutputFolderPath.isEmpty {
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.customOutputFolderPath.isEmpty ? "None chosen" : settings.customOutputFolderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(settings.customOutputFolderPath)
                        Button("Choose…") { chooseCustomFolder() }
                            .accessibilityLabel("Choose output folder")
                    }
                }
            }
            if let error = settings.customOutputFolderError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Picker("If a file with the same name exists", selection: $settings.defaultOverwritePolicyRaw) {
                ForEach(OverwritePolicy.allCases, id: \.rawValue) { policy in
                    Text(policy.displayName).tag(policy.rawValue)
                }
            }
            Text(overwritePolicyDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var customFolderLabel: String {
        if settings.customOutputFolderPath.isEmpty { return "A folder I choose…" }
        return URL(fileURLWithPath: settings.customOutputFolderPath).lastPathComponent
    }

    private var overwritePolicyDescription: String {
        switch settings.defaultOverwritePolicy {
        case .appendNumber:
            return "Adds a number, like “video (1).mp4”. Nothing is replaced."
        case .overwrite:
            return "Replaces the existing file. The old file is moved to the Trash."
        case .ask:
            return "Asks what to do for each file that already exists."
        case .skip:
            return "Leaves the existing file and skips the conversion."
        case .replaceIfNewer:
            return "Replaces the existing file only when the original is newer."
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where converted files are saved."
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { settings.setCustomOutputFolder(url: url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            settings.setCustomOutputFolder(url: url)
        }
    }

    // MARK: - File names

    private var patternProblem: String? {
        AppSettings.filenamePatternProblem(draftPattern)
    }

    private var fileNameSection: some View {
        Section {
            LabeledContent("Name pattern") {
                PatternTextField(
                    text: $draftPattern,
                    placeholder: "{name}",
                    controller: patternField,
                    onCommit: commitPattern
                )
                .frame(minWidth: 200)
            }
            LabeledContent("Insert") {
                HStack(spacing: 6) {
                    tokenButton("{name}", help: "Original file name")
                    tokenButton("{preset}", help: "Preset name")
                    tokenButton("{date}", help: "Date, like 2026-10-12")
                    tokenButton("{time}", help: "Time, like 14-05-09")
                }
            }
            if let patternProblem {
                Text(patternProblem)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                LabeledContent("Example") {
                    Text("Interview.mov → \(previewName)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("File Names")
        } footer: {
            if settings.defaultFilenamePattern != "{name}" {
                HStack {
                    Spacer()
                    Button("Use Original Name Only") {
                        draftPattern = "{name}"
                        commitPattern()
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    private func tokenButton(_ token: String, help: String) -> some View {
        Button(token) {
            patternField.insert(token)
        }
        .font(.system(.callout, design: .monospaced))
        .help(help)
        .accessibilityLabel("Insert \(help)")
    }

    private var previewName: String {
        let sampleMenuName = PresetStore.shared.enabledPresets.first { $0.category == .video }?.menuName ?? "MP4"
        return OutputNamingEngine.previewFilename(
            pattern: draftPattern,
            sourceName: "Interview",
            sourceExtension: "mov",
            targetExtension: "mp4",
            presetMenuName: sampleMenuName
        )
    }

    private func commitPattern() {
        if settings.commitFilenamePattern(draftPattern) {
            draftPattern = settings.defaultFilenamePattern
        }
    }

    // MARK: - File details

    private var fileDetailsSection: some View {
        Section {
            Toggle("Keep the original creation date", isOn: $settings.preserveCreationDate)
            Toggle("Keep the original modification date", isOn: $settings.preserveModificationDate)
            Toggle("Remove location from photos and videos", isOn: $settings.removeLocationData)
        } header: {
            Text("File Details")
        } footer: {
            FooterText("With the modification date off, new files show today's date and appear first when Finder sorts by date. Presets can override these.")
        }
    }

    // MARK: - After converting

    private var afterConvertingSection: some View {
        Section("After Converting") {
            Toggle("Show a notification when a batch finishes", isOn: $settings.enableNotifications)
            if settings.enableNotifications {
                switch settings.notificationAuthorizationState {
                case .notDetermined:
                    LabeledContent("File Converter needs permission to show notifications.") {
                        Button("Allow…") { settings.requestNotificationAuthorization() }
                    }
                case .denied:
                    LabeledContent("Notifications are turned off for File Converter in System Settings.") {
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                default:
                    EmptyView()
                }
            }
            Toggle("Show converted files in Finder", isOn: $settings.revealInFinder)
            Toggle("Show progress in the menu bar", isOn: $settings.showMenuBarExtra)
        }
    }

    // MARK: - Opening files

    private var openingFilesSection: some View {
        Section {
            Picker("Files opened without a preset", selection: $settings.openWithBehavior) {
                ForEach(AppSettings.OpenWithBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("Opening Files")
        } footer: {
            FooterText("Applies to Open With, Services, and files dropped on the Dock icon. The File Converter menu in Finder always converts right away.")
        }
    }
}
