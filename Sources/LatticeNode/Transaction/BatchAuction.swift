import Foundation
import Lattice

public struct BatchAuction: Sendable {
    public static let auctionDuration: UInt64 = 3

    public struct CommittedOrder: Codable, Sendable {
        public let commitHash: String
        public let sender: String
        public let commitHeight: UInt64
    }

    public struct RevealedOrder: Sendable {
        public let order: Order
        public let salt: String
    }

    public static func commitOrder(order: Order, salt: String) -> String {
        let preimage = "\(order.side.rawValue):\(order.price):\(order.amount):\(order.owner):\(salt)"
        let data = Data(preimage.utf8)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyReveal(committed: CommittedOrder, order: Order, salt: String) -> Bool {
        let recomputed = commitOrder(order: order, salt: salt)
        return recomputed == committed.commitHash
    }

    public static func canReveal(commitHeight: UInt64, currentHeight: UInt64) -> Bool {
        currentHeight >= commitHeight + auctionDuration
    }

    public static func executeBatch(orders: [RevealedOrder]) -> [(buy: Order, sell: Order, fillAmount: UInt64, fillPrice: UInt64)] {
        let buys = orders.filter { $0.order.side == .buy }.sorted { $0.order.price > $1.order.price }
        let sells = orders.filter { $0.order.side == .sell }.sorted { $0.order.price < $1.order.price }

        var matches: [(buy: Order, sell: Order, fillAmount: UInt64, fillPrice: UInt64)] = []
        var buyIdx = 0
        var sellIdx = 0

        while buyIdx < buys.count && sellIdx < sells.count {
            let buy = buys[buyIdx].order
            let sell = sells[sellIdx].order

            guard buy.price >= sell.price else { break }

            let fillPrice = (buy.price + sell.price) / 2
            let buyRemaining = buy.amount - buy.filled
            let sellRemaining = sell.amount - sell.filled
            let fillAmount = min(buyRemaining, sellRemaining)

            matches.append((buy: buy, sell: sell, fillAmount: fillAmount, fillPrice: fillPrice))

            if fillAmount >= buyRemaining { buyIdx += 1 }
            if fillAmount >= sellRemaining { sellIdx += 1 }
        }

        return matches
    }
}
