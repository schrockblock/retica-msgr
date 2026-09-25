import SwiftUI
import ReTiCaMsgrCore

/// Full emoji picker for reactions: grouped grid, searchable by name.
struct EmojiPickerSheet: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let catalog = EmojiCatalog.shared
    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 4)]

    var body: some View {
        let searchResults: [EmojiCatalog.Entry] = query.isEmpty ? [] : catalog.search(query)
        NavigationStack {
            Group {
                if !query.isEmpty && searchResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            if query.isEmpty {
                                ForEach(catalog.groups) { group in
                                    Section {
                                        cells(group.emojis)
                                    } header: {
                                        Text(group.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.top, 8)
                                    }
                                }
                            } else {
                                cells(searchResults)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func cells(_ entries: [EmojiCatalog.Entry]) -> some View {
        ForEach(entries) { entry in
            Button {
                onPick(entry.emoji)
                dismiss()
            } label: {
                Text(entry.emoji)
                    .font(.system(size: 32))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.name)
        }
    }
}

#Preview {
    EmojiPickerSheet { print("picked", $0) }
}
