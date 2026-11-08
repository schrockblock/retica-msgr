//
//  AddressView.swift
//  ReTiCAMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

struct AddressView: View {
    let store: StoreOf<AppFeature>
    @Environment(\.dismiss) private var dismiss
    /// Legacy is the bare address every earlier ReTiCAMsgr build displayed and scans; Standard is
    /// the lxma:// contact URI MeshChatX, Columba and Retichat read.
    @State private var showsLegacyQR = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    MyAvatarView(store: store, size: 72)
                    if !store.displayName.isEmpty {
                        Text(store.displayName).font(.title2.weight(.semibold))
                    }
                    Text("Scan this code to message me")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                qrCodeView

                VStack(spacing: 6) {
                    Picker("QR format", selection: $showsLegacyQR) {
                        Text("Standard").tag(false)
                        Text("Legacy").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                    Text(showsLegacyQR
                         ? "Address only, for older ReTiCAMsgr versions."
                         : "Works with MeshChatX, Columba, Retichat and current ReTiCAMsgr.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Text(store.myAddressHex)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding()
                    #if os(iOS)
                    .background(Color(.systemGray6))
                    #else
                    .background(Color(nsColor: .controlBackgroundColor))
                    #endif
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                ShareLink(item: store.myAddressHex) {
                    Label("Share Address", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("My Code")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The QR's payload: `lxma://<address>:<public key>` (`ContactURI.encode`), or the bare address
    /// in legacy mode. Both derive from the identity set once at store init, so no TCA state.
    private var qrPayload: String {
        showsLegacyQR ? store.myAddressHex : ContactURI.encode(store.identity)
    }

    @ViewBuilder
    private var qrCodeView: some View {
        if let image = QRCodeImage.generate(from: qrPayload) {
            Image(platformImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .padding(16)
                // Explicit white backing keeps the code scannable in dark mode.
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
