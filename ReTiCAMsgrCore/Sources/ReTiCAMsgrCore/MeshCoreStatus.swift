import Foundation
import ReTiCAInterfaces

/// What Diagnostics and Settings show about the MeshCore radio (spec 2026-11-07 §6): plain,
/// session-only app state. Lane C only renders it; lane D fills it from the MeshCore endpoint's
/// delegates, its `details` sink (radio name, firmware code, channel slot) and its counters.
///
/// Holds nothing secret: no channel key, no retired key, no fingerprint of either.
public struct MeshCoreStatus: Equatable, Sendable {
    /// The radio's LoRa settings, as it reported them.
    public struct LoRaParams: Equatable, Sendable {
        public var spreadingFactor: UInt8
        public var bandwidthHz: UInt32
        public var codingRate: UInt8

        public init(spreadingFactor: UInt8, bandwidthHz: UInt32, codingRate: UInt8) {
            self.spreadingFactor = spreadingFactor
            self.bandwidthHz = bandwidthHz
            self.codingRate = codingRate
        }
    }

    /// Cumulative since launch.
    public struct Counters: Equatable, Sendable {
        public var malformed: Int
        public var notAddressed: Int
        public var evicted: Int
        public var timedOut: Int
        public var oversize: Int
        public var completed: Int
        public var queueFull: Int
        public var sendFailed: Int
        public var announcesLimited: Int
        public var pathRequestsLimited: Int

        public init(malformed: Int = 0, notAddressed: Int = 0, evicted: Int = 0, timedOut: Int = 0,
                    oversize: Int = 0, completed: Int = 0, queueFull: Int = 0, sendFailed: Int = 0,
                    announcesLimited: Int = 0, pathRequestsLimited: Int = 0) {
            self.malformed = malformed
            self.notAddressed = notAddressed
            self.evicted = evicted
            self.timedOut = timedOut
            self.oversize = oversize
            self.completed = completed
            self.queueFull = queueFull
            self.sendFailed = sendFailed
            self.announcesLimited = announcesLimited
            self.pathRequestsLimited = pathRequestsLimited
        }
    }

    public var online: Bool
    /// The radio's own name. Unauthenticated text from the air: rows only, never a reason.
    public var radioName: String?
    public var params: LoRaParams?
    public var firmwareCode: UInt8?
    public var channelSlot: UInt8?
    /// The last disconnect's reason, if the radio gave one.
    public var offlineReason: String?
    /// Set while the Bluetooth path to the radio is unavailable.
    public var adapterUnavailable: BLEAdapterUnavailable?
    /// A turn-off couldn't remove our slot from the radio.
    public var channelLeftOnRadio: Bool
    /// The last turn-off removed our slot.
    public var channelRemoved: Bool
    public var counters: Counters

    public init(online: Bool = false, radioName: String? = nil, params: LoRaParams? = nil,
                firmwareCode: UInt8? = nil, channelSlot: UInt8? = nil, offlineReason: String? = nil,
                adapterUnavailable: BLEAdapterUnavailable? = nil, channelLeftOnRadio: Bool = false,
                channelRemoved: Bool = false, counters: Counters = Counters()) {
        self.online = online
        self.radioName = radioName
        self.params = params
        self.firmwareCode = firmwareCode
        self.channelSlot = channelSlot
        self.offlineReason = offlineReason
        self.adapterUnavailable = adapterUnavailable
        self.channelLeftOnRadio = channelLeftOnRadio
        self.channelRemoved = channelRemoved
        self.counters = counters
    }

    /// For Settings: the driver's own text for `.other`, a sentence for the causes the user can act
    /// on, nil while the adapter is available.
    public var userMessage: String? {
        adapterUnavailable?.userMessage
    }
}

extension MeshCoreStatus.LoRaParams {
    /// The LoRa settings the radio reported at `.connected`.
    public init(_ params: MeshCoreLinkParams) {
        self.init(spreadingFactor: params.spreadingFactor, bandwidthHz: params.bandwidthHz,
                  codingRate: params.codingRate)
    }
}

extension MeshCoreStatus.Counters {
    /// A slot's counters, as the endpoint reports them.
    public init(_ counters: MeshCoreCounters) {
        self.init(malformed: counters.malformed, notAddressed: counters.notAddressed,
                  evicted: counters.evicted, timedOut: counters.timedOut, oversize: counters.oversize,
                  completed: counters.completed, queueFull: counters.queueFull,
                  sendFailed: counters.sendFailed, announcesLimited: counters.announcesLimited,
                  pathRequestsLimited: counters.pathRequestsLimited)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(malformed: lhs.malformed + rhs.malformed, notAddressed: lhs.notAddressed + rhs.notAddressed,
             evicted: lhs.evicted + rhs.evicted, timedOut: lhs.timedOut + rhs.timedOut,
             oversize: lhs.oversize + rhs.oversize, completed: lhs.completed + rhs.completed,
             queueFull: lhs.queueFull + rhs.queueFull, sendFailed: lhs.sendFailed + rhs.sendFailed,
             announcesLimited: lhs.announcesLimited + rhs.announcesLimited,
             pathRequestsLimited: lhs.pathRequestsLimited + rhs.pathRequestsLimited)
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}
