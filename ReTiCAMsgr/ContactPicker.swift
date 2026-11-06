//
//  ContactPicker.swift
//  ReTiCAMsgr
//

import SwiftUI
import Contacts
import ContactsUI

#if os(iOS)
/// The system contact picker. Needs no permission of its own and returns the identifier and
/// formatted name even under limited access (spec 2026-10-11 §2).
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (_ identifier: String, _ name: String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPicker
        init(_ parent: ContactPicker) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact"
            parent.onPick(contact.identifier, name)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
#else
/// The Mac contact picker: a popover anchored to this view, shown once the view is in a window.
struct ContactPicker: NSViewRepresentable {
    let onPick: (_ identifier: String, _ name: String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onMovedToWindow = { [weak view] in
            guard let view else { return }
            context.coordinator.show(relativeTo: view)
        }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// `CNContactPicker` needs a window to anchor to, which exists only after the view is placed.
    final class AnchorView: NSView {
        var onMovedToWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onMovedToWindow?() }
        }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPicker
        /// Held strongly: the picker is dismissed if it is deallocated.
        private let picker = CNContactPicker()
        private var picked = false
        private var shown = false

        init(_ parent: ContactPicker) {
            self.parent = parent
            super.init()
            picker.delegate = self
        }

        func show(relativeTo view: NSView) {
            guard !shown else { return }
            shown = true
            // Deferred so the window has finished laying the view out.
            DispatchQueue.main.async { [picker] in
                // The sheet may have closed before the next turn of the run loop.
                guard view.window != nil else { return }
                picker.showRelative(to: view.bounds, of: view, preferredEdge: .maxY)
            }
        }

        func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
            picked = true
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact"
            parent.onPick(contact.identifier, name)
        }

        func contactPickerDidClose(_ picker: CNContactPicker) {
            if !picked { parent.onCancel() }
        }
    }
}
#endif
