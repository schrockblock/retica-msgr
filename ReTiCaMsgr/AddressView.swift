//
//  AddressView.swift
//  ReTiCaMsgr
//
//  Created by Elliot Schrock on 8/1/26.
//

import SwiftUI
import ComposableArchitecture
import ReTiCaMsgrCore

struct AddressView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("My LXMF Address")
                    .font(.headline)

                qrCodeView

                Text(store.myAddressHex)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)

                ShareLink(item: store.myAddressHex) {
                    Label("Share Address", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Address")
        }
    }

    /// QR encoding of the LXMF address, a pure derivation of `store.myAddressHex`
    /// (set once at store init), so no extra TCA state is needed.
    @ViewBuilder
    private var qrCodeView: some View {
        if let image = QRCodeImage.generate(from: store.myAddressHex) {
            Image(uiImage: image)
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
