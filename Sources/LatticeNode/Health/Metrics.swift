import Foundation
import Synchronization

public final class NodeMetrics: Sendable {
    private struct Storage {
        var counters: [String: Int64] = [:]
        var gauges: [String: Double] = [:]
        var histogramSums: [String: Double] = [:]
        var histogramCounts: [String: Int64] = [:]
    }

    private let storage = Mutex(Storage())

    public init() {}

    public func increment(_ name: String, by value: Int64 = 1) {
        storage.withLock { $0.counters[name, default: 0] += value }
    }

    public func set(_ name: String, value: Double) {
        storage.withLock { $0.gauges[name] = value }
    }

    public func observe(_ name: String, value: Double) {
        storage.withLock { s in
            s.histogramSums[name, default: 0] += value
            s.histogramCounts[name, default: 0] += 1
        }
    }

    /// Drop every counter/gauge/histogram whose name contains `substring`.
    /// Used to clear per-chain label series when a chain is torn down, so the
    /// metrics map doesn't grow forever as chains are deployed and destroyed.
    public func removeKeys(containing substring: String) {
        storage.withLock { s in
            s.counters = s.counters.filter { !$0.key.contains(substring) }
            s.gauges = s.gauges.filter { !$0.key.contains(substring) }
            s.histogramSums = s.histogramSums.filter { !$0.key.contains(substring) }
            s.histogramCounts = s.histogramCounts.filter { !$0.key.contains(substring) }
        }
    }

    public func prometheus() -> String {
        let snap = storage.withLock { $0 }
        var lines: [String] = []

        for (name, value) in snap.counters.sorted(by: { $0.key < $1.key }) {
            lines.append("# TYPE \(name) counter")
            lines.append("\(name) \(value)")
        }

        for (name, value) in snap.gauges.sorted(by: { $0.key < $1.key }) {
            lines.append("# TYPE \(name) gauge")
            lines.append("\(name) \(value)")
        }

        for (name, sum) in snap.histogramSums.sorted(by: { $0.key < $1.key }) {
            let count = snap.histogramCounts[name] ?? 0
            lines.append("# TYPE \(name) summary")
            lines.append("\(name)_sum \(sum)")
            lines.append("\(name)_count \(count)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
