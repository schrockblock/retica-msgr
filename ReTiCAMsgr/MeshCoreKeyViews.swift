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
///
/// No copy path here bypasses Settings' Copy button, whose pasteboard item is local-only and expires:
/// the key text is not selectable, and on iOS the share sheet leaves out the system Copy action.
struct MeshCoreShareKeySheet: View {
    let key: MeshCoreKeyText

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var showingActivity = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Not `.textSelection(.enabled)`: its Copy would put a plain, permanent item on the
                    // pasteboard that Universal Clipboard sends to other devices.
                    Text(key.reveal())
                        .font(.system(.body, design: .monospaced))
                    shareButton
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
            #if os(iOS)
            // At Form level, like `MeshCoreKeyPresentations`: a Form row only presents while it is drawn.
            .sheet(isPresented: $showingActivity) {
                MeshCoreActivityView(text: key.reveal())
                    .presentationDetents([.medium, .large])
            }
            #endif
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        #if os(iOS)
        // A standard Form button row is hittable across its width already.
        Button {
            showingActivity = true
        } label: {
            Label(MeshCoreCopy.shareKey, systemImage: "square.and.arrow.up")
        }
        #else
        // macOS's share picker proposes Mail, Messages, Notes, Freeform, Journal and Reminders for a
        // string; none is a Copy action.
        ShareLink(item: key.reveal()) {
            Label(MeshCoreCopy.shareKey, systemImage: "square.and.arrow.up")
        }
        #endif
    }
}

#if os(iOS)
/// The system share sheet without its Copy action, which would write a plain, permanent,
/// Universal-Clipboard item and bypass Settings' local-only, expiring copy. `ShareLink` can't
/// exclude activities, so this wraps `UIActivityViewController` directly.
private struct MeshCoreActivityView: UIViewControllerRepresentable {
    let text: String

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.excludedActivityTypes = [.copyToPasteboard]
        // Finishing or cancelling an activity closes the sheet that hosts this controller.
        controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
#endif
