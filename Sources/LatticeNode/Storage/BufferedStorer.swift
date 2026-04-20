import Foundation
import cashew
import OrderedCollections

final class BufferedStorer: Storer {
    private(set) var entries: OrderedDictionary<String, Data> = [:]

    var entryList: [(String, Data)] {
        entries.map { ($0.key, $0.value) }
    }

    func store(rawCid: String, data: Data) throws {
        // Merkle subtrees are heavily shared across adjacent blocks — only
        // buffer the first occurrence of each CID.
        if entries[rawCid] == nil { entries[rawCid] = data }
    }

    func flush(to network: ChainNetwork) async {
        await network.storeBatch(entryList)
    }

    func flush(to fetcher: AcornFetcher) async {
        await fetcher.storeBatch(entryList)
    }
}
