//
//  AttachmentViews.swift
//  ReTiCaMsgr
//

import SwiftUI
import UIKit
import ImageIO
import ReTiCaMsgrCore

// MARK: - Thumbnails

/// Decodes images at a capped pixel size off the main thread and keeps them in memory. Keyed by
/// attachment id (or the pending attachment's name, size and preset) plus the size, so a
/// thumbnail and the viewer's larger decode of the same file do not collide.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    func image(for url: URL, key: String, maxPixels: Int) async -> UIImage? {
        await image(key: key, maxPixels: maxPixels) { CGImageSourceCreateWithURL(url as CFURL, nil) }
    }

    func image(for data: Data, key: String, maxPixels: Int) async -> UIImage? {
        await image(key: key, maxPixels: maxPixels) { CGImageSourceCreateWithData(data as CFData, nil) }
    }

    /// The one decode path: cache lookup, then the source is opened and decoded off the main thread.
    private func image(key: String, maxPixels: Int,
                       source: @escaping @Sendable () -> CGImageSource?) async -> UIImage? {
        let cacheKey = "\(key)/\(maxPixels)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = source() else { return nil }
            return Self.decode(src, maxPixels: maxPixels)
        }.value
        if let decoded { cache.setObject(decoded, forKey: cacheKey) }
        return decoded
    }

    nonisolated private static func decode(_ source: CGImageSource, maxPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// An attachment's thumbnail, sized from the stored dimensions so the bubble does not jump when
/// the decode lands. `url == nil` means the bytes were never written; a missing file means they
/// were removed since.
struct AttachmentThumbnail: View {
    static let maxWidth: CGFloat = 240
    static let maxHeight: CGFloat = 320
    static let decodePixels = 640

    let attachment: Attachment
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    private var displaySize: CGSize {
        let w = CGFloat(attachment.width ?? 4), h = CGFloat(attachment.height ?? 3)
        let scale = min(Self.maxWidth / w, Self.maxHeight / h, 1)
        return CGSize(width: max(w * scale, 80), height: max(h * scale, 60))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
                if url == nil {
                    Label("Attachment could not be saved", systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(8)
                } else if failed {
                    Label("Attachment unavailable", systemImage: "photo")
                        .font(.caption).padding(8)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: attachment.id) {
            guard let url else { return }
            let decoded = await ThumbnailCache.shared.image(for: url, key: attachment.id.uuidString, maxPixels: Self.decodePixels)
            image = decoded
            failed = decoded == nil
        }
        .accessibilityLabel(attachment.isImage ? "Photo" : attachment.name)
    }
}

// MARK: - Bubble slot

/// What sits above the caption in a bubble: the thumbnail or the file row, then the progress bar
/// while the message is still sending.
struct AttachmentBubbleSlot: View {
    let attachment: Attachment
    let url: URL?
    let progress: Double?
    let onOutgoingBubble: Bool
    var onTapImage: (() -> Void)? = nil
    var onTapFile: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if attachment.isImage {
                Button { onTapImage?() } label: {
                    AttachmentThumbnail(attachment: attachment, url: url)
                }
                .buttonStyle(.plain)
                .disabled(onTapImage == nil || url == nil)
            } else {
                FileAttachmentRow(attachment: attachment, url: url, onOutgoingBubble: onOutgoingBubble,
                                  onTap: onTapFile)
            }
            if let progress {
                TransferProgressBar(fraction: progress, onOutgoingBubble: onOutgoingBubble)
            }
        }
    }
}

/// A file attachment: icon, name, and size — or why it cannot be opened. `url == nil` means the
/// bytes were never written ("could not be saved"); a URL whose file is gone from disk means they
/// were removed since ("unavailable"). Either way the row is not tappable.
struct FileAttachmentRow: View {
    let attachment: Attachment
    let url: URL?
    let onOutgoingBubble: Bool
    var onTap: (() -> Void)? = nil
    @State private var missing = false

    private var status: String {
        if url == nil { return "Attachment could not be saved" }
        if missing { return "Attachment unavailable" }
        return AttachmentSizeNote.formattedSize(attachment.size)
    }

    var body: some View {
        Button { onTap?() } label: {
            HStack(spacing: 10) {
                Image(systemName: (url == nil || missing) ? "doc.badge.ellipsis" : "doc.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(status)
                        .font(.caption)
                        .opacity(0.8)
                }
            }
            .padding(8)
            // UI rule: the whole row is the tap target.
            .frame(minWidth: 160, maxWidth: AttachmentThumbnail.maxWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(onOutgoingBubble ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil || url == nil || missing)
        .accessibilityElement(children: .combine)
        .task(id: attachment.id) {
            guard let url else { return }
            let path = url.path
            missing = await Task.detached { !FileManager.default.fileExists(atPath: path) }.value
        }
    }
}

/// Thin bar under an attachment while its message is sending: indeterminate until the transfer
/// has started (ReTiCA reports 0.05 for "link active", 0.10 at transfer start), then the fraction.
struct TransferProgressBar: View {
    let fraction: Double
    let onOutgoingBubble: Bool

    var body: some View {
        Group {
            if fraction < 0.10 {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            }
        }
        .tint(onOutgoingBubble ? .white : .accentColor)
        .frame(maxWidth: AttachmentThumbnail.maxWidth)
        .accessibilityLabel(fraction < 0.10 ? "Waiting for link" : "Sending \(Int(fraction * 100)) percent")
    }
}

// MARK: - Inbound capsule

/// "Receiving… 43%" for transfers on their way in. Shows the lowest fraction when several run.
struct ReceivingCapsule: View {
    let transfers: [AppFeature.InboundTransfer]

    var body: some View {
        if !transfers.isEmpty {
            let lowest = transfers.map(\.fraction).min() ?? 0
            let label = transfers.count == 1
                ? "Receiving… \(Int(lowest * 100))%"
                : "Receiving \(transfers.count)… \(Int(lowest * 100))%"
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(label)
        }
    }
}

// MARK: - Composer bar

/// The pending attachment above the text field: preview, name · size, size note, Original toggle
/// for a photo, and × to remove. Also shows the preparing spinner and the last error.
struct AttachmentComposerBar: View {
    let pending: PendingAttachment?
    let preparing: Bool
    let error: String?
    let onRemove: () -> Void
    let onOriginalToggled: (Bool) -> Void

    @State private var preview: UIImage?

    /// The pending preview's cache key: name, size and preset identify one encode (a toggle
    /// changes the preset, a new pick the name or size). `Data.hashValue` would hash only the
    /// first 80 bytes, which two JPEGs with the same headers share.
    private var previewKey: String? {
        pending.map { "pending-\($0.name)-\($0.size)-\($0.isOriginal)" }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            previewView
            VStack(alignment: .leading, spacing: 2) {
                if let pending {
                    Text(pending.name).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(AttachmentSizeNote.formattedSize(pending.size)).font(.caption).foregroundStyle(.secondary)
                    if let note = AttachmentSizeNote.note(for: pending.size) {
                        Text(note).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                    if pending.isImage, pending.originalSource != nil {
                        Toggle("Original", isOn: Binding(get: { pending.isOriginal }, set: onOriginalToggled))
                            .font(.caption)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(preparing)
                    }
                } else if preparing {
                    Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .task(id: previewKey) {
            preview = nil
            guard let pending, pending.isImage, let previewKey else { return }
            preview = await ThumbnailCache.shared.image(for: pending.data, key: previewKey, maxPixels: 160)
        }
    }

    @ViewBuilder
    private var previewView: some View {
        if preparing {
            ProgressView().frame(width: 48, height: 48)
        } else if let preview {
            Image(uiImage: preview).resizable().scaledToFill()
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if pending != nil {
            Image(systemName: "doc.fill").font(.title).frame(width: 48, height: 48)
        } else {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red).frame(width: 48, height: 48)
        }
    }
}

// MARK: - Viewer

/// Full-screen photo: pinch to zoom, share, done, or swipe down (at zoom 1) to dismiss. Decodes at
/// most 2048 px on the long edge. `shareURL` is the copy under the attachment's real name
/// (`AttachmentStore.exportURL`), or the stored file if that copy failed.
struct ImageViewerSheet: View {
    static let dismissDragDistance: CGFloat = 120

    let attachment: Attachment
    let url: URL
    let shareURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: UIScreen.main.bounds.width * zoom)
                    }
                    .offset(y: dragOffset)
                    .gesture(MagnifyGesture()
                        .onChanged { value in zoom = min(max(lastZoom * value.magnification, 1), 5) }
                        .onEnded { _ in lastZoom = zoom })
                    // Spec §4: swipe down to dismiss — only at zoom 1, where a drag is not a pan.
                    .simultaneousGesture(DragGesture()
                        .onChanged { value in
                            guard zoom == 1 else { return }
                            dragOffset = max(value.translation.height, 0)
                        }
                        .onEnded { value in
                            guard zoom == 1 else { return }
                            if value.translation.height > Self.dismissDragDistance {
                                dismiss()
                            } else {
                                withAnimation(.spring) { dragOffset = 0 }
                            }
                        })
                } else {
                    ProgressView().tint(.white)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: shareURL, preview: SharePreview(attachment.name))
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task(id: attachment.id) {
            image = await ThumbnailCache.shared.image(for: url, key: attachment.id.uuidString, maxPixels: 2048)
        }
    }
}
