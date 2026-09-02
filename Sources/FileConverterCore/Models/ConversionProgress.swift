import Foundation

public struct ConversionProgress: Sendable, Codable, Equatable {
    public var fractionCompleted: Double
    public var processedBytes: Int64
    public var totalBytes: Int64
    public var processedFrames: Int64
    public var totalFrames: Int64
    public var currentFPS: Double?
    public var currentSpeed: Double? // e.g. 2.5x
    public var currentBitrateKbps: Double?
    public var elapsedTime: TimeInterval
    public var estimatedTimeRemaining: TimeInterval?

    public init(
        fractionCompleted: Double = 0.0,
        processedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        processedFrames: Int64 = 0,
        totalFrames: Int64 = 0,
        currentFPS: Double? = nil,
        currentSpeed: Double? = nil,
        currentBitrateKbps: Double? = nil,
        elapsedTime: TimeInterval = 0.0,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.fractionCompleted = min(max(fractionCompleted, 0.0), 1.0)
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.processedFrames = processedFrames
        self.totalFrames = totalFrames
        self.currentFPS = currentFPS
        self.currentSpeed = currentSpeed
        self.currentBitrateKbps = currentBitrateKbps
        self.elapsedTime = elapsedTime
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }

    public var percentageString: String {
        String(format: "%.1f%%", fractionCompleted * 100.0)
    }

    public var formattedTimeRemaining: String? {
        guard let eta = estimatedTimeRemaining, eta > 0 && eta.isFinite else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = eta >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: eta)
    }
}
