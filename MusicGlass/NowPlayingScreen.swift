import SwiftUI
import MediaPlayer
import UIKit

// MARK: - Экран «Сейчас играет»

struct NowPlayingScreen: View {
    @EnvironmentObject var player: PlayerStore
    @EnvironmentObject var library: LibraryStore
    @State private var palette: [UIColor] = []
    @State private var showEditor = false

    private var paletteKey: String {
        palette.map { $0.description }.joined(separator: "|")
    }

    private var trackKey: String {
        "\(player.currentTrack?.id ?? "")|\(player.artwork != nil)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            artworkView
            Spacer(minLength: 24)
            titleRow
            if player.isLive {
                LiveRow()
                    .padding(.top, 18)
            } else {
                ScrubSection(clock: player.clock)
                    .padding(.top, 18)
            }

            Spacer(minLength: 8)
            transport
            Spacer(minLength: 8)
            volumeRow
            Spacer(minLength: 10)
            bottomRow
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
        .background { backdrop }
        .task(id: trackKey) { await updatePalette() }
        .sheet(isPresented: $showEditor) {
            if let t = player.currentTrack {
                TagEditorView(track: t)
            }
        }
    }

    // Фон

    private var backdrop: some View {
        ZStack {
            Color.black
            MeshArtBackground(colors: palette.map { Color(uiColor: $0) })
                .id(paletteKey)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 1.0), value: paletteKey)
        .ignoresSafeArea()
    }

    private func updatePalette() async {
        guard let art = player.artwork else {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { palette = [] }
            return
        }
        let colors = await Task.detached(priority: .userInitiated) {
            ArtPalette.colors(from: art)
        }.value
        palette = colors
    }

    // Обложка

    private var artworkView: some View {
        NowPlayingArtwork(image: player.artwork)
            .shadow(color: .black.opacity(0.35), radius: 28, y: 18)
            .scaleEffect(player.isPlaying ? 1.0 : 0.86)
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
    }

    // Название и меню

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(player.displaySubtitle)
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let t = player.currentTrack {
                if RadioID.isRadio(t) {
                    RadioFavoriteButton(track: t)
                } else if OnlineID.isOnline(t) {
                    OnlineFavoriteButton(track: t)
                } else {
                    FavoriteButton(track: t)
                }
            }

            Menu {
                if let t = player.currentTrack, RadioID.isRadio(t) {
                    if let s = RadioCatalog.shared.info(for: t),
                       !s.homepage.isEmpty,
                       let url = URL(string: s.homepage) {
                        Link(destination: url) {
                            Label("Сайт станции", systemImage: "safari")
                        }
                    }
                } else if let t = player.currentTrack, OnlineID.isOnline(t) {
                    if let info = OnlineCatalog.shared.info(for: t),
                       !info.artistHandle.isEmpty,
                       let url = URL(string: "https://audius.co/\(info.artistHandle)") {
                        Link(destination: url) {
                            Label("Открыть исполнителя на Audius", systemImage: "safari")
                        }
                    }
                } else {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Найти данные и обложку", systemImage: "square.and.pencil")
                    }
                    .disabled(player.currentTrack == nil)

                    if let t = player.currentTrack, let url = library.url(for: t) {
                        ShareLink(item: url) {
                            Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        }
    }


    // Управление

    private var transport: some View {
        HStack {
            Spacer()
            transportButton("backward.fill", size: 38) { player.previous() }
            Spacer()
            transportButton(player.isPlaying ? "pause.fill" : "play.fill", size: 58) {
                player.togglePlayPause()
            }
            Spacer()
            transportButton("forward.fill", size: 38) { player.next() }
            Spacer()
        }
    }

    private func transportButton(_ name: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 84, height: 84)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
            SystemVolumeSlider()
                .frame(height: 30)
            Image(systemName: "speaker.wave.3.fill")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private var bottomRow: some View {
        HStack {
            Spacer()
            toggleButton("shuffle", on: player.shuffleOn) { player.toggleShuffle() }
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            toggleButton(player.repeatMode == .one ? "repeat.1" : "repeat",
                         on: player.repeatMode != .off) { player.cycleRepeat() }
            Spacer()
        }
    }

    private func toggleButton(_ name: String, on: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(on ? 0.22 : 0)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Обложка с заглушкой

struct NowPlayingArtwork: View {
    let image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.10)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 84, weight: .regular))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Полоса прогресса

struct ScrubSection: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject var clock: PlayerClock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var shown: Double { scrubbing ? scrubValue : clock.currentTime }
    private var total: Double { max(clock.duration, 1) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let progress = min(max(shown / total, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28))
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: max(width * progress, 0))
                }
                .frame(height: scrubbing ? 12 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrubbing = true
                            let f = min(max(g.location.x / max(width, 1), 0), 1)
                            scrubValue = f * total
                        }
                        .onEnded { g in
                            let f = min(max(g.location.x / max(width, 1), 0), 1)
                            player.seek(to: f * total)
                            scrubbing = false
                        }
                )
                .animation(.easeOut(duration: 0.15), value: scrubbing)
            }
            .frame(height: 24)

            HStack {
                Text(format(shown))
                Spacer()
                Text("-" + format(max(total - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private func format(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Громкость

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Живой фон из цветов обложки

struct MeshArtBackground: View {
    let colors: [Color]

    private var meshColors: [Color] {
        let p: [Color] = colors.isEmpty
            ? [Color(white: 0.36), Color(white: 0.26), Color(white: 0.32), Color(white: 0.22)]
            : colors
        let idx = [0, 1, 2, 3, 0, 2, 1, 3, 0]
        return idx.map { p[$0 % p.count] }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: meshColors)
        }
        .overlay(Color.black.opacity(0.22))
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        func s(_ speed: Double, _ phase: Double) -> Float {
            Float(sin(t * speed + phase))
        }
        return [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.5 + 0.12 * s(0.45, 0), 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 0.5 + 0.12 * s(0.38, 1)),
            SIMD2<Float>(0.5 + 0.18 * s(0.31, 2), 0.5 + 0.18 * s(0.27, 3)),
            SIMD2<Float>(1, 0.5 + 0.12 * s(0.41, 4)),
            SIMD2<Float>(0, 1),
            SIMD2<Float>(0.5 + 0.12 * s(0.35, 5), 1),
            SIMD2<Float>(1, 1)
        ]
    }
}

// MARK: - Палитра из обложки

enum ArtPalette {
    static func colors(from image: UIImage, count: Int = 4) -> [UIColor] {
        let side = 32
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = small.cgImage else { return [] }
        let w = cg.width
        let h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        struct Bucket {
            var r = 0.0
            var g = 0.0
            var b = 0.0
            var n = 0.0
        }
        var buckets: [Int: Bucket] = [:]
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
            var bk = buckets[key] ?? Bucket()
            bk.r += r
            bk.g += g
            bk.b += b
            bk.n += 1
            buckets[key] = bk
        }

        var candidates: [(color: UIColor, score: Double)] = []
        for (_, bk) in buckets {
            let r = bk.r / bk.n
            let g = bk.g / bk.n
            let b = bk.b / bk.n
            var hue: CGFloat = 0
            var sat: CGFloat = 0
            var bri: CGFloat = 0
            var alpha: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1)
                .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            let weight = bk.n * (0.25 + Double(sat)) * (bri < 0.12 ? 0.2 : 1.0)
            let adjusted = UIColor(
                hue: hue,
                saturation: min(1, sat * 1.15 + 0.05),
                brightness: min(max(bri, 0.38), 0.85),
                alpha: 1
            )
            candidates.append((adjusted, weight))
        }
        candidates.sort { $0.score > $1.score }

        var chosen: [UIColor] = []
        for c in candidates {
            if chosen.allSatisfy({ distance($0, c.color) > 0.28 }) {
                chosen.append(c.color)
            }
            if chosen.count == count { break }
        }

        // Если обложка почти одноцветная, добавляем близкие оттенки для глубины.
        if let first = chosen.first, chosen.count < count {
            var hue: CGFloat = 0
            var sat: CGFloat = 0
            var bri: CGFloat = 0
            var alpha: CGFloat = 0
            first.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            var k: CGFloat = 1
            while chosen.count < count {
                let shifted = UIColor(
                    hue: (hue + 0.05 * k).truncatingRemainder(dividingBy: 1),
                    saturation: min(1, sat + 0.05 * k),
                    brightness: max(0.3, bri - 0.1 * k),
                    alpha: 1
                )
                chosen.append(shifted)
                k += 1
            }
        }
        return chosen
    }

    private static func distance(_ x: UIColor, _ y: UIColor) -> Double {
        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0
        x.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        y.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2
        return Double(sqrt(dr * dr + dg * dg + db * db))
    }
}
