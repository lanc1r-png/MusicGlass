import SwiftUI
import AVKit

// MARK: - Корень приложения

struct RootView: View {
    @EnvironmentObject var player: PlayerStore
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            Tab("Медиатека", systemImage: "music.note.list") {
                LibraryView()
            }
                        Tab("Источники", systemImage: "folder") {
                SourcesView()
            }

            Tab("Поиск", systemImage: "magnifyingglass", role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayer(player: player, showNowPlaying: $showNowPlaying)
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .preferredColorScheme(.dark)
                .presentationDragIndicator(.visible)
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

/// Обложка трека, которая подгружается из тегов файла.
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
                guard let track, let url = library.url(for: track) else { return }
                image = await ArtworkLoader.shared.image(for: track, url: url, maxSize: maxPixels)
            }
    }
}

// MARK: - Мини-плеер

struct MiniPlayer: View {
    @ObservedObject var player: PlayerStore
    @Binding var showNowPlaying: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(image: player.artwork, corner: 8)
                .frame(width: 34, height: 34)

            Text(player.currentTrack?.title ?? "Не играет")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            if placement != .inline {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if player.currentTrack != nil { showNowPlaying = true }
        }
    }
}

// MARK: - Экран «Сейчас играет»

struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)

            ArtworkImage(image: player.artwork, corner: 28)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1.0 : 0.88)
                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.title ?? "Не играет")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(player.currentTrack?.artist ?? " ")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProgressSection(clock: player.clock)

            controls
            bottomRow

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .background {
            backgroundView.ignoresSafeArea()
        }
    }

    private var backgroundView: some View {
        ZStack {
            Color.black
            if let art = player.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 70)
                    .saturation(1.5)
            } else {
                LinearGradient(colors: [.pink, .purple, .indigo],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.35)
        }
        .clipped()
        .animation(.easeInOut(duration: 0.6), value: player.currentTrack?.id)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 24) {
                glassButton("backward.fill", size: 28, box: 64) { player.previous() }
                glassButton(player.isPlaying ? "pause.fill" : "play.fill", size: 36, box: 84) {
                    player.togglePlayPause()
                }
                glassButton("forward.fill", size: 28, box: 64) { player.next() }
            }
        }
    }

    private var bottomRow: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 28) {
                toggleButton("shuffle", active: player.shuffleOn) { player.toggleShuffle() }
                AirPlayButton().frame(width: 48, height: 48)
                toggleButton(player.repeatMode == .one ? "repeat.1" : "repeat",
                             active: player.repeatMode != .off) { player.cycleRepeat() }
            }
        }
    }

    private func glassButton(_ name: String, size: CGFloat, box: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: box, height: box)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private func toggleButton(_ name: String, active: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(active ? Glass.regular.tint(.pink.opacity(0.6)).interactive()
                            : Glass.regular.interactive(),
                     in: .circle)
    }
}

struct ProgressSection: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject var clock: PlayerClock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var shownTime: Double { scrubbing ? scrubValue : clock.currentTime }

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(get: { shownTime }, set: { scrubValue = $0 }),
                in: 0...max(clock.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = clock.currentTime
                        scrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
            )
            HStack {
                Text(format(shownTime))
                Spacer()
                Text("-" + format(max(clock.duration - shownTime, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func format(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemPink
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
