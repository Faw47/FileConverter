import Foundation
import os

/// Performance and workflow signposts for Instruments profiling.
/// Emits state and timing intervals without logging privacy-sensitive file paths.
public enum AppSignpost {
    private static let subsystem = "io.fileconverter"

    public static let detection = OSSignposter(subsystem: subsystem, category: "detection")
    public static let probing = OSSignposter(subsystem: subsystem, category: "probing")
    public static let conversion = OSSignposter(subsystem: subsystem, category: "conversion")
    public static let commit = OSSignposter(subsystem: subsystem, category: "commit")
    public static let externalDiscovery = OSSignposter(subsystem: subsystem, category: "discovery")
}
