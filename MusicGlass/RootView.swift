import SwiftUI

// MARK: - Корень приложения

struct RootView: View {
    // Корень не подписан на весь плеер: таб-бар не перерисовывается от каждой мелочи.
    @Environment(\.playerControl) private var player
    @State private var showNowPlaying = false
    @Namespace private var nowPlayingNS

    var body: some View {
        TabView {
            Tab("Медиатека", systemImage: "music.note.list") {
                LibraryView()
            }
            Tab("Онлайн", systemImage: "cloud") {
                OnlineView()
            }
            Tab("Радио", systemImage: "dot.radiowaves.left.and.right") {
                RadioView()
            }
            Tab("Поиск", systemImage: "magnifyingglass", role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Системный слот над таб-баром, мини-плеер виден всегда (в том числе «Не играет»).
        .tabViewBottomAccessory {
            if let player {
                MiniPlayer(player: player, showNowPlaying: $showNowPlaying, zoomNS: nowPlayingNS)
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            // Экран плеера вырастает из мини-плеера и сжимается обратно в него.
            NowPlayingScreen()
                .presentationDragIndicator(.visible)
                .zoomDestination("nowPlaying", in: nowPlayingNS)
        }
    }
}

// MARK: - Zoom-переходы

extension View {
    /// Откуда «вырастает» экран (обложка, мини-плеер, аватар).
    @ViewBuilder
    func zoomSource<ID: Hashable>(_ id: ID, in ns: Namespace.ID?) -> some View {
        if let ns {
            matchedTransitionSource(id: id, in: ns)
        } else {
            self
        }
    }

    /// Экран, который раскрывается из источника и сжимается обратно.
    @ViewBuilder
    func zoomDestination<ID: Hashable>(_ id: ID, in ns: Namespace.ID?) -> some View {
        if let ns {
            navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            self
        }
    }
}

// MARK: - Обложка

struct ArtworkImage: View {
    let image: UIImage?
    var corner: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [.pink.opacity(0.7), .purple.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Обложка трека: из тегов файла или (для онлайн-треков) из сети.
struct ArtworkView: View {
    @EnvironmentObject var library: LibraryStore
    let track: Track?
    var corner: CGFloat = 8
    var maxPixels: CGFloat = 200
    @State private var image: UIImage?
    @State private var shownTrackID: String?

    init(track: Track?, corner: CGFloat = 8, maxPixels: CGFloat = 200) {
        self.track = track
        self.corner = corner
        self.maxPixels = maxPixels
        // Если обложка уже в памяти, показываем её сразу, без кадра с заглушкой.
        let hit = track.flatMap { ArtworkLoader.shared.cached(for: $0, maxSize: maxPixels) }
        _image = State(initialValue: hit)
        _shownTrackID = State(initialValue: hit == nil ? nil : track?.id)
    }

    var body: some View {
        ArtworkImage(image: image, corner: corner)
            .task(id: "\(track?.id ?? "")|\(track.map { library.artworkRevision(for: $0.id) } ?? 0)") {
                guard let track else {
                    image = nil
                    return
                }
                if OnlineID.isOnline(track) {
                    if shownTrackID != track.id { image = nil }
                    image = await OnlineArtwork.image(OnlineCatalog.shared.info(for: track)?.artworkMedium)
                    shownTrackID = track.id
                    return
                }
                if let hit = ArtworkLoader.shared.cached(for: track, maxSize: maxPixels) {
                    image = hit
                    shownTrackID = track.id
                    return
                }
                // Заглушку показываем только если сменился сам трек.
                if shownTrackID != track.id { image = nil }
                guard let url = library.url(for: track) else { return }
                let img = await ArtworkLoader.shared.image(for: track, url: url, maxSize: maxPixels)
                if Task.isCancelled { return }
                image = img
                shownTrackID = track.id
            }
    }
}
