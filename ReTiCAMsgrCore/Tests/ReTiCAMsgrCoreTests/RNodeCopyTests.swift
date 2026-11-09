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
        RNodeCopy.connectButton, RNodeCopy.connecting, RNodeCopy.changesApply,
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
    let expected: [(RNodeSettingsProblem, String)] = [
        (.frequencyMissing, "Enter a frequency."),
        (.frequencyUnreadable, "Enter the frequency in MHz, like 868.1."),
        (.frequencyOutOfRange, "Enter a frequency between 137 and 3000 MHz."),
        (.bandwidthUnreadable, "Enter the bandwidth in kHz, like 62.5."),
        (.bandwidthOutOfRange, "Enter a bandwidth between 7.8 and 1625 kHz."),
        (.spreadingFactorOutOfRange, "Use a spreading factor from 5 to 12."),
        (.codingRateOutOfRange, "Use a coding rate from 5 to 8."),
        (.txPowerOutOfRange, "Use a TX power from 0 to 37 dBm. Your radio may allow less."),
    ]
    #expect(expected.count == RNodeSettingsProblem.allCases.count)
    for (problem, text) in expected {
        #expect(RNodeCopy.problemMessage(problem) == text, "\(problem)")
    }
}

/// Settings lists the problems minus `.frequencyMissing`, which the grey notice covers.
@MainActor @Test func rnCopyShownProblemsLeaveOutTheMissingFrequency() async {
    let store = rnStore()
    #expect(store.state.rnodeSettingsProblems == [.frequencyMissing])
    #expect(store.state.rnodeShownProblems == [])
    await store.send(.rnodeFrequencyTextChanged("868,1"))
    #expect(store.state.rnodeShownProblems == [.frequencyUnreadable])
    await store.send(.rnodeFrequencyTextChanged("868.1"))
    await store.send(.rnodeSpreadingFactorChanged(13))
    #expect(store.state.rnodeShownProblems == [.spreadingFactorOutOfRange])
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

/// The radio's own button (or Connect) applies a change, and so does any reconnect the app makes by
/// itself (a foreground or a push wake re-syncs the slot).
@Test func rnCopyFooterSaysWhatAppliesAChange() {
    #expect(RNodeCopy.changesApply == "Changes take effect when you tap Connect RNode or Connect, and again "
            + "whenever this app reconnects by itself, like when you come back to it or a notification wakes it.")
    #expect(RNodeCopy.footer.hasSuffix(" " + RNodeCopy.changesApply))
    #expect(RNodeCopy.changesApply.contains(RNodeCopy.connectButton))
    #expect(!RNodeCopy.footer.contains("next Connect"))
}

@Test func rnCopyConnectButtonLabels() {
    #expect(RNodeCopy.connectButton == "Connect RNode")
    #expect(RNodeCopy.connecting == "Connecting…")
    #expect(RNodeCopy.pairingNotice.contains("tap Connect RNode"))
}
#endif
