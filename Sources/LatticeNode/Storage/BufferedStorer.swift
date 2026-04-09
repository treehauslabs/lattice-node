import Foundation
import cashew

final class BufferedStorer: Storer {
    private(set) var entries: [(String, Data)] = []

    func store(rawCid: String, data: Data) throws {
        entries.append((rawCid, data))
    }

    func flush(to network: ChainNetwork) async {
        await network.storeBatch(entries)
    }

    func flush(to fetcher: AcornFetcher) async {
        await fetcher.storeBatch(entries)
    }
}
