import SwiftUI
import AVKit

// MARK: - Мини-плеер

struct MiniPlayer: View {
    @ObservedObject var player: PlayerStore
    @Binding var showNowPlaying: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            // Обложка и название уезжают за пальцем при свайпе.
            HStack(spacing: 12) {
                ArtworkImage(image: player.artwork, corner: 8)
                    .frame(width: 34, height: 34)

                Text(player.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .offset(x: dragX)
            .opacity(1 - min(abs(dragX) / 160, 0.6))

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
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
        .clipped()
        .onTapGesture {
            if player.currentTrack != nil { showNowPlaying = true }
        }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard player.currentTrack != nil,
                          abs(v.translation.width) > abs(v.translation.height) else { return }
                    dragX = v.translation.width
                }
                .onEnded { v in
                    finishSwipe(v.translation.width, velocity: v.predictedEndTranslation.width)
                }
        )
    }

    /// Влево — следующий трек, вправо — предыдущий. Название выезжает с другой стороны.
    private func finishSwipe(_ width: CGFloat, velocity: CGFloat) {
        let forward = width < -60 || velocity < -220
        let back = width > 60 || velocity > 220
        guard forward || back, player.currentTrack != nil else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragX = 0 }
            return
        }
        Haptics.tap()
        let out: CGFloat = forward ? -220 : 220
        withAnimation(.easeIn(duration: 0.14)) { dragX = out }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            if forward { player.next() } else { player.skipBack() }
            dragX = -out * 0.6
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { dragX = 0 }
        }
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .label
        v.activeTintColor = .systemPink
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
