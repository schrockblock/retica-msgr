import Foundation
import SQLiteData

/// One entry in the "already downloaded from a propagation node" set, mirrored from
/// `LXMFRouter.State.downloadedTransientIds` so a cold start does not re-request transient IDs
/// already downloaded in a previous session.
///
/// **This table is deliberately NOT pruned.** The in-memory set is also unbounded; adding a cap
/// here would quietly reintroduce the trade that Task 1 explicitly declined to make — evicted IDs
/// would look "new" on the next offer and re-download the same messages. There is no field data
/// yet to price that trade. Revisit trigger: a user report that the table is growing uncomfortably
/// large, or operational data showing a representative steady-state size.
///
/// **Write policy — one row per downloaded batch, no batching of batches.** Each call to
/// `.messagesDownloaded` is persisted immediately. Same rationale as `SeenHashRow`: the kill is
/// the normal path, so a delayed flush is a routine loss window.
@Table
public struct DownloadedTransientIdRow: Equatable, Sendable {
    /// LXMF transient_id (32 bytes, hex-encoded). Primary key; matches the dedup key in
    /// `LXMFPropagation` and `LXMFRouter.State.downloadedTransientIds`.
    public var transientIdHex: String
    /// When this transient ID was first downloaded (wall-clock time from the `\.date` dependency).
    public var storedAt: Date

    public init(transientIdHex: String, storedAt: Date) {
        self.transientIdHex = transientIdHex
        self.storedAt = storedAt
    }
}
