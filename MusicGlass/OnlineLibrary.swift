import SwiftUI

// MARK: - Плейлист

struct OnlinePlaylist: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var tracks: [OnlineTrack]
}

// MARK: - Хранилище онлайн-избранного и плейлистов

@MainActor
final class OnlineLibrary: ObservableObject {
    static let shared = OnlineLibrary()

    @Published private(set) var favorites: [OnlineTrack] = []
    @Published private(set) var playlists: [OnlinePlaylist] = []

    private struct Saved: Codable {
        var favorites: [OnlineTrack]
        var playlists: [OnlinePlaylist]
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("online.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            favorites = saved.favorites
            playlists = saved.playlists
        }
        OnlineCatalog.shared.register(favorites + playlists.flatMap { $0.tracks })
    }

    private func save() {
        let saved = Saved(favorites: favorites, playlists: playlists)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // Избранное

    func isFavorite(_ id: String) -> Bool {
        favorites.contains { $0.id == id }
    }

    func toggleFavorite(_ track: OnlineTrack) {
        if let i = favorites.firstIndex(where: { $0.id == track.id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(track, at: 0)
            OnlineCatalog.shared.register([track])
        }
        save()
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    // Плейлисты

    @discardableResult
    func createPlaylist(name: String) -> String {
        let p = OnlinePlaylist(id: UUID().uuidString, name: name, tracks: [])
        playlists.append(p)
        save()
        return p.id
    }

    func deletePlaylists(at offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
        save()
    }

    func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = n
        save()
    }

    func add(_ track: OnlineTrack, to playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[i].tracks.contains(where: { $0.id == track.id }) {
            playlists[i].tracks.append(track)
            OnlineCatalog.shared.register([track])
            save()
        }
    }

    func removeTracks(at offsets: IndexSet, from playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
        save()
    }

    func moveTracks(from source: IndexSet, to destination: Int, in playlistID: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
        save()
    }
}

// MARK: - Сердечко на экране «Сейчас играет»

struct OnlineFavoriteButton: View {
    @ObservedObject private var lib = OnlineLibrary.shared
    let track: Track

    var body: some View {
        let info = OnlineCatalog.shared.info(for: track)
        let isFav = info.map { lib.isFavorite($0.id) } ?? false
        Button {
            if let info { lib.toggleFavorite(info) }
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isFav ? Color.pink : Color.primary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Избранное (онлайн)

struct OnlineFavoritesView: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject private var lib = OnlineLibrary.shared

    var body: some View {
        let tracks = lib.favorites
        List {
            if !tracks.isEmpty {
                OnlinePlayButtons(tracks: tracks)
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    OnlineTrackRow(track: track)
                        .onTapGesture {
                            playOnline(tracks, at: index, player: player)
                        }
                }
                .onDelete { lib.removeFavorites(at: $0) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Избранное")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Пока нет избранного",
                                       systemImage: "heart",
                                       description: Text("Нажмите ⋯ у онлайн-трека и выберите «В избранное»."))
            }
        }
    }
}

// MARK: - Плейлисты (онлайн)

struct OnlinePlaylistsView: View {
    @ObservedObject private var lib = OnlineLibrary.shared
    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(lib.playlists) { p in
                NavigationLink {
                    OnlinePlaylistDetailView(playlistID: p.id)
                } label: {
                    HStack(spacing: 12) {
                        OnlineCover(urlString: p.tracks.first?.artworkSmall, corner: 8)
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).lineLimit(1)
                            Text("\(p.tracks.count) треков")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { lib.deletePlaylists(at: $0) }
        }
        .listStyle(.plain)
        .navigationTitle("Плейлисты")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if lib.playlists.isEmpty {
                ContentUnavailableView("Нет плейлистов",
                                       systemImage: "music.note.list",
                                       description: Text("Нажмите «+», чтобы создать первый."))
            }
        }
        .alert("Новый плейлист", isPresented: $showNew) {
            TextField("Название", text: $newName)
            Button("Создать") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                newName = ""
                if !n.isEmpty { lib.createPlaylist(name: n) }
            }
            Button("Отмена", role: .cancel) { newName = "" }
        }
    }
}

struct OnlinePlaylistDetailView: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject private var lib = OnlineLibrary.shared
    let playlistID: String
    @State private var showRename = false
    @State private var nameDraft = ""

    private var playlist: OnlinePlaylist? {
        lib.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        let tracks = playlist?.tracks ?? []
        List {
            if !tracks.isEmpty {
                OnlinePlayButtons(tracks: tracks)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                OnlineTrackRow(track: track)
                    .onTapGesture {
                        playOnline(tracks, at: index, player: player)
                    }
            }
            .onDelete { lib.removeTracks(at: $0, from: playlistID) }
            .onMove { lib.moveTracks(from: $0, to: $1, in: playlistID) }
        }
        .listStyle(.plain)
        .navigationTitle(playlist?.name ?? "Плейлист")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Menu {
                    Button {
                        nameDraft = playlist?.name ?? ""
                        showRename = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("Плейлист пуст",
                                       systemImage: "music.note.list",
                                       description: Text("Добавляйте треки через меню ⋯ во вкладке «Онлайн»."))
            }
        }
        .alert("Переименовать", isPresented: $showRename) {
            TextField("Название", text: $nameDraft)
            Button("Готово") { lib.rename(playlistID, to: nameDraft) }
            Button("Отмена", role: .cancel) {}
        }
    }
}
