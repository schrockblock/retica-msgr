import Testing
@testable import ReTiCaMsgrCore

@Test func expiryPresetCasesAreSignalsInOrder() {
    #expect(ExpiryPreset.allCases.map(\.seconds) == [0, 30, 300, 3_600, 28_800, 86_400, 604_800, 2_419_200])
    #expect(ExpiryPreset.allCases.map(\.label)
            == ["Off", "30 seconds", "5 minutes", "1 hour", "8 hours", "1 day", "1 week", "4 weeks"])
    #expect(ExpiryPreset.fourWeeks.seconds == ExpiryWire.maxSeconds)
}

/// A peer may send a value that is not a preset: the largest unit that divides it evenly.
@Test func expiryPresetLabelForArbitrarySeconds() {
    #expect(ExpiryPreset.label(forSeconds: 0) == "Off")
    #expect(ExpiryPreset.label(forSeconds: 1) == "1 second")
    #expect(ExpiryPreset.label(forSeconds: 90) == "90 seconds")
    #expect(ExpiryPreset.label(forSeconds: 120) == "2 minutes")
    #expect(ExpiryPreset.label(forSeconds: 7_200) == "2 hours")
    #expect(ExpiryPreset.label(forSeconds: 172_800) == "2 days")
    #expect(ExpiryPreset.label(forSeconds: 1_209_600) == "2 weeks")
    #expect(ExpiryPreset.label(forSeconds: 3_660) == "61 minutes")
}

@Test func expiryPresetAnnouncementBodies() {
    #expect(ExpiryPreset.announcement(seconds: 86_400) == "Disappearing messages set to 1 day")
    #expect(ExpiryPreset.announcement(seconds: 0) == "Disappearing messages turned off")
    #expect(ExpiryPreset.peerAnnouncement(peerName: "Ada", seconds: 300) == "Ada set disappearing messages to 5 minutes")
    #expect(ExpiryPreset.peerAnnouncement(peerName: "Ada", seconds: 0) == "Ada turned disappearing messages off")
    #expect(ExpiryPreset.peerAnnouncement(peerName: nil, seconds: 300) == "Them set disappearing messages to 5 minutes")
}

@Test func expiryPresetCaveatNamesOtherApps() {
    #expect(ExpiryPreset.caveat == "Only ReTiCaMsgr peers honour this. Other apps keep messages.")
}
