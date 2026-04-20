import Lattice
import Foundation
import cashew
import Acorn

public actor AcornFetcher: Fetcher {
    private let worker: any AcornCASWorker

    public init(worker: any AcornCASWorker) {
        self.worker = worker
    }

    public func fetch(rawCid: String) async throws -> Data {
        let cid = ContentIdentifier(rawValue: rawCid)
        if let data = await worker.get(cid: cid) {
            return data
        }
        throw FetcherError.notFound(rawCid)
    }

    public func store(rawCid: String, data: Data) async {
        let cid = ContentIdentifier(rawValue: rawCid)
        await worker.store(cid: cid, data: data)
    }

    public func storeBatch(_ entries: [(String, Data)]) async {
        guard !entries.isEmpty else { return }
        let mapped: [(ContentIdentifier, Data)] = entries.map {
            (ContentIdentifier(rawValue: $0.0), $0.1)
        }
        await worker.storeLocalBatch(mapped)
    }
}

public enum FetcherError: Error {
    case notFound(String)
}
