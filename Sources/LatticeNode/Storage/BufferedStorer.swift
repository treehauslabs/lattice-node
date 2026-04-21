import Foundation
import cashew
import OrderedCollections

final class BufferedStorer: Storer {
    private(set) var entries: OrderedDictionary<String, Data> = [:]
    private let skipSet: Set<String>

    init(skipSet: Set<String> = []) {
        self.skipSet = skipSet
    }

    var entryList: [(String, Data)] {
        entries.map { ($0.key, $0.value) }
    }

    var storedCIDs: Set<String> {
        Set(entries.keys)
    }

    var touchedCIDs: Set<String> {
        skipSet.union(entries.keys)
    }

    func store(rawCid: String, data: Data) throws {
        if entries[rawCid] == nil { entries[rawCid] = data }
    }

    func contains(rawCid: String) -> Bool {
        entries[rawCid] != nil || skipSet.contains(rawCid)
    }

    func flush(to network: ChainNetwork) async {
        await network.storeBatch(entryList)
    }

    func flush(to fetcher: AcornFetcher) async {
        await fetcher.storeBatch(entryList)
    }
}
