import Foundation

public enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

public struct NodeLogger: Sendable {
    public let subsystem: String

    public init(_ subsystem: String) {
        self.subsystem = subsystem
    }

    public func log(_ level: LogLevel, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [\(level.rawValue)] [\(subsystem)] \(message)")
    }

    public func debug(_ msg: String) { log(.debug, msg) }
    public func info(_ msg: String) { log(.info, msg) }
    public func warn(_ msg: String) { log(.warn, msg) }
    public func error(_ msg: String) { log(.error, msg) }
}
