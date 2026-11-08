//
//  MeshCoreKeyViews.swift
//  ReTiCAMsgr
//

#if DEBUG
import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

/// Paste a MeshCore channel key (spec 2026-11-07 §6). The typed text lives only in this sheet's
/// `@State`, as a plain String because a TextField needs one; it becomes a `MeshCoreKeyText` at Save
/// and is cleared on Save, Cancel and any other dismissal. The sheet calls the key store itself and
/// sends the reducer only the result, so the key never enters TCA state or actions.
struct MeshCorePasteKeySheet: View {
    let store: StoreOf<AppFeature>
    let keyStore: MeshCoreKeyStore

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                TextField(MeshCoreCopy.pastePrompt, text: $text)
                    .platformAutocapitalization(.never)
                    .platformKeyboard(.asciiCapable)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            }
            .scrollingFormStyle()
            .macSheetFrame()
            .navigationTitle(MeshCoreCopy.pasteTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MeshCoreCopy.cancelButton) {
                        text = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(MeshCoreCopy.saveButton) { save() }
                        .disabled(isEmpty)
                }
            }
            // A swipe-down skips both buttons.
            .onDisappear { text = "" }
        }
    }

    private func save() {
        let key = MeshCoreKeyText(text)
        text = ""
        let result = keyStore.paste(key)
        store.send(.meshCoreKeyDidChange(result))
        dismiss()
    }
}

/// Shows the channel key so it can be read out or shared. The key arrives as a `MeshCoreKeyText`
/// held in Settings' `@State` for as long as this sheet is up; dismissing drops it.
struct MeshCoreShareKeySheet: View {
    let key: MeshCoreKeyText

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(key.reveal())
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    ShareLink(item: key.reveal()) {
                        Label(MeshCoreCopy.shareKey, systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(MeshCoreCopy.shareBody)
                }
            }
            .scrollingFormStyle()
            .macSheetFrame()
            .navigationTitle(MeshCoreCopy.shareTitle)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(MeshCoreCopy.doneButton) { dismiss() }
                }
            }
        }
    }
}
#endif
