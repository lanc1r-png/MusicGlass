import SwiftUI

// MARK: - Экран исполнителя (как в Apple Music)

struct LocalArtistView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.playerControl) private var player
    let artist: Artist

    @State private var headerImage: UIImage?
    @State private var offset: CGFloat = 0
    @Namespace private var zoomNS

    private let headerHeight: CGFloat = 400

    private var albums: [Album] {
        library.albums.filter { $0.tracks.contains { $0.artist == artist.name } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 28) {
                    PlayShuffleButtons(tracks: artist.tracks)
                    songsSection
                    if !albums.isEmpty { albumsSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, value in
            offset = value
        }
        .navigationTitle(offset > headerHeight - 120 ? artist.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id) { await loadHeader() }
    }

    // Большая шапка: тянется вниз при оттягивании и уезжает с параллаксом при прокрутке.
    private var header: some View {
        let pull = max(0, -offset)
        let lift = max(0, offset)
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let headerImage {
                    Image(uiImage: headerImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [.pink.opacity(0.8), .purple.opacity(0.8)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .containerRelativeFrame(.horizontal)
            .frame(height: headerHeight + pull)
            .clipped()
            .offset(y: -pull + lift * 0.35)

            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                           startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom) {
                Text(artist.name)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.3), radius: 8)
                Spacer(minLength: 12)
                Button {
                    Haptics.tap()
                    player?.play(artist.tracks, startAt: 0)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .glassEffect(.regular.tint(.pink.opacity(0.6)).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .opacity(1 - min(lift / 220, 1))
        }
        .frame(height: headerHeight)
        .clipped()
    }

    private var songsSection: some View {
        let top = Array(artist.tracks.prefix(5))
        return VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                SongsView(title: artist.name, tracks: artist.tracks)
            } label: {
                sectionTitle("Песни")
            }
            .buttonStyle(.plain)

            ForEach(Array(top.enumerated()), id: \.element.id) { index, track in
                VStack(spacing: 0) {
                    TrackRow(track: track)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap()
                            player?.play(artist.tracks, startAt: index)
                        }
                        .padding(.vertical, 4)
                    if index < top.count - 1 {
                        Divider().padding(.leading, 64)
                    }
                }
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Альбомы")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                                .zoomDestination(album.id, in: zoomNS)
                        } label: {
                            AlbumCard(album: album, zoomNS: zoomNS)
                                .frame(width: 160)
                        }
                        .buttonStyle(CardPressStyle())
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.title2.weight(.bold))
            Image(systemName: "chevron.right")
                .font(.headline.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    /// Шапка: самая крупная обложка среди песен исполнителя.
    private func loadHeader() async {
        for t in artist.tracks.prefix(8) {
            guard let url = library.url(for: t) else { continue }
            if let img = await ArtworkLoader.shared.image(for: t, url: url, maxSize: 1000) {
                withAnimation(.easeOut(duration: 0.3)) { headerImage = img }
                return
            }
        }
    }
}
