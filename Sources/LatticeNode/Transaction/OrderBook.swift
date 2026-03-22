import Lattice
import Foundation
import cashew

public enum OrderSide: String, Codable, Sendable {
    case buy
    case sell
}

public struct Order: Codable, Sendable {
    public let id: String
    public let owner: String
    public let side: OrderSide
    public let price: UInt64
    public let amount: UInt64
    public let filled: UInt64
    public let timestamp: Int64

    public init(id: String, owner: String, side: OrderSide, price: UInt64, amount: UInt64, filled: UInt64 = 0, timestamp: Int64 = 0) {
        self.id = id
        self.owner = owner
        self.side = side
        self.price = price
        self.amount = amount
        self.filled = filled
        self.timestamp = timestamp
    }

    public var remaining: UInt64 { amount - filled }
    public var isFullyFilled: Bool { filled >= amount }

    public var stateKey: String { "order:\(id)" }

    public var stateValue: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromStateValue(_ json: String) -> Order? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Order.self, from: data)
    }
}

public struct OrderBook {

    public static func placementAction(order: Order) -> Action? {
        guard let value = order.stateValue else { return nil }
        return Action(key: order.stateKey, oldValue: nil, newValue: value)
    }

    public static func cancellationAction(order: Order) -> Action? {
        guard let value = order.stateValue else { return nil }
        return Action(key: order.stateKey, oldValue: value, newValue: nil)
    }

    public static func buildPlacementTransaction(
        wallet: Wallet,
        order: Order,
        senderOldBalance: UInt64,
        fee: UInt64 = 0,
        nonce: UInt64 = 0
    ) -> Transaction? {
        guard let action = placementAction(order: order) else { return nil }
        let (lockedAmount, didOverflow) = order.side == .buy
            ? order.price.multipliedReportingOverflow(by: order.amount)
            : (order.amount, false)
        guard !didOverflow else { return nil }
        let (totalCost, costOverflow) = lockedAmount.addingReportingOverflow(fee)
        guard !costOverflow else { return nil }
        guard senderOldBalance >= totalCost else { return nil }

        let accountAction = AccountAction(
            owner: wallet.address,
            oldBalance: senderOldBalance,
            newBalance: senderOldBalance - totalCost
        )

        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [action],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [wallet.address],
            fee: fee,
            nonce: nonce
        )

        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let signature = wallet.sign(message: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [wallet.publicKeyHex: signature],
            body: bodyHeader
        )
    }

    public static func buildCancellationTransaction(
        wallet: Wallet,
        order: Order,
        senderOldBalance: UInt64,
        fee: UInt64 = 0,
        nonce: UInt64 = 0
    ) -> Transaction? {
        guard order.owner == wallet.address else { return nil }
        guard let action = cancellationAction(order: order) else { return nil }
        let (refund, refundOverflow) = order.side == .buy
            ? order.price.multipliedReportingOverflow(by: order.remaining)
            : (order.remaining, false)
        guard !refundOverflow else { return nil }

        var newBalance = senderOldBalance + refund
        if fee > 0 {
            guard newBalance >= fee else { return nil }
            newBalance -= fee
        }

        let accountAction = AccountAction(
            owner: wallet.address,
            oldBalance: senderOldBalance,
            newBalance: newBalance
        )

        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [action],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [wallet.address],
            fee: fee,
            nonce: nonce
        )

        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let signature = wallet.sign(message: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [wallet.publicKeyHex: signature],
            body: bodyHeader
        )
    }

    public static func matchOrders(buyOrder: Order, sellOrder: Order) -> (fillAmount: UInt64, fillPrice: UInt64)? {
        guard buyOrder.side == .buy, sellOrder.side == .sell else { return nil }
        guard buyOrder.price >= sellOrder.price else { return nil }
        guard buyOrder.remaining > 0, sellOrder.remaining > 0 else { return nil }
        let fillAmount = min(buyOrder.remaining, sellOrder.remaining)
        let fillPrice = sellOrder.price
        return (fillAmount, fillPrice)
    }

    public static func buildSettlementTransaction(
        matcher: Wallet,
        buyOrder: Order,
        sellOrder: Order,
        buyerOldBalance: UInt64,
        sellerOldBalance: UInt64,
        matcherOldBalance: UInt64,
        fee: UInt64 = 0,
        nonce: UInt64 = 0
    ) -> Transaction? {
        guard let match = matchOrders(buyOrder: buyOrder, sellOrder: sellOrder) else { return nil }

        let (cost, costOverflow) = match.fillPrice.multipliedReportingOverflow(by: match.fillAmount)
        guard !costOverflow else { return nil }
        let (buyerRefund, refundOverflow) = (buyOrder.price - match.fillPrice).multipliedReportingOverflow(by: match.fillAmount)
        guard !refundOverflow else { return nil }

        var actions: [Action] = []

        let updatedBuy = Order(
            id: buyOrder.id, owner: buyOrder.owner, side: .buy,
            price: buyOrder.price, amount: buyOrder.amount,
            filled: buyOrder.filled + match.fillAmount, timestamp: buyOrder.timestamp
        )
        if updatedBuy.isFullyFilled {
            guard let action = cancellationAction(order: buyOrder) else { return nil }
            actions.append(action)
        } else {
            guard let oldVal = buyOrder.stateValue, let newVal = updatedBuy.stateValue else { return nil }
            actions.append(Action(key: buyOrder.stateKey, oldValue: oldVal, newValue: newVal))
        }

        let updatedSell = Order(
            id: sellOrder.id, owner: sellOrder.owner, side: .sell,
            price: sellOrder.price, amount: sellOrder.amount,
            filled: sellOrder.filled + match.fillAmount, timestamp: sellOrder.timestamp
        )
        if updatedSell.isFullyFilled {
            guard let action = cancellationAction(order: sellOrder) else { return nil }
            actions.append(action)
        } else {
            guard let oldVal = sellOrder.stateValue, let newVal = updatedSell.stateValue else { return nil }
            actions.append(Action(key: sellOrder.stateKey, oldValue: oldVal, newValue: newVal))
        }

        var accountActions: [AccountAction] = []

        if buyerRefund > 0 {
            accountActions.append(AccountAction(
                owner: buyOrder.owner,
                oldBalance: buyerOldBalance,
                newBalance: buyerOldBalance + buyerRefund
            ))
        }

        accountActions.append(AccountAction(
            owner: sellOrder.owner,
            oldBalance: sellerOldBalance,
            newBalance: sellerOldBalance + cost
        ))

        if fee > 0 {
            guard matcherOldBalance >= fee else { return nil }
            accountActions.append(AccountAction(
                owner: matcher.address,
                oldBalance: matcherOldBalance,
                newBalance: matcherOldBalance - fee
            ))
        }

        let signers = [matcher.address]

        let body = TransactionBody(
            accountActions: accountActions,
            actions: actions,
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: signers,
            fee: fee,
            nonce: nonce
        )

        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let signature = matcher.sign(message: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [matcher.publicKeyHex: signature],
            body: bodyHeader
        )
    }
}
