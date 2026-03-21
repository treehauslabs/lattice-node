import Lattice
import Foundation
import Acorn
import AcornDiskWorker
import Ivy

public actor DistanceCASWorker: AcornCASWorker {
    public var near: (any AcornCASWorker)?
    public var far: (any AcornCASWorker)?
    public let timeout: Duration?

    private let disk: DiskCASWorker<DefaultFileSystem>
    private let nodeHash: [UInt8]
    private let maxBytes: Int
    private var storedCIDs: [ContentIdentifier: Int] = [:]
    private var totalBytes: Int = 0

    public init(
        directory: URL,
        nodeHash: [UInt8],
        maxBytes: Int,
        timeout: Duration? = nil
    ) throws {
        self.nodeHash = nodeHash
        self.maxBytes = maxBytes
        self.timeout = timeout
        self.disk = try DiskCASWorker(
            directory: directory,
            maxBytes: maxBytes
        )
    }

    public func has(cid: ContentIdentifier) -> Bool {
        storedCIDs[cid] != nil
    }

    public func getLocal(cid: ContentIdentifier) async -> Data? {
        await disk.getLocal(cid: cid)
    }

    public func storeLocal(cid: ContentIdentifier, data: Data) async {
        while totalBytes + data.count > maxBytes {
            guard let victim = mostDistantCID() else { break }
            if victim == cid { break }
            await disk.delete(cid: victim)
            let size = storedCIDs.removeValue(forKey: victim) ?? 0
            totalBytes -= size
        }

        await disk.storeLocal(cid: cid, data: data)
        let oldSize = storedCIDs[cid] ?? 0
        storedCIDs[cid] = data.count
        totalBytes += data.count - oldSize
    }

    private func mostDistantCID() -> ContentIdentifier? {
        var worst: ContentIdentifier?
        var worstDistance: [UInt8]? = nil

        let sampleSize = min(storedCIDs.count, 16)
        let keys = Array(storedCIDs.keys)
        guard !keys.isEmpty else { return nil }

        if keys.count <= sampleSize {
            for cid in keys {
                let dist = Router.xorDistance(nodeHash, Router.hash(cid.rawValue))
                if worstDistance == nil || dist > worstDistance! {
                    worstDistance = dist
                    worst = cid
                }
            }
        } else {
            for _ in 0..<sampleSize {
                let cid = keys[Int.random(in: 0..<keys.count)]
                let dist = Router.xorDistance(nodeHash, Router.hash(cid.rawValue))
                if worstDistance == nil || dist > worstDistance! {
                    worstDistance = dist
                    worst = cid
                }
            }
        }

        return worst
    }
}
