//
//  RadioPickerView.swift
//  ReTiCAMsgr
//

import SwiftUI
import ComposableArchitecture
import ReTiCAMsgrCore

/// The "Choose radio" sheet (spec 2026-10-16 §7). All behaviour is in `RadioPickerFeature`. This
/// file renders. Every way out (swipe, Cancel, a pick) reaches `AppFeature` as
/// `.radioPicker(.dismiss)`, where paused Bluetooth resumes.
struct RadioPickerView: View {
    let store: StoreOf<RadioPickerFeature>

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.radios) { radio in
                        Button {
                            store.send(.radioTapped(radio.id))
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(radio.displayName)
                                    Text(radio.id.uuidString)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(radio.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if radio.id == store.selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            // A `.plain` button hit-tests only its glyphs: make the whole row the target.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    statusFooter
                }
            }
            .navigationTitle("Choose Radio")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelTapped) }
                }
            }
            .onAppear { store.send(.onAppear) }
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if !store.scanEnded {
            HStack(spacing: 8) {
                ProgressView()
                Text(store.scanningMessage)
            }
        } else if store.radios.isEmpty {
            Text(store.scanEndedEmptyMessage)
                .foregroundStyle(.red)
        } else {
            Text("Scanning stopped.")
        }
    }
}

#Preview {
    // `\.radioScanner`'s previewValue lists three fake radios on an open scan.
    RadioPickerView(store: Store(initialState: RadioPickerFeature.State()) { RadioPickerFeature() })
}

#Preview("MeshCore") {
    RadioPickerView(store: Store(initialState: RadioPickerFeature.State(kind: .meshCore)) { RadioPickerFeature() })
}

#Preview("RNode") {
    RadioPickerView(store: Store(initialState: RadioPickerFeature.State(kind: .rnode)) { RadioPickerFeature() })
}
