import Foundation
import os.log

public enum AppLogger {
    private static let subsystem = "io.fileconverter"

    public static let general = Logger(subsystem: subsystem, category: "general")
    public static let conversion = Logger(subsystem: subsystem, category: "conversion")
    public static let formats = Logger(subsystem: subsystem, category: "formats")
    public static let presets = Logger(subsystem: subsystem, category: "presets")
    public static let finder = Logger(subsystem: subsystem, category: "finder")
    public static let backends = Logger(subsystem: subsystem, category: "backends")
    public static let fileAccess = Logger(subsystem: subsystem, category: "fileAccess")
    public static let ipc = Logger(subsystem: subsystem, category: "ipc")
    public static let queue = Logger(subsystem: subsystem, category: "queue")
}
