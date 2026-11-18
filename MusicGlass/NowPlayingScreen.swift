import SwiftUI
import MediaPlayer
import AVFoundation
import UIKit

// MARK: - Экран «Сейчас играет»

enum NowPanel { case none, lyrics, queue }

struct NowPlayingScreen: View {
    @EnvironmentObject var player: PlayerStore
    @EnvironmentObject var library: LibraryStore
    @State private var palette: [UIColor] = []
    @State private var showEditor = false
    @State private var panel: NowPanel = .none
    @Namespace private var artNS
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fg: Color { scheme == .dark ? .white : .black }

    private var paletteKey: String {
        palette.map { $0.description }.joined(separator: "|")
    }

    private var trackKey: String {
        "\(player.currentTrack?.id ?? "")|\(player.artwork != nil)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if panel == .none {
                Spacer(minLength: 28)
                artworkView
                Spacer(minLength: 24)
                titleRow
            } else {
                compactHeader
                    .padding(.top, 30)
                Group {
                    if panel == .lyrics {
                        LyricsPanel(clock: player.clock, fg: fg)
                    } else {
                        QueuePanel(fg: fg)
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if player.isLive {
                LiveRow()
                    .padding(.top, 18)
            } else {
                ScrubSection(clock: player.clock)
                    .padding(.top, 14)
            }

            Spacer(minLength: 8)
            transport
            Spacer(minLength: 8)
            VolumeRow(fg: fg)
            Spacer(minLength: 10)
            bottomRow
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .foregroundStyle(fg)
        .background { backdrop }
        .task(id: trackKey) { await updatePalette() }
        .sheet(isPresented: $showEditor) {
            if let t = player.currentTrack {
                TagEditorView(track: t)
            }
        }
    }

    private func setPanel(_ p: NowPanel) {
        Haptics.tap()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            panel = panel == p ? .none : p
        }
    }

    // Фон

    private var backdrop: some View {
        ZStack {
            scheme == .dark ? Color.black : Color.white
            MeshArtBackground(colors: palette.map { Color(uiColor: ArtPalette.toned($0, dark: scheme == .dark)) },
                              dark: scheme == .dark,
                              paused: !player.isPlaying || reduceMotion)
                .id(paletteKey + "\(scheme == .dark)")
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 1.2), value: paletteKey)
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
            .matchedGeometryEffect(id: "art", in: artNS)
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.22), radius: 28, y: 18)
            .scaleEffect(player.isPlaying ? 1.0 : 0.86)
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
    }

    /// Шапка в режиме текста или очереди: маленькая обложка, название, сердечко и меню.
    private var compactHeader: some View {
        HStack(spacing: 12) {
            NowPlayingArtwork(image: player.artwork, corner: 10)
                .matchedGeometryEffect(id: "art", in: artNS)
                .frame(width: 62, height: 62)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                .onTapGesture { setPanel(panel) }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(player.displaySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(fg.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            glassButtons
        }
    }

    /// Сердечко и «⋯» в одном стеклянном контейнере.
    private var glassButtons: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                favoriteButton
                moreMenu
            }
        }
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
                    .foregroundStyle(fg.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            glassButtons
        }
    }

    @ViewBuilder
    private var favoriteButton: some View {
        if let t = player.currentTrack {
            if RadioID.isRadio(t) {
                RadioFavoriteButton(track: t)
            } else if OnlineID.isOnline(t) {
                OnlineFavoriteButton(track: t)
            } else {
                FavoriteButton(track: t)
            }
        }
    }

    private var moreMenu: some View {
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

    /// Как в Apple Music: текст — AirPlay — очередь.
    private var bottomRow: some View {
        HStack {
            Spacer()
            toggleButton(panel == .lyrics ? "quote.bubble.fill" : "quote.bubble",
                         on: panel == .lyrics) { setPanel(.lyrics) }
            Spacer()
            AirPlayButton().frame(width: 44, height: 44)
            Spacer()
            toggleButton("list.bullet", on: panel == .queue) { setPanel(.queue) }
            Spacer()
        }
    }

    private func toggleButton(_ name: String, on: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? fg : fg.opacity(0.55))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(Circle().fill(fg.opacity(on ? 0.2 : 0)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Очередь «Далее»

struct QueuePanel: View {
    @EnvironmentObject var player: PlayerStore
    let fg: Color
    @State private var editMode: EditMode = .active

    var body: some View {
        let up = player.upcoming
        let base = (player.currentIndex ?? 0) + 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(player.isLive ? "Другие станции" : "Далее")
                    .font(.title3.weight(.bold))
                Spacer()
                if !player.isLive {
                    pill(player.shuffleOn ? "shuffle" : "shuffle", on: player.shuffleOn) {
                        player.toggleShuffle()
                    }
                    pill(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) {
                        player.cycleRepeat()
                    }
                }
            }
            .padding(.top, 18)

            if up.isEmpty {
                Text("Дальше ничего нет")
                    .font(.subheadline)
                    .foregroundStyle(fg.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(up.enumerated()), id: \.offset) { offset, track in
                        HStack(spacing: 12) {
                            ArtworkView(track: track, corner: 6, maxPixels: 120)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(fg)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(fg.opacity(0.6))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap()
                            player.jump(to: base + offset)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation { player.removeUpcoming(at: offset) }
                            } label: {
                                Label("Убрать из очереди", systemImage: "minus.circle")
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
                .tint(fg)
            }
        }
    }

    private func pill(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(on ? (fg == .white ? Color.black : Color.white) : fg)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 30)
                .background(Capsule().fill(on ? fg.opacity(0.9) : fg.opacity(0.12)))
        }
        .buttonStyle(PressScaleStyle())
    }
}

// MARK: - Обложка с заглушкой

struct NowPlayingArtwork: View {
    let image: UIImage?
    var corner: CGFloat = 24
    @Environment(\.colorScheme) private var scheme
    private var fg: Color { scheme == .dark ? .white : .black }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    fg.opacity(0.10)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: corner > 12 ? 84 : 22, weight: .regular))
                                .foregroundStyle(fg.opacity(0.35))
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Упругая полоса (перемотка и громкость, как в Apple Music)

/// При касании утолщается, тянется за пальцем относительно, а за краями пружинит.
struct ElasticBar: View {
    let value: Double
    let fg: Color
    @Binding var active: Bool
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    @State private var startValue: Double = 0
    @State private var overflow: CGFloat = 0
    @State private var last: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let v = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(fg.opacity(active ? 0.28 : 0.2))
                Capsule()
                    .fill(fg.opacity(active ? 1 : 0.78))
                    .frame(width: w * v)
            }
            .frame(height: active ? 14 : 7)
            .scaleEffect(x: 1 + abs(overflow) / w, y: 1 - min(abs(overflow) / 160, 0.3),
                         anchor: overflow < 0 ? .trailing : .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !active {
                            startValue = v
                            last = v
                            haptic.prepare()
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                                                       : .spring(response: 0.3, dampingFraction: 0.62)) { active = true }
                        }
                        let raw = startValue + Double(g.translation.width / w)
                        let clamped = min(max(raw, 0), 1)
                        let over = CGFloat(raw - clamped) * w
                        // При «Уменьшить движение» полоса не пружинит за краями.
                        overflow = reduceMotion ? 0 : (over >= 0 ? 1 : -1) * pow(abs(over), 0.7)
                        if (clamped == 0 || clamped == 1) && last != clamped { haptic.impactOccurred() }
                        last = clamped
                        onChange(clamped)
                    }
                    .onEnded { _ in
                        let final = last
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                                                   : .spring(response: 0.45, dampingFraction: 0.55)) {
                            active = false
                            overflow = 0
                        }
                        onEnd(final)
                    }
            )
        }
    }
}

// MARK: - Полоса прогресса

struct ScrubSection: View {
    @EnvironmentObject var player: PlayerStore
    @ObservedObject var clock: PlayerClock
    @State private var active = false
    @State private var scrubValue: Double = 0
    @Environment(\.colorScheme) private var scheme
    private var fg: Color { scheme == .dark ? .white : .black }

    private var shown: Double { active ? scrubValue : clock.currentTime }
    private var total: Double { max(clock.duration, 1) }

    var body: some View {
        VStack(spacing: 4) {
            ElasticBar(value: shown / total, fg: fg, active: $active,
                       onChange: { scrubValue = $0 * total },
                       onEnd: { player.seek(to: $0 * total) })
                .frame(height: 30)

            HStack {
                Text(format(shown))
                Spacer()
                Text("-" + format(max(total - shown, 0)))
            }
            .font(.caption.monospacedDigit().weight(active ? .semibold : .regular))
            .foregroundStyle(fg.opacity(active ? 0.9 : 0.55))
            .scaleEffect(active ? 1.06 : 1)
            .offset(y: active ? 3 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
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

/// Системная громкость: читаем из аудиосессии, меняем через скрытый системный слайдер.
@MainActor
final class SystemVolume: ObservableObject {
    static let shared = SystemVolume()
    @Published var value: Double
    var dragging = false
    weak var slider: UISlider?
    private var observation: NSKeyValueObservation?

    private init() {
        value = Double(AVAudioSession.sharedInstance().outputVolume)
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let v = Double(session.outputVolume)
            Task { @MainActor in
                guard let self, !self.dragging else { return }
                withAnimation(.easeOut(duration: 0.15)) { self.value = v }
            }
        }
    }

    func set(_ v: Double) {
        value = v
        slider?.value = Float(v)
    }
}

/// Невидимый системный регулятор: нужен, чтобы менять громкость и не показывать системную плашку.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        v.alpha = 0.011
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        DispatchQueue.main.async {
            SystemVolume.shared.slider = Self.findSlider(in: uiView)
        }
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let s = view as? UISlider { return s }
        for sub in view.subviews {
            if let s = findSlider(in: sub) { return s }
        }
        return nil
    }
}

struct VolumeRow: View {
    let fg: Color
    @ObservedObject private var volume = SystemVolume.shared
    @State private var active = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.footnote)
                .foregroundStyle(fg.opacity(active ? 0.9 : 0.55))
                .scaleEffect(active ? 1.18 : 1)
            ElasticBar(value: volume.value, fg: fg, active: $active,
                       onChange: { volume.set($0) },
                       onEnd: { volume.set($0) })
                .frame(height: 30)
            Image(systemName: "speaker.wave.3.fill", variableValue: volume.value)
                .font(.footnote)
                .foregroundStyle(fg.opacity(active ? 0.9 : 0.55))
                .scaleEffect(active ? 1.18 : 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
        .background {
            HiddenVolumeView()
                .frame(width: 100, height: 30)
                .allowsHitTesting(false)
        }
        .onChange(of: active) { _, a in volume.dragging = a }
    }
}

// MARK: - Живой фон из цветов обложки

struct MeshArtBackground: View {
    let colors: [Color]
    var dark: Bool = true
    /// На паузе фон замирает и не тратит батарею.
    var paused: Bool = false

    private var meshColors: [Color] {
        let fallback: [Color] = dark
            ? [Color(white: 0.20), Color(white: 0.14), Color(white: 0.18), Color(white: 0.11)]
            : [Color(white: 0.96), Color(white: 0.90), Color(white: 0.93), Color(white: 0.87)]
        let p = colors.isEmpty ? fallback : colors
        let idx = [0, 1, 2, 3, 0, 2, 1, 3, 0]
        return idx.map { p[$0 % p.count] }
    }

    var body: some View {
        // Медленное, едва заметное движение, как в Apple Music.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: meshColors,
                         smoothsColors: true)
        }
        .overlay(dark ? Color.black.opacity(0.30) : Color.white.opacity(0.35))
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        func s(_ speed: Double, _ phase: Double) -> Float {
            Float(sin(t * speed + phase))
        }
        return [
            SIMD2<Float>(0, 0),
            SIMD2<Float>(0.5 + 0.06 * s(0.13, 0), 0),
            SIMD2<Float>(1, 0),
            SIMD2<Float>(0, 0.5 + 0.06 * s(0.11, 1)),
            SIMD2<Float>(0.5 + 0.10 * s(0.09, 2), 0.5 + 0.10 * s(0.08, 3)),
            SIMD2<Float>(1, 0.5 + 0.06 * s(0.12, 4)),
            SIMD2<Float>(0, 1),
            SIMD2<Float>(0.5 + 0.06 * s(0.10, 5), 1),
            SIMD2<Float>(1, 1)
        ]
    }
}

// MARK: - Палитра из обложки

enum ArtPalette {
    /// Приглушает цвет под тему: в тёмной темнее, в светлой ближе к белому.
    static func toned(_ c: UIColor, dark: Bool) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if dark {
            return UIColor(hue: h, saturation: min(1, s * 0.95), brightness: min(b, 0.8) * 0.55, alpha: 1)
        } else {
            return UIColor(hue: h, saturation: s * 0.40, brightness: min(0.98, 0.84 + b * 0.14), alpha: 1)
        }
    }

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
