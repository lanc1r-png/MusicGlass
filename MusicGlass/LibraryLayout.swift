import SwiftUI

// MARK: - Категория медиатеки (встроенная или своя)

struct LibraryCategory: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String
    var colorName: String
    var isCustom: Bool
    var hidden: Bool
    var trackIDs: [String]
}

enum CategoryPalette {
    static let colorNames = ["pink", "red", "orange", "yellow", "green",
                             "teal", "blue", "indigo", "purple", "gray"]

    static let icons = [
        "heart.fill", "star.fill", "flame.fill", "sparkles", "moon.stars.fill", "sun.max.fill",
        "bolt.fill", "leaf.fill", "car.fill", "figure.run", "headphones", "guitars.fill",
        "pianokeys", "music.mic", "gamecontroller.fill", "cup.and.saucer.fill", "bed.double.fill", "airplane"
    ]

    static func color(_ name: String) -> Color {
        switch name {
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "gray": return .gray
        default: return .primary
        }
    }
}

// MARK: - Порядок и состав категорий

@MainActor
final class LibraryLayout: ObservableObject {
    static let shared = LibraryLayout()
    @Published private(set) var items: [LibraryCategory] = []

    static let builtins: [LibraryCategory] = [
        LibraryCategory(id: "favorites", title: "Избранное", icon: "heart",
                        colorName: "primary", isCustom: false, hidden: false, trackIDs: []),
        LibraryCategory(id: "artists", title: "Исполнители", icon: "music.mic",
                        colorName: "primary", isCustom: false, hidden: false, trackIDs: []),
        LibraryCategory(id: "albums", title: "Альбомы", icon: "square.stack",
                        colorName: "primary", isCustom: false, hidden: false, trackIDs: []),
        LibraryCategory(id: "songs", title: "Песни", icon: "music.note",
                        colorName: "primary", isCustom: false, hidden: false, trackIDs: [])
    ]

    var custom: [LibraryCategory] { items.filter { $0.isCustom } }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library_layout.json")
    }

    private init() {
        var loaded: [LibraryCategory] = []
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([LibraryCategory].self, from: data) {
            loaded = list
        }
        var result: [LibraryCategory] = []
        for item in loaded {
            if item.isCustom {
                result.append(item)
            } else if var b = Self.builtins.first(where: { $0.id == item.id }) {
                b.hidden = item.hidden
                result.append(b)
            }
        }
        for b in Self.builtins where !result.contains(where: { $0.id == b.id }) {
            result.append(b)
        }
        items = result
    }

    func category(_ id: String) -> LibraryCategory? {
        items.first { $0.id == id }
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        save()
    }

    func toggleHidden(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].hidden.toggle()
        Haptics.tap()
        save()
    }

    func create(title: String, icon: String, colorName: String) {
        let c = LibraryCategory(id: "custom-" + UUID().uuidString, title: title, icon: icon,
                                colorName: colorName, isCustom: true, hidden: false, trackIDs: [])
        items.append(c)
        Haptics.tap()
        save()
    }

    func update(_ id: String, title: String, icon: String, colorName: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        items[i].icon = icon
        items[i].colorName = colorName
        save()
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id && $0.isCustom }
        save()
    }

    func containsAll(_ trackIDs: [String], in id: String) -> Bool {
        guard let c = category(id), !trackIDs.isEmpty else { return false }
        let set = Set(c.trackIDs)
        return trackIDs.allSatisfy { set.contains($0) }
    }

    /// Добавляет песни в категорию, а если они все уже там, убирает.
    func toggle(_ trackIDs: [String], in id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if containsAll(trackIDs, in: id) {
            let set = Set(trackIDs)
            items[i].trackIDs.removeAll { set.contains($0) }
        } else {
            for t in trackIDs where !items[i].trackIDs.contains(t) {
                items[i].trackIDs.append(t)
            }
        }
        Haptics.tap()
        save()
    }

    func remove(_ trackIDs: [String], from id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let set = Set(trackIDs)
        items[i].trackIDs.removeAll { set.contains($0) }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Пункт меню «Добавить в категорию»

struct AddToCategoryMenu: View {
    @ObservedObject private var layout = LibraryLayout.shared
    let tracks: [Track]

    var body: some View {
        let custom = layout.custom
        if !custom.isEmpty {
            Menu {
                ForEach(custom) { c in
                    let ids = tracks.map { $0.id }
                    Button {
                        layout.toggle(ids, in: c.id)
                    } label: {
                        Label(c.title, systemImage: layout.containsAll(ids, in: c.id) ? "checkmark" : c.icon)
                    }
                }
            } label: {
                Label("Добавить в категорию", systemImage: "text.badge.plus")
            }
        }
    }
}
