import Foundation

/// Parses the opaque identifier carried by a completion notification. Output
/// URLs are resolved by ConversionQueue after this parse.
public enum NotificationURLResolver {
    public static func batchID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let value = userInfo[ConversionQueue.completionBatchIdentifierKey] as? String else {
            return nil
        }
        return UUID(uuidString: value)
    }
}
