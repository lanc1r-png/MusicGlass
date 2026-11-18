import SwiftUI

// MARK: - Вспомогательное

@MainActor
func playOnline(_ list: [OnlineTrack], at index: Int, player: PlayerStore) {
    guard list.indices.contains(index) else { return }
    OnlineCatalog.shared.register(list)
    player.play(list.map { $0.asTrack }, startAt: index)
}

private func onlineTime(_ s: Double) -> String {
    let t = Int(max(s, 0))
    return String(format: "%d:%02d", t / 60, t % 60)
}

struct OnlineCover: View {
    let urlString: String?
    var corner: CGFloat = 8

    var body: some View {
        Color.gray.opacity(0.22)
            .overlay {
                AsyncImage(url: urlString.flatMap { URL(string: $0) }) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Кнопки «Играть» и «Вперемешку»

struct OnlinePlayButtons: View {
    @Environment(\.playerControl) private var player
    let tracks: [OnlineTrack]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard let player else { return }
                if player.shuffleOn { player.toggleShuffle() }
                playOnline(tracks, at: 0, player: player)
            } label: {
                Label("Играть", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            // Главное действие залито акцентом, второе — прозрачное стекло, как в Apple Music.
            .buttonStyle(.glassProminent)
            Button {
                OnlineCatalog.shared.register(tracks)
                player?.playShuffled(tracks.map { $0.asTrack })
            } label: {
                Label("Вперемешку", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
        .tint(.pink)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Действия над онлайн-треком

struct OnlineTrackActions: View {
    @ObservedObject private var lib = OnlineLibrary.shared
    let track: OnlineTrack
    @Binding var showNewPlaylist: Bool

    var body: some View {
        Button {
            lib.toggleFavorite(track)
        } label: {
            Label(lib.isFavorite(track.id) ? "Убрать из избранного" : "В избранное",
                  systemImage: lib.isFavorite(track.id) ? "heart.slash" : "heart")
        }

        Menu {
            Button {
                showNewPlaylist = true
            } label: {
                Label("Новый плейлист…", systemImage: "plus")
            }
            if !lib.playlists.isEmpty {
                Divider()
                ForEach(lib.playlists) { p in
                    Button(p.name) {
                        lib.add(track, to: p.id)
                    }
                }
            }
        } label: {
            Label("Добавить в плейлист", systemImage: "text.badge.plus")
        }

        if !track.artistHandle.isEmpty,
           let url = URL(string: "https://audius.co/\(track.artistHandle)") {
            Link(destination: url) {
                Label("Открыть исполнителя на Audius", systemImage: "safari")
            }
        }
    }
}

// MARK: - Строка онлайн-трека

struct OnlineTrackRow: View {
    @ObservedObject private var status = PlaybackStatus.shared
    @ObservedObject private var lib = OnlineLibrary.shared
    let track: OnlineTrack
    @State private var showNewPlaylist = false
    @State private var newName = ""

    var body: some View {
        let isCurrent = status.currentID == track.playerID
        HStack(spacing: 12) {
            ZStack {
                OnlineCover(urlString: track.artworkSmall, corner: 8)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: status.isPlaying)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if lib.isFavorite(track.id) {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)
            }
            Text(onlineTime(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                OnlineTrackActions(track: track, showNewPlaylist: $showNewPlaylist)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            OnlineTrackActions(track: track, showNewPlaylist: $showNewPlaylist)
        }
        .alert("Новый плейлист", isPresented: $showNewPlaylist) {
            TextField("Название", text: $newName)
            Button("Создать") { createAndAdd() }
            Button("Отмена", role: .cancel) { newName = "" }
        }
    }

    private func createAndAdd() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !n.isEmpty else { return }
        let id = lib.createPlaylist(name: n)
        lib.add(track, to: id)
    }
}

// MARK: - Модель поиска

@MainActor
final class OnlineModel: ObservableObject {
    @Published var trending: [OnlineTrack] = []
    @Published var tracks: [OnlineTrack] = []
    @Published var artists: [OnlineArtist] = []
    @Published var isLoading = false
    @Published var errorText: String?
    private var searchTask: Task<Void, Never>?

    func loadTrending(force: Bool = false) async {
        if !trending.isEmpty && !force { return }
        isLoading = true
        errorText = nil
        do {
            let list = try await AudiusAPI.trending()
            trending = list
        } catch {
            if !Task.isCancelled { errorText = error.localizedDescription }
        }
        isLoading = false
    }

    func search(_ raw: String) {
        searchTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        errorText = nil
        guard !q.isEmpty else {
            tracks = []
            artists = []
            isLoading = false
            return
        }
        isLoading = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            do {
                let t = try await AudiusAPI.searchTracks(q)
                let a = try await AudiusAPI.searchArtists(q)
                if Task.isCancelled { return }
                tracks = t
                artists = a
            } catch {
                if Task.isCancelled { return }
                tracks = []
                artists = []
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Вкладка «Онлайн»

enum OnlineScope: String, CaseIterable, Identifiable {
    case tracks = "Треки"
    case artists = "Исполнители"
    var id: String { rawValue }
}

private struct OnlineCategoryRow: View {
    let title: String
    let icon: String
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.pink)
                .frame(width: 30)
            Text(title)
                .font(.title3)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct OnlineView: View {
    @Environment(\.playerControl) private var player
    @ObservedObject private var lib = OnlineLibrary.shared
    @StateObject private var model = OnlineModel()
    @State private var query = ""
    @State private var scope: OnlineScope = .tracks

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var searchListEmpty: Bool {
        scope == .tracks ? model.tracks.isEmpty : model.artists.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    Picker("Раздел", selection: $scope) {
                        ForEach(OnlineScope.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    if scope == .tracks {
                        trackRows(model.tracks)
                    } else {
                        ForEach(model.artists) { artist in
                            NavigationLink {
                                ArtistDetailView(artist: artist)
                            } label: {
                                artistRow(artist)
                            }
                        }
                    }
                } else {
                    Section {
                        NavigationLink {
                            OnlineFavoritesView()
                        } label: {
                            OnlineCategoryRow(title: "Избранное", icon: "heart.fill",
                                              count: lib.favorites.count)
                        }
                        NavigationLink {
                            OnlinePlaylistsView()
                        } label: {
                            OnlineCategoryRow(title: "Плейлисты", icon: "music.note.list",
                                              count: lib.playlists.count)
                        }
                    }

                    if !model.trending.isEmpty {
                        Section {
                            trackRows(model.trending)
                        } header: {
                            Text("В тренде")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                                .textCase(nil)
                        }
                    } else if model.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Загружаю тренды…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let e = model.errorText {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(e, systemImage: "wifi.slash")
                                .foregroundStyle(.secondary)
                            Button("Повторить") {
                                Task { await model.loadTrending(force: true) }
                            }
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Музыка из каталога Audius. Права принадлежат исполнителям.")
                        if let url = URL(string: "https://audius.co") {
                            Link("audius.co", destination: url)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Онлайн")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, prompt: "Треки и исполнители")
            .onChange(of: query) { _, new in model.search(new) }
            .task { await model.loadTrending() }
            .overlay { searchOverlay }
            .playbackErrorAlert()
        }
    }

    @ViewBuilder
    private func trackRows(_ list: [OnlineTrack]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
            OnlineTrackRow(track: track)
                .onTapGesture {
                    if let player { playOnline(list, at: index, player: player) }
                }
        }
    }

    private func artistRow(_ artist: OnlineArtist) -> some View {
        HStack(spacing: 12) {
            OnlineCover(urlString: artist.avatar, corner: 26)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).lineLimit(1)
                Text("\(artist.trackCount) треков")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Состояния только для режима поиска. Главный экран показывает их прямо в списке,
    /// чтобы «Избранное» и «Плейлисты» были доступны даже без интернета.
    @ViewBuilder
    private var searchOverlay: some View {
        if isSearching {
            if let e = model.errorText, searchListEmpty {
                ContentUnavailableView {
                    Label("Не получилось загрузить", systemImage: "wifi.slash")
                } description: {
                    Text(e)
                } actions: {
                    Button("Повторить") { model.search(query) }
                }
            } else if model.isLoading && searchListEmpty {
                ProgressView()
            } else if !model.isLoading && searchListEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

// MARK: - Страница исполнителя

struct ArtistDetailView: View {
    @Environment(\.playerControl) private var player
    let artist: OnlineArtist
    @State private var tracks: [OnlineTrack] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        List {
            VStack(spacing: 8) {
                OnlineCover(urlString: artist.avatar, corner: 80)
                    .frame(width: 160, height: 160)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                Text(artist.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                if !artist.handle.isEmpty {
                    Text("@\(artist.handle)")
                        .font(.subheadline)
                        .foregroundStyle(.pink)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if !tracks.isEmpty {
                OnlinePlayButtons(tracks: tracks)

                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    OnlineTrackRow(track: track)
                        .onTapGesture {
                            if let player { playOnline(tracks, at: index, player: player) }
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading && tracks.isEmpty {
                ProgressView()
            } else if let e = errorText, tracks.isEmpty {
                ContentUnavailableView {
                    Label("Не получилось загрузить", systemImage: "wifi.slash")
                } description: {
                    Text(e)
                } actions: {
                    Button("Повторить") { Task { await load() } }
                }
            } else if !isLoading && tracks.isEmpty {
                ContentUnavailableView("Нет доступных треков", systemImage: "music.note")
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            tracks = try await AudiusAPI.tracks(ofArtist: artist.id)
        } catch {
            if !Task.isCancelled { errorText = error.localizedDescription }
        }
        isLoading = false
    }
}
