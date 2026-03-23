import Foundation
import Lattice
import cashew

public actor ParallelBlockFetcher {
    private let fetcher: Fetcher
    private let concurrency: Int
    private let fetchTimeout: Duration

    public init(
        fetcher: Fetcher,
        concurrency: Int = 8,
        fetchTimeout: Duration = .seconds(30)
    ) {
        self.fetcher = fetcher
        self.concurrency = concurrency
        self.fetchTimeout = fetchTimeout
    }

    public enum FetchError: Error {
        case fetchFailed(cid: String)
        case invalidBlock(cid: String)
        case cancelled
    }

    public func fetchBlocks(
        cids: [String],
        storeFn: @escaping @Sendable (String, Data) async -> Void,
        validatePoW: Bool = true,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws {
        let total = UInt64(cids.count)
        let completed = CompletedCounter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var index = 0

            for _ in 0..<min(concurrency, cids.count) {
                let cid = cids[index]
                index += 1
                group.addTask { [fetcher, fetchTimeout] in
                    let data = try await Self.fetchWithTimeout(
                        cid: cid,
                        fetcher: fetcher,
                        timeout: fetchTimeout
                    )

                    if validatePoW {
                        guard Block(data: data) != nil else {
                            throw FetchError.invalidBlock(cid: cid)
                        }
                    }

                    await storeFn(cid, data)
                    let count = await completed.increment()
                    await progress?(count, total)
                }
            }

            while index < cids.count {
                try await group.next()

                if Task.isCancelled {
                    throw FetchError.cancelled
                }

                let cid = cids[index]
                index += 1
                group.addTask { [fetcher, fetchTimeout] in
                    let data = try await Self.fetchWithTimeout(
                        cid: cid,
                        fetcher: fetcher,
                        timeout: fetchTimeout
                    )

                    if validatePoW {
                        guard Block(data: data) != nil else {
                            throw FetchError.invalidBlock(cid: cid)
                        }
                    }

                    await storeFn(cid, data)
                    let count = await completed.increment()
                    await progress?(count, total)
                }
            }

            try await group.waitForAll()
        }
    }

    private static func fetchWithTimeout(
        cid: String,
        fetcher: Fetcher,
        timeout: Duration
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await fetcher.fetch(rawCid: cid)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw FetchError.fetchFailed(cid: cid)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private actor CompletedCounter {
    private var count: UInt64 = 0

    func increment() -> UInt64 {
        count += 1
        return count
    }
}
