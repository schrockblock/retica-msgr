#if DEBUG
import Testing
@testable import ReTiCAMsgrCore

// RNode Settings copy (lane C, Task 5). The copy says "this app", never the app's name.

@Test func rnCopyNoStringNamesTheApp() {
    for text in RNodeCopy.all {
        #expect(!text.lowercased().contains("reticamsgr"), "\(text)")
    }
}

/// Guards `all` itself: a string left out of it would escape `rnCopyNoStringNamesTheApp`.
@Test func rnCopyAllListsEveryString() {
    let constants = [
        RNodeCopy.header, RNodeCopy.toggle, RNodeCopy.radioRow, RNodeCopy.chooseRadio,
        RNodeCopy.frequencyRow, RNodeCopy.frequencyPrompt, RNodeCopy.bandwidthRow,
        RNodeCopy.spreadingFactorRow, RNodeCopy.codingRateRow, RNodeCopy.txPowerRow,
        RNodeCopy.incompleteNotice, RNodeCopy.boardsNotice, RNodeCopy.pairingNotice, RNodeCopy.footer,
    ]
    for text in constants {
        #expect(RNodeCopy.all.contains(text), "\(text)")
    }
    for problem in RNodeSettingsProblem.allCases {
        #expect(RNodeCopy.all.contains(RNodeCopy.problemMessage(problem)), "\(problem)")
    }
}

@Test func rnCopyEveryProblemHasAMessage() {
    let messages = RNodeSettingsProblem.allCases.map { RNodeCopy.problemMessage($0) }
    for message in messages { #expect(!message.isEmpty) }
    #expect(Set(messages).count == messages.count)
}

@Test func rnCopyProblemMessagesAreTheSpecText() {
    #expect(RNodeCopy.problemMessage(.frequencyMissing) == "Enter a frequency.")
    #expect(RNodeCopy.problemMessage(.frequencyUnreadable) == "Enter the frequency in MHz, like 868.1.")
    #expect(RNodeCopy.problemMessage(.txPowerOutOfRange)
            == "Use a TX power from 0 to 37 dBm. Your radio may allow less.")
}

@Test func rnCopyBoardsNoticeNamesEveryBLEBoard() {
    for board in ["Heltec V3 and V4", "T3S3", "T-Deck", "T-Beam Supreme", "XIAO S3", "RAK4631", "T-Echo",
                  "Heltec T114"] {
        #expect(RNodeCopy.boardsNotice.contains(board), "\(board)")
    }
}

@Test func rnCopyBoardsNoticeNamesTheClassicOnlyBoards() {
    for board in ["original T-Beam", "LoRa32", "Heltec V2", "RNode NG"] {
        #expect(RNodeCopy.boardsNotice.contains(board), "\(board)")
    }
}

/// Carry from Task 2 (F18): the incomplete notice and a text problem's message never stack.
@MainActor @Test func rnCopyIncompleteNoticeShowsOnlyWithoutATextProblem() async {
    let store = rnStore()
    #expect(store.state.rnodeIncompleteNoticeVisible)
    await store.send(.rnodeFrequencyTextChanged("868,1"))
    #expect(store.state.rnodeFrequencyHz == nil)
    #expect(!store.state.rnodeIncompleteNoticeVisible)
    await store.send(.rnodeFrequencyTextChanged(""))
    #expect(store.state.rnodeIncompleteNoticeVisible)
    await store.send(.rnodeFrequencyTextChanged("868.1"))
    #expect(!store.state.rnodeIncompleteNoticeVisible)
}

@Test func rnCopyPairingNoticeSaysTheAppReconnects() {
    #expect(RNodeCopy.pairingNotice.contains("reconnects by itself"))
}

@Test func rnCopyFooterSaysChangesWaitForConnect() {
    #expect(RNodeCopy.footer.hasSuffix("Changes take effect on the next Connect."))
}
#endif
