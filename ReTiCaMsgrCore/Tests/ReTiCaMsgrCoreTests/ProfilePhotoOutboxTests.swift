import Testing
import Foundation
import ReTiCA
@testable import ReTiCaMsgrCore

private let outboxJPEG = TestImages.jpeg(width: 64, height: 64)
private let outboxVersionData = ProfileWire.version(of: outboxJPEG)
private let outboxV = outboxVersionData.hexString

private func outboxDelivery(
    delivered: String? = nil, pending: String? = nil
) -> ProfilePhotoDelivery {
    ProfilePhotoDelivery(
        peerHex: String(repeating: "a", count: 32), deliveredVersion: delivered,
        pendingVersion: pending, pendingHash: pending == nil ? nil : "hash")
}

@Test func outboxNoPhotoNeverSentIsEmpty() {
    let plan = ProfilePhotoOutbox.plan(myVersion: "", myPhoto: nil, delivery: nil, imageAllowed: true)
    #expect(plan.fields.isEmpty)
    #expect(plan.pendingVersion == nil)
}

/// Final review 10: bytes read after a new pick no longer hash to the captured version, so the
/// image must not ride under the old version: tag only, nothing pending.
@Test func outboxBytesOfAnotherVersionSendTagOnly() {
    let newer = TestImages.jpeg(width: 80, height: 80)
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: newer, delivery: nil, imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .tag(version: outboxVersionData))
    #expect(plan.pendingVersion == nil)
}

@Test func outboxFirstSendAttachesPhoto() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: outboxJPEG, delivery: nil, imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .photo(version: outboxVersionData, jpeg: outboxJPEG))
    #expect(plan.pendingVersion == outboxV)
}

@Test func outboxDeliveredSendsTagOnly() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: outboxJPEG, delivery: outboxDelivery(delivered: outboxV),
        imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .tag(version: outboxVersionData))
    #expect(plan.pendingVersion == nil)
}

@Test func outboxSkipsImageWhilePendingForSameVersion() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: outboxJPEG, delivery: outboxDelivery(pending: outboxV),
        imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .tag(version: outboxVersionData))
    #expect(plan.pendingVersion == nil)
}

@Test func outboxAttachesNewVersionWhileOldPending() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: outboxJPEG,
        delivery: outboxDelivery(delivered: "1111111111111111", pending: "0011223344556677"),
        imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .photo(version: outboxVersionData, jpeg: outboxJPEG))
    #expect(plan.pendingVersion == outboxV)
}

@Test func outboxImageNotAllowedSendsTagOnly() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: outboxJPEG, delivery: nil, imageAllowed: false)
    #expect(ProfileWire.decode(plan.fields) == .tag(version: outboxVersionData))
    #expect(plan.pendingVersion == nil)
}

@Test func outboxRemovalSentUntilConfirmed() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: "", myPhoto: nil, delivery: outboxDelivery(delivered: outboxV), imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .removed)
    #expect(plan.pendingVersion == "")
}

@Test func outboxRemovalConfirmedIsEmpty() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: "", myPhoto: nil, delivery: outboxDelivery(delivered: ""), imageAllowed: true)
    #expect(plan.fields.isEmpty)
    #expect(plan.pendingVersion == nil)
}

@Test func outboxReattachesAfterRemovalConfirmed() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: outboxJPEG, delivery: outboxDelivery(delivered: ""),
        imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .photo(version: outboxVersionData, jpeg: outboxJPEG))
    #expect(plan.pendingVersion == outboxV)
}

@Test func outboxMissingFileSendsTagOnly() {
    let plan = ProfilePhotoOutbox.plan(
        myVersion: outboxV, myPhoto: nil, delivery: nil, imageAllowed: true)
    #expect(ProfileWire.decode(plan.fields) == .tag(version: outboxVersionData))
    #expect(plan.pendingVersion == nil)
}
