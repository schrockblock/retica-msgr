import Foundation
import ReTiCAInterfaces

/// What Diagnostics shows about the Meshtastic radio (spec 2026-10-16 §7 lane D): plain,
/// session-only app state. Lane D only renders it. Lane E fills it from the Meshtastic endpoint's
/// delegates (`.radioOnline(myNodeNum:modemPreset:)`, `.radioOffline(reason:)`,
/// `.adapterUnavailable`, spec Contract 3) and from the interface's reassembler and sender
/// counters (spec §5.2, §5.3).
public struct MeshtasticStatus: Equatable, Sendable {
    /// Cumulative since launch.
    public struct Counters: Equatable, Sendable {
        /// Reassembler (spec §5.2).
        public var malformed: Int
        public var evicted: Int
        public var timedOut: Int
        public var oversize: Int
        public var completed: Int
        /// Sender (spec §5.3).
        public var queueFull: Int
        public var sendFailed: Int

        public init(malformed: Int = 0, evicted: Int = 0, timedOut: Int = 0, oversize: Int = 0,
                    completed: Int = 0, queueFull: Int = 0, sendFailed: Int = 0) {
            self.malformed = malformed
            self.evicted = evicted
            self.timedOut = timedOut
            self.oversize = oversize
            self.completed = completed
            self.queueFull = queueFull
            self.sendFailed = sendFailed
        }
    }

    public var online: Bool
    /// Raw `Config.LoRaConfig.ModemPreset` value from the radio, nil until it is known.
    public var modemPreset: Int?
    public var myNodeNum: UInt32?
    /// The last disconnect's reason, if the radio gave one.
    public var offlineReason: String?
    /// Set while the Bluetooth path to the radio is unavailable (including Contract 2's
    /// "ReTiCAMeshtasticLive not installed" stub).
    public var adapterUnavailable: BLEAdapterUnavailable?
    public var counters: Counters

    public init(online: Bool = false, modemPreset: Int? = nil, myNodeNum: UInt32? = nil,
                offlineReason: String? = nil, adapterUnavailable: BLEAdapterUnavailable? = nil,
                counters: Counters = Counters()) {
        self.online = online
        self.modemPreset = modemPreset
        self.myNodeNum = myNodeNum
        self.offlineReason = offlineReason
        self.adapterUnavailable = adapterUnavailable
        self.counters = counters
    }
}

extension MeshtasticStatus.Counters {
    /// The endpoint's public counters (spec Contract 3), field for field.
    public init(_ counters: MeshtasticCounters) {
        self.init(malformed: counters.malformed, evicted: counters.evicted, timedOut: counters.timedOut,
                  oversize: counters.oversize, completed: counters.completed,
                  queueFull: counters.queueFull, sendFailed: counters.sendFailed)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(malformed: lhs.malformed + rhs.malformed, evicted: lhs.evicted + rhs.evicted,
             timedOut: lhs.timedOut + rhs.timedOut, oversize: lhs.oversize + rhs.oversize,
             completed: lhs.completed + rhs.completed, queueFull: lhs.queueFull + rhs.queueFull,
             sendFailed: lhs.sendFailed + rhs.sendFailed)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}
