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
}
