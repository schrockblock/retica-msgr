import Foundation
import ReTiCAInterfaces

/// What Diagnostics and Settings show about the RNode radio (spec 2026-11-08 §6): plain, session-only
/// app state. Lane C only renders it; lane D fills it from the RNode endpoint's report, telemetry and
/// counters. App-local value types on purpose: lane C references no RNode library type.
public struct RNodeStatus: Equatable, Sendable {
    /// LoRa parameters in the app's units: hertz, SF, CR (5...8), dBm.
    public struct Params: Equatable, Sendable {
        public var frequencyHz: Int
        public var bandwidthHz: Int
        public var spreadingFactor: Int
        public var codingRate: Int
        public var txPowerDBm: Int

        public init(frequencyHz: Int, bandwidthHz: Int, spreadingFactor: Int, codingRate: Int, txPowerDBm: Int) {
            self.frequencyHz = frequencyHz
            self.bandwidthHz = bandwidthHz
            self.spreadingFactor = spreadingFactor
            self.codingRate = codingRate
            self.txPowerDBm = txPowerDBm
        }
    }

    /// Cumulative since launch.
    public struct Counters: Equatable, Sendable {
        public var received: Int
        public var sent: Int
        public var oversize: Int
        public var queueFull: Int
        public var sendFailed: Int
        public var hardwareErrors: Int

        public init(received: Int = 0, sent: Int = 0, oversize: Int = 0, queueFull: Int = 0,
                    sendFailed: Int = 0, hardwareErrors: Int = 0) {
            self.received = received
            self.sent = sent
            self.oversize = oversize
            self.queueFull = queueFull
            self.sendFailed = sendFailed
            self.hardwareErrors = hardwareErrors
        }

        /// The RNode endpoint's counters (`RNodeEndpoint.State.counters`), field by field.
        public init(_ counters: RNodeCounters) {
            self.init(received: counters.received, sent: counters.sent, oversize: counters.oversize,
                      queueFull: counters.queueFull, sendFailed: counters.sendFailed,
                      hardwareErrors: counters.hardwareErrors)
        }

        public static func + (lhs: Self, rhs: Self) -> Self {
            Self(received: lhs.received + rhs.received, sent: lhs.sent + rhs.sent,
                 oversize: lhs.oversize + rhs.oversize, queueFull: lhs.queueFull + rhs.queueFull,
                 sendFailed: lhs.sendFailed + rhs.sendFailed,
                 hardwareErrors: lhs.hardwareErrors + rhs.hardwareErrors)
        }

        public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
    }

    public var online: Bool
    /// The radio's own name. Unauthenticated text from the air: rows only, never a reason.
    public var radioName: String?
    /// The firmware version, as `"1.86"`.
    public var firmware: String?
    /// The board's platform byte (0x80 ESP32, 0x70 nRF52).
    public var platform: UInt8?
    /// The LoRa parameters the radio reported back.
    public var reported: Params?
    /// The on-air bitrate in bits per second.
    public var bitrate: Int?
    /// The last disconnect's reason, if the radio gave one.
    public var offlineReason: String?
    /// Set while the Bluetooth path to the radio is unavailable.
    public var adapterUnavailable: BLEAdapterUnavailable?
    /// dBm.
    public var lastRSSI: Int?
    /// dB.
    public var lastSNR: Double?
    /// Percent, 0...100 (`2.15` is 2.15%).
    public var channelLoadShort: Double?
    public var channelLoadLong: Double?
    /// Percent, 0...100.
    public var airtimeShort: Double?
    public var airtimeLong: Double?
    /// dBm.
    public var noiseFloor: Int?
    /// The radio's last hardware error code.
    public var lastHardwareError: UInt8?
    public var counters: Counters

    public init(online: Bool = false, radioName: String? = nil, firmware: String? = nil, platform: UInt8? = nil,
                reported: Params? = nil, bitrate: Int? = nil, offlineReason: String? = nil,
                adapterUnavailable: BLEAdapterUnavailable? = nil, lastRSSI: Int? = nil, lastSNR: Double? = nil,
                channelLoadShort: Double? = nil, channelLoadLong: Double? = nil,
                airtimeShort: Double? = nil, airtimeLong: Double? = nil, noiseFloor: Int? = nil,
                lastHardwareError: UInt8? = nil, counters: Counters = Counters()) {
        self.online = online
        self.radioName = radioName
        self.firmware = firmware
        self.platform = platform
        self.reported = reported
        self.bitrate = bitrate
        self.offlineReason = offlineReason
        self.adapterUnavailable = adapterUnavailable
        self.lastRSSI = lastRSSI
        self.lastSNR = lastSNR
        self.channelLoadShort = channelLoadShort
        self.channelLoadLong = channelLoadLong
        self.airtimeShort = airtimeShort
        self.airtimeLong = airtimeLong
        self.noiseFloor = noiseFloor
        self.lastHardwareError = lastHardwareError
        self.counters = counters
    }

    /// For Settings: the same sentences as `MeshCoreStatus.userMessage`, nil while the adapter is
    /// available.
    public var userMessage: String? {
        adapterUnavailable?.userMessage
    }
}
