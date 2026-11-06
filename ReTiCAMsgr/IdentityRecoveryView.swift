import SwiftUI
import ReTiCAMsgrCore

struct IdentityRecoveryView: View {
    let runtime: AppRuntime
    @State private var showRestore = false
    @State private var confirmAccept = false
    @State private var confirmCreate = false

    var body: some View {
        let screen = IdentityRecoveryText.screen(for: runtime.state)
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(screen.message)
                    .font(.body)
                if let detail = screen.detail {
                    DisclosureGroup("Details") {
                        Text(detail)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(spacing: 12) {
                    if screen.showsRestore {
                        Button("Restore from backup") { showRestore = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(runtime.isBuilding)
                    }
                    if screen.showsAccept {
                        Button("Use the new identity") { confirmAccept = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(runtime.isBuilding)
                    }
                    if screen.showsCreate {
                        Button("Create a new identity") { confirmCreate = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(runtime.isBuilding)
                    }
                    Button("Retry") { runtime.retry() }
                        .buttonStyle(.bordered)
                        .disabled(runtime.isBuilding)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
            .padding()
            .navigationTitle(screen.title)
            .sheet(isPresented: $showRestore) {
                RestoreIdentitySheet(runtime: runtime)
            }
            .confirmationDialog("Use the new identity?", isPresented: $confirmAccept, titleVisibility: .visible) {
                Button("Use the new identity", role: .destructive) { runtime.acceptNewIdentity() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(IdentityRecoveryText.acceptConfirmation)
            }
            .confirmationDialog("Create a new identity?", isPresented: $confirmCreate, titleVisibility: .visible) {
                Button("Create a new identity", role: .destructive) { runtime.createNewIdentity() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(IdentityRecoveryText.createConfirmation)
            }
        }
    }
}
