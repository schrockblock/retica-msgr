//
//  QRScannerView.swift
//  ReTiCaMsgr
//

import SwiftUI
import VisionKit
import Vision
import ReTiCaMsgrCore

/// Presents VisionKit's live barcode scanner and reports the first recognized
/// QR payload that parses as an LXMF address. Falls back to a plain "not
/// available" screen when the simulator (no camera) or a permission denial
/// makes scanning impossible.
struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    @State private var errorCaption: String?

    private var scanningAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanningAvailable {
                    scannerContent
                } else {
                    unavailableContent
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var scannerContent: some View {
        ZStack(alignment: .bottom) {
            DataScannerRepresentable(onPayload: handlePayload)
                .ignoresSafeArea(edges: .bottom)

            if let errorCaption {
                Text(errorCaption)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 24)
            }
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: 16) {
            Text("Scanning isn't available on this device. Ask for the address as text instead.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Returns true when the payload parsed as an LXMF address and scanning should stop.
    private func handlePayload(_ payload: String) -> Bool {
        guard let hex = ScannedAddress.parse(payload) else {
            errorCaption = "That code isn't an LXMF address."
            return false
        }
        errorCaption = nil
        onScanned(hex)
        return true
    }
}

/// Thin UIViewControllerRepresentable wrapper around VisionKit's live QR scanner.
private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !context.coordinator.hasStopped, !controller.isScanning else { return }
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Bool
        private(set) var hasStopped = false

        init(onPayload: @escaping (String) -> Bool) {
            self.onPayload = onPayload
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasStopped else { return }
            for case let .barcode(barcode) in addedItems {
                guard let payload = barcode.payloadStringValue else { continue }
                if onPayload(payload) {
                    hasStopped = true
                    dataScanner.stopScanning()
                }
                break
            }
        }
    }
}
