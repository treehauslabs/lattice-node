import Foundation
import Ivy
import Tally

public struct ChainAnnounceData: Sendable, Equatable {
    public let chainDirectory: String
    public let tipIndex: UInt64
    public let tipCID: String
    public let specCID: String
    public let capabilities: ChainCapabilities

    public init(chainDirectory: String, tipIndex: UInt64, tipCID: String, specCID: String, capabilities: ChainCapabilities = .default) {
        self.chainDirectory = chainDirectory
        self.tipIndex = tipIndex
        self.tipCID = tipCID
        self.specCID = specCID
        self.capabilities = capabilities
    }

    public func serialize() -> Data {
        var buf = Data()
        var v1 = UInt16(chainDirectory.utf8.count).bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v1) { Array($0) })
        buf.append(contentsOf: chainDirectory.utf8)
        var v2 = tipIndex.bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v2) { Array($0) })
        var v3 = UInt16(tipCID.utf8.count).bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v3) { Array($0) })
        buf.append(contentsOf: tipCID.utf8)
        var v4 = UInt16(specCID.utf8.count).bigEndian
        buf.append(contentsOf: Swift.withUnsafeBytes(of: &v4) { Array($0) })
        buf.append(contentsOf: specCID.utf8)
        buf.append(capabilities.rawValue)
        return buf
    }

    public static func deserialize(_ data: Data) -> ChainAnnounceData? {
        guard data.count >= 2 else { return nil }
        var offset = 0

        func readUInt16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let val = data[data.startIndex + offset ..< data.startIndex + offset + 2]
                .withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            offset += 2
            return val
        }
        func readUInt64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            let val = data[data.startIndex + offset ..< data.startIndex + offset + 8]
                .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            offset += 8
            return val
        }
        func readString() -> String? {
            guard let len = readUInt16(), offset + Int(len) <= data.count else { return nil }
            let str = String(data: data[data.startIndex + offset ..< data.startIndex + offset + Int(len)], encoding: .utf8)
            offset += Int(len)
            return str
        }

        guard let dir = readString(),
              let tipIdx = readUInt64(),
              let tipCID = readString(),
              let specCID = readString(),
              offset < data.count else { return nil }
        let capRaw = data[data.startIndex + offset]
        return ChainAnnounceData(
            chainDirectory: dir,
            tipIndex: tipIdx,
            tipCID: tipCID,
            specCID: specCID,
            capabilities: ChainCapabilities(rawValue: capRaw)
        )
    }
}

public struct ChainCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let fullNode = ChainCapabilities(rawValue: 1 << 0)
    public static let miner = ChainCapabilities(rawValue: 1 << 1)
    public static let archiveNode = ChainCapabilities(rawValue: 1 << 2)
    public static let lightClient = ChainCapabilities(rawValue: 1 << 3)
    public static let transportServer = ChainCapabilities(rawValue: 1 << 4)

    public static let `default`: ChainCapabilities = [.fullNode]
}
