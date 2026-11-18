import SwiftUI

// MARK: - Корень приложения

struct RootView: View {
    // Корень не подписан на весь плеер: таб-бар не перерисовывается от каждой мелочи.
    @Environment(\.playerControl) private var player
    @ObservedObject private var status = PlaybackStatus.shared
    @State private var showNowPlaying = false

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
        // Системный слот над таб-баром; пока ничего не играет, мини-плеера нет (iOS 26.1+).
        .modifier(MiniPlayerAccessory(enabled: status.currentID != nil) {
            if let player {
                MiniPlayer(player: player, showNowPlaying: $showNowPlaying)
            }
        })
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingScreen()
                .presentationDragIndicator(.visible)
        }
    }
}

/// Мини-плеер в слоте над таб-баром. На iOS 26.0 слот виден всегда, с 26.1 прячется без трека.
struct MiniPlayerAccessory<Accessory: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let accessory: () -> Accessory

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) { accessory() }
        } else {
            content.tabViewBottomAccessory { accessory() }
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

    var body: some View {
        ArtworkImage(image: image, corner: corner)
            .task(id: "\(track?.id ?? "")|\(library.artworkVersion)") {
                image = nil
                guard let track else { return }
                if OnlineID.isOnline(track) {
                    image = await OnlineArtwork.image(OnlineCatalog.shared.info(for: track)?.artworkMedium)
                    return
                }
                guard let url = library.url(for: track) else { return }
                image = await ArtworkLoader.shared.image(for: track, url: url, maxSize: maxPixels)
            }
    }
}
