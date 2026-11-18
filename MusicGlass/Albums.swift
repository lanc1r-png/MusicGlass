import SwiftUI

// MARK: - Кнопки «Играть» и «Вперемешку»

struct PlayShuffleButtons: View {
    @Environment(\.playerControl) private var player
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                if player?.shuffleOn == true { player?.toggleShuffle() }
                player?.play(tracks, startAt: 0)
            } label: {
                Label("Играть", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            // Главное действие залито акцентом, второе — прозрачное стекло, как в Apple Music.
            .buttonStyle(.glassProminent)
            Button {
                Haptics.tap()
                player?.playShuffled(tracks)
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

// MARK: - Карточка альбома

struct AlbumCard: View {
    @EnvironmentObject var library: LibraryStore
    let album: Album
    var zoomNS: Namespace.ID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: album.tracks.first, corner: 12, maxPixels: 500)
                .zoomSource(album.id, in: zoomNS)
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
            AlbumMenuItems(tracks: album.tracks)
        } preview: {
            AlbumPreview(album: album)
                .environmentObject(library)
        }
    }
}

/// Общие пункты меню для альбома или набора песен.
struct AlbumMenuItems: View {
    @Environment(\.playerControl) private var player
    let tracks: [Track]

    var body: some View {
        Button {
            player?.play(tracks, startAt: 0)
        } label: {
            Label("Играть", systemImage: "play.fill")
        }
        Button {
            player?.playShuffled(tracks)
        } label: {
            Label("Вперемешку", systemImage: "shuffle")
        }
        Divider()
        Button {
            player?.playNext(tracks)
        } label: {
            Label("Играть следующим", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player?.addToQueue(tracks)
        } label: {
            Label("В конец очереди", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        AddToCategoryMenu(tracks: tracks)
    }
}

/// Превью при долгом нажатии: крупная обложка и первые песни, как в Apple Music.
struct AlbumPreview: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(track: album.tracks.first, corner: 14, maxPixels: 600)
                .frame(width: 288, height: 288)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(album.artist)
                    .font(.subheadline)
                    .foregroundStyle(.pink)
                    .lineLimit(1)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(album.tracks.prefix(5).enumerated()), id: \.element.id) { i, t in
                    HStack(spacing: 10) {
                        Text("\(i + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        Text(t.title)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                if album.tracks.count > 5 {
                    Text("и ещё \(album.tracks.count - 5)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Color(.systemBackground))
    }
}

// MARK: - Все альбомы

struct AlbumsView: View {
    @EnvironmentObject var library: LibraryStore
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    @Namespace private var zoomNS

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(library.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                            .zoomDestination(album.id, in: zoomNS)
                    } label: {
                        AlbumCard(album: album, zoomNS: zoomNS)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle("Альбомы")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Страница альбома

struct AlbumDetailView: View {
    @Environment(\.playerControl) private var player
    @EnvironmentObject var library: LibraryStore
    let album: Album
    @State private var tint: Color = .clear
    @State private var offset: CGFloat = 0

    private var totalMinutes: Int {
        Int(album.tracks.map { $0.duration }.reduce(0, +) / 60)
    }

    var body: some View {
        List {
            header
            PlayShuffleButtons(tracks: album.tracks)
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                AlbumTrackRow(index: index, track: track)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.tap()
                        player?.play(album.tracks, startAt: index)
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
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, value in
            offset = value
        }
        // Название появляется в стеклянной панели, когда обложка уехала наверх.
        .navigationTitle(offset > 300 ? album.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    AlbumMenuItems(tracks: album.tracks)
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { await loadTint() }
    }

    private var header: some View {
        let pull = max(0, -offset)
        let lift = max(0, offset)
        return VStack(spacing: 6) {
            ArtworkView(track: album.tracks.first, corner: 18, maxPixels: 800)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
                // Растягивается при оттягивании, уменьшается и уходит под панель при прокрутке.
                .scaleEffect(pull > 0 ? 1 + pull / 500 : max(0.78, 1 - lift / 900), anchor: .bottom)
                .offset(y: lift * 0.3)
                .opacity(1 - min(lift / 320, 0.9))
                .padding(.bottom, 10)
            Text(album.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(album.artist)
                .font(.title3)
                .foregroundStyle(.pink)
            Text("Альбом · \(album.tracks.count) песен")
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
    @ObservedObject private var status = PlaybackStatus.shared
    let index: Int
    let track: Track

    private var isCurrent: Bool { status.currentID == track.id }
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
                        .symbolEffect(.variableColor.iterative, isActive: status.isPlaying)
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
