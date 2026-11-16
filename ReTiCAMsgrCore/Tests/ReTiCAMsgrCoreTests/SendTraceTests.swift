import Testing
import Foundation
@testable import ReTiCAMsgrCore
import ReTiCA
import ReTiCANode
import ReTiCATransport

/// What the send trace records, and what it leaves out.
@Suite struct SendTraceTests {
    private let peer = Data(repeating: 0xAB, count: 16)

    private func node(linkTo dest: Data? = nil) -> LXMFNode.State {
        var node = LXMFNode.State(identity: Identity(), endpoint: TransportEndpoint.State())
        if let dest { node.router.directLinks[dest] = .establishing }
        return node
    }

    @Test func aLinkFailureIsRecordedWithItsReasonAndRoute() {
        let line = SendTrace.line(for: .endpoint(.delegate(.linkFailed(destinationHash: peer,
                                                                        reason: .establishmentTimedOut))),
                                  node(linkTo: peer))
        #expect(line == "linkFailed to=abababababab reason=establishmentTimedOut "
                + "knownPath=false learned=false link=establishing establishAttempts=0")
    }

    /// `.pathLearned` fires for every announce on the network: only a destination with outbound
    /// work is worth a line.
    @Test func aPathLearnedIsRecordedOnlyForADestinationWithWork() {
        let action = LXMFNode.Action.endpoint(.delegate(.pathLearned(destinationHash: peer, hops: 2)))
        #expect(SendTrace.line(for: action, node()) == nil)
        #expect(SendTrace.line(for: action, node(linkTo: peer))?.hasPrefix("pathLearned to=abababababab hops=2 ") == true)
    }

    @Test func aDeliveryFailureIsRecorded() {
        let hash = Data(repeating: 0x01, count: 32)
        #expect(SendTrace.line(for: .router(.delegate(.deliveryFailed(messageHash: hash))), node())
                == "deliveryFailed msg=010101010101")
    }

    // MARK: - Proof path

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let hub = Data(repeating: 0xCD, count: 16)
    private let messageHash = Data(repeating: 0x01, count: 32)
    private let packetHash = Data(repeating: 0x02, count: 32)
    private var receiptKey: Data { Data(packetHash.prefix(16)) }

    /// A node whose transport holds a route to `peer` via `hub` and one receipt for `messageHash`.
    private func nodeWithReceipt(expiresIn: TimeInterval = 12) -> LXMFNode.State {
        var node = node()
        node.endpoint.transport.learned[peer] = LearnedDestination(
            identity: Identity(), appData: nil, interfaceID: InterfaceID("tcp:hub"),
            hops: 1, nextHop: hub, announceEmitted: 0)
        node.endpoint.transport.pendingReceipts[receiptKey] = Transport.State.PendingReceipt(
            packetHash: packetHash, token: messageHash, identity: Identity(),
            expiresAt: now.addingTimeInterval(expiresIn))
        return node
    }

    private func proofPacket(to destination: Data, payloadLength: Int = 64) -> Data {
        let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                           destinationType: .single, context: .none, contextFlag: false, hops: 0,
                           destinationHash: destination, transportId: nil,
                           payload: Data(repeating: 0x55, count: payloadLength))
        return try! proof.packed()
    }

    /// The send line names the receipt this attempt is waiting on and the route's hops and next hop,
    /// so a late proof can be matched to its attempt and its window.
    @Test func anOpportunisticSendRecordsItsReceiptAndRoute() {
        let action = LXMFNode.Action.router(.delegate(.sendOpportunistic(
            destinationHash: peer, payload: Data(repeating: 0, count: 40), messageHash: messageHash)))
        let line = SendTrace.line(for: action, nodeWithReceipt(), now: now)
        #expect(line == "sendOpportunistic msg=010101010101 to=abababababab bytes=40 attempts=- "
                + "receipt=020202020202 expiresIn=12 knownPath=false learned=true hops=1 nextHop=cdcdcdcdcdcd "
                + "link=none establishAttempts=0")
    }

    /// Every inbound PROOF is recorded against the receipts still outstanding after Transport
    /// handled it: a proof that matched has consumed its receipt (a `singlePacketDelivered` line
    /// follows), one that arrived late finds none, and an invalid one leaves it in place.
    @Test func anInboundProofIsRecordedWithTheOutstandingReceipts() {
        let action = LXMFNode.Action.endpoint(.transport(.received(
            InterfaceID("tcp:hub"), proofPacket(to: Data(repeating: 0x03, count: 16)))))
        #expect(SendTrace.line(for: action, nodeWithReceipt(), now: now)
                == "proofReceived dest=030303030303 bytes=64 if=tcp:hub receipts=[020202020202@+12s]")
        #expect(SendTrace.line(for: action, node(), now: now)
                == "proofReceived dest=030303030303 bytes=64 if=tcp:hub receipts=[]")
    }

    /// Other inbound packets are not recorded: the hub interface carries every announce on the network.
    @Test func anInboundDataPacketIsNotRecorded() {
        let data = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 0,
                          destinationHash: peer, transportId: nil, payload: Data(repeating: 0x55, count: 64))
        let action = LXMFNode.Action.endpoint(.transport(.received(InterfaceID("tcp:hub"), try! data.packed())))
        #expect(SendTrace.line(for: action, nodeWithReceipt(), now: now) == nil)
    }

    @Test func aMatchedProofIsRecorded() {
        let action = LXMFNode.Action.endpoint(.transport(.delegate(.singlePacketDelivered(token: messageHash))))
        #expect(SendTrace.line(for: action, node(), now: now) == "singlePacketDelivered token=010101010101")
    }
}
