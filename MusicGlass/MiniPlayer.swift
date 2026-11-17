import SwiftUI
import AVKit

// MARK: - Мини-плеер

struct MiniPlayer: View {
    @ObservedObject var player: PlayerStore
    @Binding var showNowPlaying: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(image: player.artwork, corner: 8)
                .frame(width: 34, height: 34)

            Text(player.displayTitle)
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

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemPink
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
