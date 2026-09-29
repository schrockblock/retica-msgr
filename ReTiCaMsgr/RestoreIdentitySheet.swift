import SwiftUI
import UniformTypeIdentifiers
import ReTiCaMsgrCore

/// Paste the base32 text form or pick the 64-byte identity file (spec §5.5). Input lives only
/// here and is cleared on success, cancel, dismiss and rejection. Nothing is logged.
struct RestoreIdentitySheet: View {
    let runtime: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var pendingKey: Data?
    @State private var summary: String?
    @State private var message: String?
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        take(IdentityRestore.key(fromText: text), summary: "Pasted text")
                    }
                    Button("Choose identity file") { showImporter = true }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Paste the text form from Nbhd's Identity Export (or Sideband), or choose the 64-byte identity file.")
                }
                if let summary {
                    Section {
                        HStack {
                            Text(summary)
                            Spacer()
                            Button("Clear") { clear() }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Restore identity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { clear(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { restore() }
                        .disabled(pendingKey == nil || runtime.isBuilding)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
                guard case let .success(urls) = result, let url = urls.first else { return }
                guard let data = IdentityRestore.readKeyFile(at: url) else {
                    clear()
                    message = "That file couldn't be read, or it is larger than \(IdentityRestore.maxFileBytes) bytes."
                    return
                }
                take(IdentityRestore.key(fromFile: data), summary: url.lastPathComponent)
            }
            .onDisappear { clear() }
        }
    }

    private func take(_ result: Result<Data, IdentityRestore.Rejection>, summary: String) {
        switch result {
        case let .success(key):
            pendingKey = key
            self.summary = summary
            message = nil
        case let .failure(rejection):
            clear()
            message = IdentityRecoveryText.restore(.rejected(rejection))
        }
    }

    private func restore() {
        guard let key = pendingKey else { return }
        let result = runtime.restore(privateKey: key)
        clear()
        switch result {
        case .restored, .refused(.notMissing):
            dismiss()
        default:
            message = IdentityRecoveryText.restore(result)
        }
    }

    private func clear() {
        pendingKey = nil
        summary = nil
    }
}
