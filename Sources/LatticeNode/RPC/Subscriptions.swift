import Foundation

public enum SubscriptionEventType: String, Sendable, CaseIterable {
    case newBlock
    case newTransaction
    case chainReorg
    case syncStatus
}

public enum NodeEvent: Sendable {
    case newBlock(hash: String, height: UInt64, directory: String, timestamp: Int64)
    case newTransaction(cid: String, fee: UInt64, sender: String)
    case chainReorg(directory: String, oldTip: String, newTip: String, depth: UInt64)
    case syncProgress(directory: String, current: UInt64, target: UInt64)

    public var type: SubscriptionEventType {
        switch self {
        case .newBlock: return .newBlock
        case .newTransaction: return .newTransaction
        case .chainReorg: return .chainReorg
        case .syncProgress: return .syncStatus
        }
    }

    public func toJSON() -> String {
        switch self {
        case .newBlock(let hash, let height, let directory, let timestamp):
            return "{\"event\":\"newBlock\",\"data\":{\"hash\":\"\(hash)\",\"height\":\(height),\"directory\":\"\(directory)\",\"timestamp\":\(timestamp)}}"
        case .newTransaction(let cid, let fee, let sender):
            return "{\"event\":\"newTransaction\",\"data\":{\"cid\":\"\(cid)\",\"fee\":\(fee),\"sender\":\"\(sender)\"}}"
        case .chainReorg(let directory, let oldTip, let newTip, let depth):
            return "{\"event\":\"chainReorg\",\"data\":{\"directory\":\"\(directory)\",\"oldTip\":\"\(oldTip)\",\"newTip\":\"\(newTip)\",\"depth\":\(depth)}}"
        case .syncProgress(let directory, let current, let target):
            return "{\"event\":\"syncStatus\",\"data\":{\"directory\":\"\(directory)\",\"current\":\(current),\"target\":\(target)}}"
        }
    }
}

public actor SubscriptionManager {
    public struct Subscriber: Sendable {
        let id: UUID
        let events: Set<SubscriptionEventType>
        let send: @Sendable (String) async -> Void
    }

    private var subscribers: [UUID: Subscriber] = [:]

    public init() {}

    public func subscribe(
        events: Set<SubscriptionEventType>,
        send: @escaping @Sendable (String) async -> Void
    ) -> UUID {
        let id = UUID()
        subscribers[id] = Subscriber(id: id, events: events, send: send)
        return id
    }

    public func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    public func emit(_ event: NodeEvent) async {
        let json = event.toJSON()
        for (_, subscriber) in subscribers {
            if subscriber.events.contains(event.type) {
                await subscriber.send(json)
            }
        }
    }

    public var subscriberCount: Int { subscribers.count }
}
