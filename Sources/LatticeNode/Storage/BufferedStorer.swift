import Foundation
import cashew

final class BufferedStorer: Storer {
    private(set) var entries: [(String, Data)] = []

    func store(rawCid: String, data: Data) throws {
        entries.append((rawCid, data))
    }

    func flush(to fetcher: AcornFetcher) async {
        for (cid, data) in entries {
            await fetcher.store(rawCid: cid, data: data)
        }
    }
}
