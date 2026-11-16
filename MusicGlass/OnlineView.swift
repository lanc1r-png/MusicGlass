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

struct OnlineTrackRow: View {
    @EnvironmentObject var player: PlayerStore
    let track: OnlineTrack

    var body: some View {
        let isCurrent = player.currentTrack?.id == track.playerID
        HStack(spacing: 12) {
            ZStack {
                OnlineCover(urlString: track.artworkSmall, corner: 8)
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
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(onlineTime(track.duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !track.artistHandle.isEmpty,
               let url = URL(string: "https://audius.co/\(track.artistHandle)") {
                Link(destination: url) {
                    Label("Открыть исполнителя на Audius", systemImage: "safari")
                }
            }
        }
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

struct OnlineView: View {
    @EnvironmentObject var player: PlayerStore
    @StateObject private var model = OnlineModel()
    @State private var query = ""
    @State private var scope: OnlineScope = .tracks

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    private var currentListEmpty: Bool {
        if !isSearching { return model.trending.isEmpty }
        return scope == .tracks ? model.tracks.isEmpty : model.artists.isEmpty
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
                } else if !model.trending.isEmpty {
                    Section {
                        trackRows(model.trending)
                    } header: {
                        Text("В тренде")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                            .textCase(nil)
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
            .overlay { stateOverlay }
            .alert("Не удалось воспроизвести",
                   isPresented: Binding(
                    get: { player.playbackError != nil },
                    set: { if !$0 { player.playbackError = nil } }
                   )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(player.playbackError ?? "")
            }
        }
    }

    @ViewBuilder
    private func trackRows(_ list: [OnlineTrack]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, track in
            OnlineTrackRow(track: track)
                .onTapGesture {
                    playOnline(list, at: index, player: player)
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

    @ViewBuilder
    private var stateOverlay: some View {
        if let e = model.errorText, currentListEmpty {
            ContentUnavailableView {
                Label("Не получилось загрузить", systemImage: "wifi.slash")
            } description: {
                Text(e)
            } actions: {
                Button("Повторить") {
                    if isSearching {
                        model.search(query)
                    } else {
                        Task { await model.loadTrending(force: true) }
                    }
                }
            }
        } else if model.isLoading && currentListEmpty {
            ProgressView()
        } else if isSearching && !model.isLoading && currentListEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}

// MARK: - Страница исполнителя

struct ArtistDetailView: View {
    @EnvironmentObject var player: PlayerStore
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
                HStack(spacing: 12) {
                    Button {
                        if player.shuffleOn { player.toggleShuffle() }
                        playOnline(tracks, at: 0, player: player)
                    } label: {
                        Label("Играть", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        OnlineCatalog.shared.register(tracks)
                        player.playShuffled(tracks.map { $0.asTrack })
                    } label: {
                        Label("Вперемешку", systemImage: "shuffle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(.pink)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    OnlineTrackRow(track: track)
                        .onTapGesture {
                            playOnline(tracks, at: index, player: player)
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
