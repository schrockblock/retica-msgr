//
//  AttachmentPicker.swift
//  ReTiCaMsgr
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os
import ReTiCaMsgrCore

/// The paperclip beside the text field: Photo Library (one image) or Document (one file). Reads
/// the picker's bytes here — `fileImporter` hands over a security-scoped URL only the view can
/// open — and hands a `PickedItem` to the store, which prepares it off the main thread.
struct AttachmentPickerButton: View {
    let onPicked: (PickedItem) -> Void
    let onFailed: (String) -> Void

    private static let log = Logger(subsystem: "com.reticamsgr", category: "attachments")

    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showingPhotos = true }
            Button("Document", systemImage: "doc") { showingFiles = true }
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
                // UI rule: a 44 pt hit area, all of it tappable.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        Self.log.error("photo pick: loadTransferable returned no data")
                        onFailed("Couldn't read that photo")
                        return
                    }
                    onPicked(PickedItem(kind: AttachmentKind.image, name: "", data: data))
                } catch {
                    Self.log.error("photo pick failed: \(String(describing: error), privacy: .public)")
                    onFailed("Couldn't read that photo")
                }
            }
        }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item]) { result in
            switch result {
            case let .success(url):
                // The read happens off the main thread (a document can be large); the Task inherits
                // the view's main-actor isolation, so `onPicked` / `onFailed` run back on it.
                Task {
                    let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return Result { try Data(contentsOf: url) }
                    }.value
                    switch read {
                    case let .success(data):
                        onPicked(PickedItem(kind: AttachmentKind.file, name: url.lastPathComponent, data: data))
                    case let .failure(error):
                        Self.log.error("file import read failed: \(String(describing: error), privacy: .public)")
                        onFailed("Couldn't read that file")
                    }
                }
            case let .failure(error):
                Self.log.error("file import failed: \(String(describing: error), privacy: .public)")
                onFailed("Couldn't read that file")
            }
        }
    }
}
