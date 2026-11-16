import SwiftUI
import UniformTypeIdentifiers

// MARK: - Медиатека

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        NavigationStack {
            Group {
                if library.tracks.isEmpty {
                    if library.isScanning {
                        ProgressView("Сканирую музыку…")
                    } else {
                        ContentUnavailableView(
                            "Пока пусто",
                            systemImage: "folder.badge.plus",
                            description: Text("Добавьте папки с музыкой на вкладке «Папки».")
                        )
                    }
                } else {
                    List {
                        NavigationLink {
                            SongsView(title: "Песни", tracks: library.tracks)
                        } label: {
                            Label("Песни", systemImage: "music.note")
                        }
                        NavigationLink {
                            AlbumsView()
                        } label: {
                            Label("Альбомы", systemImage: "square.stack")
                        }
                        NavigationLink {
                            ArtistsView()
                        } label: {
                            Label("Исполнители", systemImage: "music.mic")
                        }
                    }
                }
            }
            .navigationTitle("Медиатека")
        }
    }
}

// MARK: - Песни

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    @State private var showEditor = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track, corner: 6, maxPixels: 150)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "waveform").foregroundStyle(.pink)
            }
            Menu {
                Button {
                    showEditor = true
                } label: {
                    Label("Найти данные и обложку", systemImage: "square.and.pencil")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .sheet(isPresented: $showEditor) {
            TagEditorView(track: track)
        }
    }
}

struct PlayShuffleButtons: View {
    @EnvironmentObject var player: PlayerStore
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(tracks, startAt: 0)
            } label: {
                Label("Играть", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button {
                player.playShuffled(tracks)
            } label: {
                Label("Вперемешку", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

struct SongsView: View {
    @EnvironmentObject var player: PlayerStore
    let title: String
    let tracks: [Track]

    var body: some View {
        List {
            if !tracks.isEmpty {
                PlayShuffleButtons(tracks: tracks)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id)
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(tracks, startAt: index) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Альбомы

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.tracks.first, corner: 12, maxPixels: 500)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct AlbumsView: View {
    @EnvironmentObject var library: LibraryStore
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(library.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle("Альбомы")
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject var player: PlayerStore
    let album: Album

    var body: some View {
        List {
            VStack(spacing: 8) {
                ArtworkView(track: album.tracks.first, corner: 16, maxPixels: 800)
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                Text(album.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(album.artist)
                    .foregroundStyle(.pink)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            PlayShuffleButtons(tracks: album.tracks)

            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .lineLimit(1)
                            .foregroundStyle(player.currentTrack?.id == track.id ? Color.pink : Color.primary)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { player.play(album.tracks, startAt: index) }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Исполнители

struct ArtistsView: View {
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        List(library.artists) { artist in
            NavigationLink {
                SongsView(title: artist.name, tracks: artist.tracks)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(track: artist.tracks.first, corner: 24, maxPixels: 150)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).lineLimit(1)
                        Text("\(artist.tracks.count) песен")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Исполнители")
    }
}

// MARK: - Поиск

struct SearchView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: PlayerStore
    @State private var query = ""

    private var results: [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let found = library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
        return Array(found.prefix(300))
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Поиск по медиатеке",
                                           systemImage: "magnifyingglass",
                                           description: Text("Песни, альбомы и исполнители"))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    let list = results
                    List {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id)
                                .contentShape(Rectangle())
                                .onTapGesture { player.play(list, startAt: index) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Песни, альбомы, исполнители")
        }
    }
}

// MARK: - Папки

struct FoldersView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                    }
                    .onDelete { offsets in
                        let items = offsets.map { library.folders[$0] }
                        for item in items { library.removeFolder(item) }
                    }
                    Button {
                        showPicker = true
                    } label: {
                        Label("Добавить папку", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Папки с музыкой")
                } footer: {
                    Text("Выберите папки в приложении «Файлы». Музыка читается прямо из них, копировать ничего не нужно. Свайп влево удаляет папку из списка (сами файлы не трогаются).")
                }

                Section {
                    HStack {
                        Text("Треков в медиатеке")
                        Spacer()
                        Text("\(library.tracks.count)").foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        if library.isScanning {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Сканирую…")
                            }
                        } else {
                            Label("Обновить медиатеку", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(library.isScanning)
                }
            }
            .navigationTitle("Папки")
            .sheet(isPresented: $showPicker) {
                FolderPicker(
                    onPick: { urls in
                        library.addFolders(urls)
                        showPicker = false
                    },
                    onCancel: { showPicker = false }
                )
                .ignoresSafeArea()
            }
        }
    }
}
