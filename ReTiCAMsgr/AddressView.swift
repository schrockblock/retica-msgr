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

    /// QR encoding of the LXMF address, a pure derivation of `store.myAddressHex`
    /// (set once at store init), so no extra TCA state is needed.
    @ViewBuilder
    private var qrCodeView: some View {
        if let image = QRCodeImage.generate(from: store.myAddressHex) {
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
