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
    let ownAddress: String
    let onScanned: (String) -> Void

    @State private var errorCaption: String?
    @State private var startFailed = false

    private var scanningAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                if scanningAvailable && !startFailed {
                    scannerContent
                } else if startFailed {
                    unavailableContent(
                        message: "The camera couldn't start. Check ReTiCaMsgr's camera permission in Settings."
                    )
                } else {
                    unavailableContent(
                        message: "Scanning isn't available on this device. Ask for the address as text instead."
                    )
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
            DataScannerRepresentable(
                onPayload: handlePayload,
                onStartFailure: { startFailed = true }
            )
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

    private func unavailableContent(message: String) -> some View {
        VStack(spacing: 16) {
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Returns true when the payload parsed as someone else's LXMF address and
    /// scanning should stop. A payload that parses but matches this device's own
    /// address is treated like an unparseable one: keep scanning, show a caption.
    private func handlePayload(_ payload: String) -> Bool {
        guard let hex = ScannedAddress.parse(payload) else {
            errorCaption = "That code isn't an LXMF address."
            return false
        }
        guard hex != ownAddress.lowercased() else {
            errorCaption = "That's your own address."
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
    let onStartFailure: () -> Void

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
        do {
            try controller.startScanning()
        } catch {
            onStartFailure()
        }
    }

    /// Stops the capture session on every teardown path that isn't a successful
    /// scan (Cancel, swipe-to-dismiss, the parent sheet closing, etc.) — the
    /// success path already stops it explicitly in the delegate callback below.
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
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
