import Foundation

/// In-process notifications between the conversion code and the app's
/// windows. Names only; the payload keys are documented at each post.
public extension Notification.Name {
    /// Bring File Converter forward and show its main window.
    static let fileConverterActivateApp = Notification.Name("FileConverterActivateApp")
    /// A file-converter:// URL arrived (userInfo["url"]).
    static let fileConverterHandleIncomingURL = Notification.Name("HandleIncomingURL")
    /// Show the file chooser (as for ⌘O).
    static let fileConverterOpenPanel = Notification.Name("OpenFileConverterOpenPanel")
    /// Show the preset picker for files (userInfo["urls"]).
    static let fileConverterPresetPicker = Notification.Name("OpenFileConverterPresetPicker")
    /// Show a PDF Compress or Split dialog (userInfo["preset"], ["urls"], ["leases"]).
    static let fileConverterWorkflowDialog = Notification.Name("OpenFileConverterWorkflowDialog")
}
