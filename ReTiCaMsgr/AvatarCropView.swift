//
//  AvatarCropView.swift
//  ReTiCaMsgr
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Frames a picked photo for the profile picture: a square viewport with a circle guide, drag to
/// move and pinch to zoom. "Choose" renders exactly the visible square to a JPEG; the core encoder
/// then scales it to the 256 px avatar.
struct AvatarCropView: View {
    let image: PlatformImage
    let onChoose: (Data) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxScale: CGFloat = 5

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) - 32
                VStack {
                    Spacer()
                    viewport(side: side)
                        .frame(width: side, height: side)
                        .frame(maxWidth: .infinity)
                    Spacer()
                    Text("Drag and pinch to frame your photo.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Choose") {
                            if let data = render(side: side) { onChoose(data) }
                        }
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Move and Scale")
            .inlineNavigationTitle()
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// The image's size in viewport points at zoom 1: the shorter side fills the square.
    private func fillSize(side: CGFloat) -> CGSize {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let fill = side / min(w, h)
        return CGSize(width: w * fill, height: h * fill)
    }

    /// Keeps the image covering the whole square: the offset can move an edge at most to the
    /// viewport's edge.
    private func clamped(_ proposed: CGSize, scale: CGFloat, side: CGFloat) -> CGSize {
        let size = fillSize(side: side)
        let maxX = max(0, (size.width * scale - side) / 2)
        let maxY = max(0, (size.height * scale - side) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }

    private func viewport(side: CGFloat) -> some View {
        let size = fillSize(side: side)
        let drag = DragGesture()
            .onChanged { value in
                offset = clamped(CGSize(width: committedOffset.width + value.translation.width,
                                        height: committedOffset.height + value.translation.height),
                                 scale: scale, side: side)
            }
            .onEnded { _ in committedOffset = offset }
        let pinch = MagnifyGesture()
            .onChanged { value in
                scale = min(max(committedScale * value.magnification, 1), Self.maxScale)
                offset = clamped(committedOffset, scale: scale, side: side)
            }
            .onEnded { _ in
                committedScale = scale
                committedOffset = offset
            }
        return ZStack {
            Image(platformImage: image)
                .resizable()
                .frame(width: size.width * scale, height: size.height * scale)
                .offset(offset)
            // The circle guide: what the avatar will show; the corners stay in the JPEG but dim.
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .mask {
                    Rectangle()
                        .overlay(Circle().blendMode(.destinationOut))
                        .compositingGroup()
                }
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .gesture(drag.simultaneously(with: pinch))
        .accessibilityElement()
        .accessibilityLabel("Photo framing")
    }

    /// The visible square, in the image's own (orientation-corrected) points, drawn to a JPEG.
    private func render(side: CGFloat) -> Data? {
        let displayed = fillSize(side: side)
        let k = (displayed.width * scale) / max(image.size.width, 1)   // points on screen per image point
        let cropSide = side / k
        let originX = (displayed.width * scale - side) / 2 - offset.width
        let originY = (displayed.height * scale - side) / 2 - offset.height
        let crop = CGRect(x: originX / k, y: originY / k, width: cropSide, height: cropSide)

        return Self.renderSquareJPEG(image, crop: crop, outputSide: 512)
    }

    /// Draws `crop` (image points, origin top-left) into an opaque `outputSide` square and encodes
    /// it as a JPEG.
    static func renderSquareJPEG(_ image: PlatformImage, crop: CGRect, outputSide: CGFloat) -> Data? {
        let ratio = outputSide / crop.width
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide), format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(x: -crop.minX * ratio, y: -crop.minY * ratio,
                                  width: image.size.width * ratio, height: image.size.height * ratio))
        }
        return rendered.jpegData(compressionQuality: 0.9)
        #else
        guard let cgImage = image.cgImage else { return nil }
        let side = Int(outputSide)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // CGContext is y-up; flip the vertical placement so the crop's origin is top-left as on iOS.
        // The rect spans the whole image, so any pixel density of `cgImage` maps onto it correctly.
        let height = image.size.height * ratio
        context.draw(cgImage, in: CGRect(x: -crop.minX * ratio, y: outputSide - height + crop.minY * ratio,
                                         width: image.size.width * ratio, height: height))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output).jpegData(compressionQuality: 0.9)
        #endif
    }
}

#if os(iOS)
/// The system camera with its own square move-and-scale step (`allowsEditing`); hands back the
/// edited image as a JPEG.
struct CameraPicker: UIViewControllerRepresentable {
    let onPicked: (Data) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let data = image?.jpegData(compressionQuality: 0.9) {
                parent.onPicked(data)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
#endif
