import SwiftUI

// MARK: - Действия над треком (одни и те же для «⋯» и долгого нажатия)

struct TrackActionButtons: View {
    @ObservedObject private var favorites = FavoritesStore.shared
    let track: Track
    @Binding var showEditor: Bool

    var body: some View {
        Button {
            favorites.toggle(track)
        } label: {
            Label(favorites.contains(track) ? "Убрать из избранного" : "В избранное",
                  systemImage: favorites.contains(track) ? "heart.slash" : "heart")
        }
        Button {
            showEditor = true
        } label: {
            Label("Найти данные и обложку", systemImage: "square.and.pencil")
        }
    }
}

// MARK: - Строка трека

struct TrackRow: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject private var favorites = FavoritesStore.shared
    let track: Track
    let isCurrent: Bool
    @State private var showEditor = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkView(track: track, corner: 8, maxPixels: 160)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if favorites.contains(track) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }

            Menu {
                TrackActionButtons(track: track, showEditor: $showEditor)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .contextMenu {
            TrackActionButtons(track: track, showEditor: $showEditor)
        }
        .sheet(isPresented: $showEditor) {
            TagEditorView(track: track)
        }
    }
}

// MARK: - Песни

struct SongsView: View {
    @EnvironmentObject var player: PlayerStore
    let title: String
    let tracks: [Track]

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView("Здесь пока пусто", systemImage: "music.note")
            } else {
                List {
                    PlayShuffleButtons(tracks: tracks)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, isCurrent: player.currentTrack?.id == track.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                player.play(tracks, startAt: index)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
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
                    ArtworkView(track: artist.tracks.first, corner: 26, maxPixels: 160)
                        .frame(width: 52, height: 52)
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
        .navigationBarTitleDisplayMode(.large)
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
                                .onTapGesture {
                                    Haptics.tap()
                                    player.play(list, startAt: index)
                                }
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
