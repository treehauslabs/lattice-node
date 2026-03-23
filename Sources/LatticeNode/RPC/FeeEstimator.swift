import Foundation

public actor FeeEstimator {
    private var blockFeeData: [(height: UInt64, fees: [UInt64])] = []
    private let windowSize: Int

    public init(windowSize: Int = 100) {
        self.windowSize = windowSize
    }

    public func recordBlock(height: UInt64, transactionFees: [UInt64]) {
        blockFeeData.append((height: height, fees: transactionFees))
        if blockFeeData.count > windowSize {
            blockFeeData.removeFirst()
        }
    }

    public func estimate(confirmationTarget: Int) -> UInt64 {
        let minimums = blockFeeData.compactMap { entry -> UInt64? in
            guard !entry.fees.isEmpty else { return nil }
            return entry.fees.min()
        }
        guard !minimums.isEmpty else { return 1 }

        let sorted = minimums.sorted()

        let percentile: Double
        switch confirmationTarget {
        case ...1:
            percentile = 0.90
        case 2...5:
            percentile = 0.60
        case 6...10:
            percentile = 0.30
        default:
            percentile = 0.10
        }

        let index = min(Int(Double(sorted.count - 1) * percentile), sorted.count - 1)
        return max(sorted[index], 1)
    }

    public func histogram() -> [(range: String, count: Int)] {
        let allFees = blockFeeData.flatMap { $0.fees }
        guard !allFees.isEmpty else { return [] }

        let buckets: [(label: String, low: UInt64, high: UInt64)] = [
            ("1-10", 1, 10),
            ("11-100", 11, 100),
            ("101-1000", 101, 1000),
            ("1001-10000", 1001, 10000),
            ("10001+", 10001, UInt64.max),
        ]

        return buckets.compactMap { bucket in
            let count = allFees.filter { $0 >= bucket.low && $0 <= bucket.high }.count
            guard count > 0 else { return nil }
            return (range: bucket.label, count: count)
        }
    }

    public var blockCount: Int { blockFeeData.count }
}
