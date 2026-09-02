import SwiftUI
import FileConverterCore

public struct FinderIntegrationView: View {
    public init() {}

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("File Converter includes a native macOS Finder Sync extension that integrates directly into your right-click context menu.")
                        .font(.system(size: 13))

                    Divider()

                    Text("How to Enable:")
                        .font(.system(size: 13, weight: .semibold))

                    VStack(alignment: .leading, spacing: 6) {
                        StepRow(number: "1", text: "Open System Settings on your Mac.")
                        StepRow(number: "2", text: "Navigate to Privacy & Security > Extensions.")
                        StepRow(number: "3", text: "Select 'Added Extensions' and enable the checkbox for File Converter.")
                        StepRow(number: "4", text: "Right-click any video, audio, image, or document in Finder to use.")
                    }
                    .padding(.vertical, 4)

                    Divider()

                    Button("Open System Settings Extensions...") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Finder Sync Context Menu Extension").font(.headline)
            }

            Section {
                Text("If the context menu does not appear after enabling, you can restart Finder from Terminal using: killall Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Troubleshooting").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct StepRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Circle())

            Text(text)
                .font(.system(size: 12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}
