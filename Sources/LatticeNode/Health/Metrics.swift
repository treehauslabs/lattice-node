import Foundation

public actor NodeMetrics {
    private var counters: [String: Int64] = [:]
    private var gauges: [String: Double] = [:]
    private var histogramSums: [String: Double] = [:]
    private var histogramCounts: [String: Int64] = [:]

    public init() {}

    public func increment(_ name: String, by value: Int64 = 1) {
        counters[name, default: 0] += value
    }

    public func set(_ name: String, value: Double) {
        gauges[name] = value
    }

    public func observe(_ name: String, value: Double) {
        histogramSums[name, default: 0] += value
        histogramCounts[name, default: 0] += 1
    }

    public func prometheus() -> String {
        var lines: [String] = []

        for (name, value) in counters.sorted(by: { $0.key < $1.key }) {
            lines.append("# TYPE \(name) counter")
            lines.append("\(name) \(value)")
        }

        for (name, value) in gauges.sorted(by: { $0.key < $1.key }) {
            lines.append("# TYPE \(name) gauge")
            lines.append("\(name) \(value)")
        }

        for (name, sum) in histogramSums.sorted(by: { $0.key < $1.key }) {
            let count = histogramCounts[name] ?? 0
            lines.append("# TYPE \(name) summary")
            lines.append("\(name)_sum \(sum)")
            lines.append("\(name)_count \(count)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
