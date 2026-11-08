import Testing
import Foundation
import Security
import ComposableArchitecture
import ReTiCAKeychain
@testable import ReTiCAMsgrCore

// Task 3: the channel-key store. Keys appear only as the `mcHexA` / `mcHexB` test constants.

private let keyA = Data(hexString: mcHexA)!
private let keyB = Data(hexString: mcHexB)!
private let keyC = Data(repeating: 0x5C, count: 16)

/// The four generic printing paths a secret could leak through.
private func printings(_ value: Any) -> [String] {
    var dumped = ""
    dump(value, to: &dumped)
    return [String(describing: value), String(reflecting: value), String(customDumping: value), dumped]
}

@Test func mcKeyStoreNewStoreHasNoKey() {
    let (_, store) = mcKeychain()
    #expect(store.presence() == .absent)
    #expect(store.secrets() == nil)
    #expect(store.exportText() == nil)
}

@Test func mcKeyStoreGenerateStoresSixteenBytes() {
    let keychain = InMemoryKeychain()
    let store = MeshCoreKeyStore.live(ops: keychain.ops, randomKey: { keyA })
    #expect(store.generate() == .changed)
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation)?.count == 16)
}

@Test func mcKeyStoreLiveGenerateDiffersEachTime() {
    let (first, firstStore) = mcKeychain()
    let (second, secondStore) = mcKeychain()
    #expect(firstStore.generate() == .changed)
    #expect(secondStore.generate() == .changed)
    let one = first.item(at: MeshCoreKeyStore.keyLocation)
    let two = second.item(at: MeshCoreKeyStore.keyLocation)
    #expect(one?.count == 16)
    #expect(two?.count == 16)
    #expect(one != two)
}

@Test func mcKeyStorePasteStoresTheBytes() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
}

@Test func mcKeyStorePasteAcceptsUppercaseAndSurroundingWhitespace() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(" \(mcHexA.uppercased())\n")) == .changed)
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
}

private let refusedPastes: [String] = {
    let tail30 = String(mcHexA.dropFirst(2))
    let spaced = String(mcHexA.prefix(16)) + " " + String(mcHexA.suffix(15))
    return [
        String(mcHexA.dropLast()),            // 31 characters
        mcHexA + "0",                         // 33 characters
        "zz" + tail30,                        // 32 characters, not all hex
        "0x" + tail30,                        // 0x prefix, 32 characters
        "",
        spaced,                               // a space inside, 32 characters
        "00000000000000000000000000000000",   // an empty slot's secret
        "8b3387e9c5cdea6ac9e5edbaa115cd72",   // MeshCore Public
        "8B3387E9C5CDEA6AC9E5EDBAA115CD72",   // MeshCore Public, uppercase
        "c4d2b6c8254e3b11200f57e95dcb1197",   // ScotMesh's documented secret
    ]
}()

@Test(arguments: refusedPastes)
func mcKeyStorePasteRejects(_ text: String) {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(text)) == .invalid)
    #expect(store.presence() == .absent)
    #expect(keychain.addCount == 0)
}

@Test func mcKeyStorePasteRejectsLeavesTheStoredKey() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText("not a key")) == .invalid)
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
    #expect(keychain.item(at: MeshCoreKeyStore.retiredLocation) == nil)
}

@Test func mcKeyStoreFirstKeyRetiresNothing() {
    let (_, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.secrets()?.retired == [])
}

@Test func mcKeyStoreChangeRetiresTheOldKey() {
    let (_, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .changed)
    #expect(store.secrets()?.current == keyB)
    #expect(store.secrets()?.retired == [keyA])
}

@Test func mcKeyStoreRetiredListSurvivesANewStore() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .changed)
    let reopened = MeshCoreKeyStore.live(ops: keychain.ops)
    #expect(reopened.secrets()?.retired == [keyA])
}

@Test func mcKeyStoreRepastingTheSameKeyChangesNothing() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    let adds = keychain.addCount
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .unchanged)
    #expect(store.secrets()?.retired == [])
    // Read the item itself: `secrets()` filters the current key out of the retired list.
    #expect(keychain.item(at: MeshCoreKeyStore.retiredLocation) == nil)
    #expect(keychain.addCount == adds)
}

@Test func mcKeyStoreReturningToARetiredKeyUnretiresIt() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.secrets()?.current == keyA)
    #expect(store.secrets()?.retired == [keyB])
    // The item too, not only the filtered `secrets()`.
    #expect(keychain.item(at: MeshCoreKeyStore.retiredLocation) == keyB)
}

@Test func mcKeyStoreSecretsNeverListTheCurrentKeyAsRetired() {
    // A crash between the retire write and the key write leaves the current key on the list.
    let (keychain, store) = mcKeychain()
    keychain.set(keyA, at: MeshCoreKeyStore.keyLocation)
    keychain.set(keyA, at: MeshCoreKeyStore.retiredLocation)
    #expect(store.secrets()?.current == keyA)
    #expect(store.secrets()?.retired == [])
}

@Test func mcKeyStoreForgetRemovesOnlyTheNamedKeys() {
    let (_, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .changed)
    #expect(store.paste(MeshCoreKeyText(keyC.hexString)) == .changed)
    #expect(store.secrets()?.retired == [keyA, keyB])
    store.forgetRetired([keyA])
    #expect(store.secrets()?.retired == [keyB])
}

@Test func mcKeyStoreForgetLastDeletesTheItem() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .changed)
    #expect(store.secrets()?.retired == [keyA])
    store.forgetRetired([keyA])
    #expect(keychain.item(at: MeshCoreKeyStore.retiredLocation) == nil)
}

@Test func mcKeyStoreUnreadableIsNotAbsent() {
    let (keychain, store) = mcKeychain()
    keychain.failRead(at: MeshCoreKeyStore.keyLocation, status: errSecInteractionNotAllowed)
    #expect(store.presence() == .unreadable)
}

@Test func mcKeyStoreRejectedReadIsNotAbsent() {
    let (keychain, store) = mcKeychain()
    keychain.set(keyA, at: MeshCoreKeyStore.keyLocation, synchronizable: true)
    #expect(store.presence() == .unreadable)
}

@Test func mcKeyStoreUnreadableKeyIsNotOverwritten() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    keychain.failRead(at: MeshCoreKeyStore.keyLocation, status: errSecInteractionNotAllowed)
    #expect(store.generate() == .storageFailed)
    keychain.clearFailures()
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
}

@Test func mcKeyStoreKeyChangeWithAnUnreadableRetiredListFailsAndKeepsTheKey() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    let adds = keychain.addCount
    keychain.failRead(at: MeshCoreKeyStore.retiredLocation, status: errSecInteractionNotAllowed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .storageFailed)
    keychain.clearFailures()
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
    #expect(keychain.addCount == adds)
}

@Test func mcKeyStoreFailedRetiredWriteKeepsTheOldKey() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    keychain.failAdd(at: MeshCoreKeyStore.retiredLocation, status: errSecNotAvailable)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .storageFailed)
    #expect(keychain.item(at: MeshCoreKeyStore.keyLocation) == keyA)
}

@Test func mcKeyStoreFailedKeyWriteReportsFailure() {
    let (keychain, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    keychain.failAdd(at: MeshCoreKeyStore.keyLocation, status: errSecNotAvailable)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .storageFailed)
    #expect(keychain.item(at: MeshCoreKeyStore.retiredLocation) == keyA)
}

@Test func mcKeyStoreKeyTextNeverPrintsTheKey() {
    let text = MeshCoreKeyText(mcHexA)
    // Booleans only, so a failure message never carries the printed text.
    for printed in printings(text) {
        let leaks = printed.lowercased().contains(mcHexA)
        #expect(!leaks, "a printing path shows the key")
    }
    let revealed = text.reveal() == mcHexA
    #expect(revealed)
}

@Test func mcKeyStoreSecretsNeverPrint() throws {
    let (_, store) = mcKeychain()
    #expect(store.paste(MeshCoreKeyText(mcHexA)) == .changed)
    #expect(store.paste(MeshCoreKeyText(mcHexB)) == .changed)
    let secrets = try #require(store.secrets())
    // Booleans only, so a failure message never carries the printed text.
    for printed in printings(secrets) {
        let lowered = printed.lowercased()
        let leaksRetired = lowered.contains(mcHexA)
        let leaksCurrent = lowered.contains(mcHexB)
        // Data's own printing paths show "16 bytes" or list the bytes.
        let showsBytes = printed.contains("bytes")
        #expect(!leaksRetired, "a printing path shows the retired key")
        #expect(!leaksCurrent, "a printing path shows the current key")
        #expect(!showsBytes, "a printing path shows key bytes")
    }
}

@Test func mcKeyStoreTestValueIsEmptyAndQuiet() {
    #expect(MeshCoreKeyStore.testValue.presence() == .absent)
}
