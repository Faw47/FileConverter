import SwiftUI
import FileConverterCore

public struct GeneralSettingsView: View {
    @AppStorage("outputDirectoryPolicy") private var outputPolicyRaw: String = "sameAsSource"
    @AppStorage("overwritePolicy") private var overwritePolicyRaw: String = OverwritePolicy.appendNumber.rawValue
    @AppStorage("preserveTimestamps") private var preserveTimestamps: Bool = true
    @AppStorage("enableNotifications") private var enableNotifications: Bool = true
    @AppStorage("revealInFinderOnComplete") private var revealInFinder: Bool = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                Picker("Default Output Location", selection: $outputPolicyRaw) {
                    Text("Same directory as source file").tag("sameAsSource")
                    Text("Downloads folder").tag("downloads")
                }
                .pickerStyle(.radioGroup)

                Picker("When file already exists", selection: $overwritePolicyRaw) {
                    Text("Append number (e.g. filename (1).mp4)").tag(OverwritePolicy.appendNumber.rawValue)
                    Text("Overwrite existing file").tag(OverwritePolicy.overwrite.rawValue)
                    Text("Skip conversion").tag(OverwritePolicy.skip.rawValue)
                    Text("Replace only if source is newer").tag(OverwritePolicy.replaceIfNewer.rawValue)
                }
            } header: {
                Text("Output Location").font(.headline)
            }

            Section {
                Toggle("Preserve file creation & modification dates", isOn: $preserveTimestamps)
                    .help("Copies the original file's creation and modification dates to the converted output.")
            } header: {
                Text("Metadata & File Attributes").font(.headline)
            }

            Section {
                Toggle("Show system notification when batch completes", isOn: $enableNotifications)
                Toggle("Automatically reveal output file in Finder", isOn: $revealInFinder)
            } header: {
                Text("Notifications & Workflow").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
