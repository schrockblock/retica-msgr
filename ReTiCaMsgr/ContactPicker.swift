//
//  ContactPicker.swift
//  ReTiCaMsgr
//

import SwiftUI
import Contacts
import ContactsUI

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
