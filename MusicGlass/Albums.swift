import SwiftUI

// MARK: - Кнопки «Играть» и «Вперемешку»

struct PlayShuffleButtons: View {
    @EnvironmentObject var player: PlayerStore
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                if player.shuffleOn { player.toggleShuffle() }
                player.play(tracks, startAt: 0)
            } label: {
                Label("Играть", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            Button {
                Haptics.tap()
                player.playShuffled(tracks)
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
    }
}

// MARK: - Карточка альбома

struct AlbumCard: View {
    @EnvironmentObject var player: PlayerStore
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.tracks.first, corner: 12, maxPixels: 500)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contextMenu {
            Button {
                player.play(album.tracks, startAt: 0)
            } label: {
                Label("Играть", systemImage: "play.fill")
            }
            Button {
                player.playShuffled(album.tracks)
            } label: {
                Label("Вперемешку", systemImage: "shuffle")
            }
            AddToCategoryMenu(tracks: album.tracks)
        }
    }
}

// MARK: - Все альбомы

struct AlbumsView: View {
    @EnvironmentObject var library: LibraryStore
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(library.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .navigationTitle("Альбомы")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Страница альбома

struct AlbumDetailView: View {
    @EnvironmentObject var player: PlayerStore
    @EnvironmentObject var library: LibraryStore
    let album: Album
    @State private var tint: Color = .clear

    private var totalMinutes: Int {
        Int(album.tracks.map { $0.duration }.reduce(0, +) / 60)
    }

    var body: some View {
        List {
            header
            PlayShuffleButtons(tracks: album.tracks)
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                AlbumTrackRow(index: index, track: track,
                              isCurrent: player.currentTrack?.id == track.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tap()
                        player.play(album.tracks, startAt: index)
                    }
            }
            Text("\(album.tracks.count) песен, \(totalMinutes) мин.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 440)
                .ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadTint() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            ArtworkView(track: album.tracks.first, corner: 18, maxPixels: 800)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
                .padding(.bottom, 10)
            Text(album.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(album.artist)
                .font(.title3)
                .foregroundStyle(.pink)
            Text("Альбом")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func loadTint() async {
        guard let t = album.tracks.first, let url = library.url(for: t) else { return }
        guard let img = await ArtworkLoader.shared.image(for: t, url: url, maxSize: 200) else { return }
        let colors = await Task.detached(priority: .userInitiated) {
            ArtPalette.colors(from: img, count: 1)
        }.value
        if let c = colors.first {
            withAnimation(.easeInOut(duration: 0.6)) {
                tint = Color(uiColor: c)
            }
        }
    }
}

struct AlbumTrackRow: View {
    @EnvironmentObject var player: PlayerStore
    let index: Int
    let track: Track
    let isCurrent: Bool
    @State private var showEditor = false

    private var durationText: String {
        let t = Int(max(track.duration, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: "waveform")
                        .foregroundStyle(.pink)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                } else {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.pink : Color.primary)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(durationText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
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
