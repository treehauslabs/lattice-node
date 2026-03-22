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
        let contentCid = ContentIdentifier(rawValue: contentHash(of: rawCid))
        if let data = await worker.get(cid: contentCid) {
            return data
        }
        throw FetcherError.notFound(rawCid)
    }

    public func store(rawCid: String, data: Data) async {
        let cashewCid = ContentIdentifier(rawValue: rawCid)
        await worker.store(cid: cashewCid, data: data)
        let contentCid = ContentIdentifier(for: data)
        if contentCid.rawValue != rawCid {
            await worker.store(cid: contentCid, data: data)
        }
    }

    private func contentHash(of cidString: String) -> String {
        let data = Data(cidString.utf8)
        return ContentIdentifier(for: data).rawValue
    }
}

public enum FetcherError: Error {
    case notFound(String)
}
