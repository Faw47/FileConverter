import AppKit
import FileConverterCore
import SwiftUI

public struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingResetConfirmation = false
    @State private var sampleFilename = "Video_Interview"

    public init() {}

    public var body: some View {
        ScrollView {
            LiquidGlassContainer(spacing: 22) {
                VStack(alignment: .leading, spacing: 22) {
                    // Header
                    headerView

                    // Output Location
                    outputLocationSection

                    // Conflict Resolution
                    conflictResolutionSection

                    // Filename Pattern with Live Preview
                    filenamePatternSection

                    // File Attributes
                    fileAttributesSection

                    // After Conversion
                    afterConversionSection

                    // Reset Defaults
                    resetSection
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Reset General Settings?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                settings.resetAllToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will restore default output paths, conflict rules, file naming patterns, and notification preferences. Your saved presets will not be affected.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 14) {
            SettingsIconBadge(systemImage: "gearshape.fill", color: .gray, size: .header)

            VStack(alignment: .leading, spacing: 2) {
                Text("General")
                    .font(.title2.weight(.bold))

                Text("Configure default destinations, file naming, conflict rules, and notifications.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Output Location Section

    private var outputLocationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Default Output Location")

            SettingsCard {
                VStack(spacing: 0) {
                    // Option 1: Same as Source
                    outputOptionRow(
                        title: "Same folder as source file",
                        subtitle: "Converted files will be created in the exact directory of each original file.",
                        icon: "folder.badge.gearshape",
                        tag: "sameAsSource"
                    )

                    Divider().padding(.leading, 42)

                    // Option 2: Downloads folder
                    outputOptionRow(
                        title: "Downloads folder",
                        subtitle: "~/Downloads",
                        icon: "arrow.down.circle",
                        tag: "downloads"
                    )

                    Divider().padding(.leading, 42)

                    // Option 3: Custom folder
                    outputOptionRow(
                        title: "Custom folder",
                        subtitle: customFolderSubtitle,
                        icon: "folder.fill.badge.plus",
                        tag: "custom"
                    )

                    if settings.defaultOutputPolicyRaw == "custom" {
                        VStack(spacing: 0) {
                            Divider().padding(.leading, 14)

                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color.accentColor)

                                if settings.customOutputFolderPath.isEmpty {
                                    Text("No destination folder selected")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(settings.customOutputFolderPath)
                                        .font(.system(.callout, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Button("Choose Folder...") {
                                    chooseCustomFolder()
                                }
                                .glassAction()
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.quaternary.opacity(0.35))
                        }
                        if let error = settings.customOutputFolderError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 14)
                        }
                    }
                }
            }
        }
    }

    private func outputOptionRow(title: String, subtitle: String, icon: String, tag: String) -> some View {
        Button {
            if tag == "custom" && settings.customOutputFolderPath.isEmpty {
                chooseCustomFolder()
            } else {
                settings.defaultOutputPolicyRaw = tag
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(settings.defaultOutputPolicyRaw == tag ? Color.accentColor : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if settings.defaultOutputPolicyRaw == tag {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var customFolderSubtitle: String {
        if settings.customOutputFolderPath.isEmpty {
            return "Choose a dedicated destination directory on your Mac"
        }
        return settings.customOutputFolderPath
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Output Folder"
        panel.message = "Choose a default folder for newly converted files:"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            settings.setCustomOutputFolder(url: url)
        }
    }

    // MARK: - Conflict Resolution Section

    private var conflictResolutionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("File Collisions", accessory: "When Output Exists")

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow(
                        title: "If a file already exists",
                        subtitle: overwritePolicyDescription,
                        icon: "doc.on.doc",
                        iconColor: .orange
                    ) {
                        Picker("", selection: $settings.defaultOverwritePolicyRaw) {
                            ForEach(OverwritePolicy.allCases, id: \.rawValue) { policy in
                                Text(policy.displayName).tag(policy.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                }
            }
        }
    }

    private var overwritePolicyDescription: String {
        switch settings.defaultOverwritePolicy {
        case .appendNumber:
            return "Appends an incremental number (e.g. filename (1).mp4) without overwriting existing data."
        case .overwrite:
            return "Replaces the existing destination file immediately. Use with caution."
        case .ask:
            return "Prompts for confirmation before overwriting."
        case .skip:
            return "Skips the conversion if an existing file with the target name is found."
        case .replaceIfNewer:
            return "Replaces the destination file only if the source file is newer."
        }
    }

    // MARK: - Filename Pattern with Live Preview

    private var filenamePatternSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("Filename Format", accessory: "Tokens: {name}, {preset}, {date}, {time}, {ext}")

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    // Text Field
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Pattern Template")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if settings.defaultFilenamePattern != "{name}" {
                                Button("Reset to Default") {
                                    settings.defaultFilenamePattern = "{name}"
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            Image(systemName: "pencil")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)

                            TextField("Pattern", text: $settings.defaultFilenamePattern, prompt: Text("{name}"))
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
                        )
                    }

                    // Token Chips (Click to Insert)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Available Tokens (Click to insert):")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            TokenPill(token: "{name}", description: "Source filename") {
                                insertToken("{name}")
                            }
                            TokenPill(token: "{preset}", description: "Preset name") {
                                insertToken("_{preset}")
                            }
                            TokenPill(token: "{date}", description: "YYYY-MM-DD") {
                                insertToken("_{date}")
                            }
                            TokenPill(token: "{time}", description: "HH-MM-SS") {
                                insertToken("_{time}")
                            }
                            TokenPill(token: "{ext}", description: "Output extension") {
                                insertToken("_{ext}")
                            }
                        }
                    }

                    Divider()

                    // Live Preview Banner
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live Output Preview")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                Text("\(sampleFilename).mov")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.tertiary)

                                Text("\(computedPreviewName).mp4")
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        Spacer()

                        StatusBadge("Live", icon: "bolt.fill", style: .success)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                    )
                }
                .padding(14)
            }
        }
    }

    private func insertToken(_ token: String) {
        settings.defaultFilenamePattern += token
    }

    private var computedPreviewName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())

        formatter.dateFormat = "HH-mm-ss"
        let timeStr = formatter.string(from: Date())

        var result = settings.defaultFilenamePattern
        if result.isEmpty { result = "{name}" }

        result = result.replacingOccurrences(of: "{name}", with: sampleFilename)
        result = result.replacingOccurrences(of: "{preset}", with: "MP4")
        result = result.replacingOccurrences(of: "{date}", with: dateStr)
        result = result.replacingOccurrences(of: "{time}", with: timeStr)
        result = result.replacingOccurrences(of: "{ext}", with: "mp4")
        return result
    }

    // MARK: - File Attributes Section

    private var fileAttributesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("File Attributes")

            SettingsCard {
                SettingsRow(
                    title: "Preserve creation and modification dates",
                    subtitle: "Copies the source file's exact timestamps to the converted file so your photos and videos retain their chronological place in Finder and Photos.",
                    icon: "calendar.badge.clock",
                    iconColor: .purple
                ) {
                    Toggle("", isOn: $settings.preserveTimestamps)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - After Conversion Section

    private var afterConversionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionHeader("After Conversion")

            SettingsCard {
                VStack(spacing: 0) {
                    SettingsRow(
                        title: "Show macOS notification banner",
                        subtitle: "Alerts you with a banner when a batch conversion completes. \(settings.notificationStatusText)",
                        icon: "bell.badge",
                        iconColor: .red
                    ) {
                        Toggle("", isOn: $settings.enableNotifications)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if settings.enableNotifications,
                       settings.notificationAuthorizationState == .notDetermined {
                        Divider().padding(.leading, 42)

                        SettingsRow(
                            title: "Allow notifications",
                            subtitle: "Grant permission now so completed conversions can show a banner.",
                            icon: "bell.and.waves.left.and.right",
                            iconColor: .red
                        ) {
                            Button("Allow…") {
                                settings.requestNotificationAuthorization()
                            }
                            .controlSize(.small)
                        }
                    }

                    Divider().padding(.leading, 42)

                    SettingsRow(
                        title: "Reveal completed files in Finder",
                        subtitle: "Automatically activates Finder and highlights the converted files when finished.",
                        icon: "macwindow",
                        iconColor: .blue
                    ) {
                        Toggle("", isOn: $settings.revealInFinder)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset General Settings")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)

                        Text("Restores all general options to factory defaults. Your presets are kept intact.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Reset to Defaults...", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .glassActionDestructive()
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}
