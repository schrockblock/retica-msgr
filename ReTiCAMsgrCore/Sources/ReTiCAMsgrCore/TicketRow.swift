import Foundation
import SQLiteData

/// The stamp ticket a peer gave us (LXMF 1.3.0), mirrored from `LXMFNode.State.outboundTickets`
/// so the next message to that peer after a relaunch is stamped with the ticket instead of
/// proof-of-work.
///
/// One row per peer `lxmf.delivery` destination, newest ticket wins — the library keeps one
/// outbound ticket per peer, replaced by each newer one received.
///
/// **Write policy — upsert on every `.ticketReceived`.** The library reports it only when the
/// stored ticket for a peer changes, which is rare (a peer sends a fresh ticket at most about
/// daily), so writing per event costs nothing.
///
/// **Expiry.** Rows with `expires` before now are deleted at launch, before the read; the
/// library's `.rehydrateTickets` also drops an expired outbound ticket, but cannot delete the row.
/// This app does not issue tickets, so nothing of the inbound side is stored.
///
/// `expires` is a REAL (seconds since 1970), never an integer: it comes from the peer as a float.
@Table
public struct TicketRow: Equatable, Sendable {
    /// The peer's `lxmf.delivery` destination hash (16 bytes, hex). Primary key.
    public var destinationHashHex: String
    /// The ticket bytes (`LXMessage.ticketLength`).
    public var ticket: Data
    /// When the ticket stops being usable, seconds since 1970.
    public var expires: Double

    public init(destinationHashHex: String, ticket: Data, expires: Double) {
        self.destinationHashHex = destinationHashHex
        self.ticket = ticket
        self.expires = expires
    }
}
