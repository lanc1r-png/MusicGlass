import SwiftUI
import AVFoundation

// MARK: - Модель

struct LyricLine: Codable, Hashable, Identifiable {
    var id: Int
    var time: Double?      // nil, если текст без таймингов
    var text: String
}

struct Lyrics: Codable {
    var lines: [LyricLine]
    var synced: Bool
    var instrumental: Bool = false
}

// MARK: - Загрузка (LRCLIB + теги файла)

/// Тексты берутся из открытой базы lrclib.net (бесплатно, без ключа) или из тегов файла.
enum LyricsService {
    private static let memory = NSCache<NSString, LyricsBox>()
    final class LyricsBox { let value: Lyrics?; init(_ v: Lyrics?) { value = v } }

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private struct DiskEntry: Codable {
        let date: Date
        let lyrics: Lyrics?
    }

    private struct LRCLibItem: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    static func lyrics(for track: Track, localURL: URL?) async -> Lyrics? {
        let key = track.id as NSString
        if let hit = memory.object(forKey: key) { return hit.value }
        let file = dir.appendingPathComponent(hash(track.id) + ".json")
        if let data = try? Data(contentsOf: file),
           let e = try? JSONDecoder().decode(DiskEntry.self, from: data),
           e.lyrics != nil || Date().timeIntervalSince(e.date) < 86400 {
            memory.setObject(LyricsBox(e.lyrics), forKey: key)
            return e.lyrics
        }

        var result = await fromLRCLib(track)
        if result == nil || result?.synced == false, let localURL, let tagged = await fromTags(localURL) {
            if result == nil { result = tagged }
        }
        if Task.isCancelled { return result }
        memory.setObject(LyricsBox(result), forKey: key)
        if let data = try? JSONEncoder().encode(DiskEntry(date: Date(), lyrics: result)) {
            try? data.write(to: file, options: .atomic)
        }
        return result
    }

    private static func fromTags(_ url: URL) async -> Lyrics? {
        let asset = AVURLAsset(url: url)
        guard let text = try? await asset.load(.lyrics), !text.isEmpty else { return nil }
        return plain(text)
    }

    private static func fromLRCLib(_ track: Track) async -> Lyrics? {
        let title = track.title
        let artist = track.artist == "Неизвестный артист" ? "" : track.artist
        // Сначала точный запрос, потом поиск.
        if !artist.isEmpty, track.duration > 0 {
            var c = URLComponents(string: "https://lrclib.net/api/get")!
            c.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "duration", value: "\(Int(track.duration.rounded()))")
            ]
            if let item: LRCLibItem = await fetch(c.url), let l = make(item) { return l }
        }
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { c.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        guard let list: [LRCLibItem] = await fetch(c.url), !list.isEmpty else { return nil }
        // Предпочитаем с таймингами и близкой длительностью.
        let ranked = list.sorted { a, b in
            score(a, track) > score(b, track)
        }
        for item in ranked.prefix(3) {
            if let l = make(item) { return l }
        }
        return nil
    }

    private static func score(_ i: LRCLibItem, _ t: Track) -> Double {
        var s = 0.0
        if i.syncedLyrics?.isEmpty == false { s += 10 }
        if let d = i.duration, t.duration > 0 { s -= min(abs(d - t.duration), 30) / 3 }
        return s
    }

    private static func fetch<T: Decodable>(_ url: URL?) async -> T? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Opal/1.0 (https://github.com/lanc1r-png/MusicGlass)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func make(_ item: LRCLibItem) -> Lyrics? {
        if item.instrumental == true { return Lyrics(lines: [], synced: false, instrumental: true) }
        if let s = item.syncedLyrics, let l = parseLRC(s) { return l }
        if let p = item.plainLyrics, !p.isEmpty { return plain(p) }
        return nil
    }

    static func plain(_ text: String) -> Lyrics {
        let lines = text.components(separatedBy: .newlines).enumerated().map {
            LyricLine(id: $0.offset, time: nil, text: $0.element.trimmingCharacters(in: .whitespaces))
        }
        return Lyrics(lines: lines, synced: false)
    }

    /// Разбор формата LRC: «[01:23.45] строка».
    static func parseLRC(_ text: String) -> Lyrics? {
        var out: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) {
                    times.append(m * 60 + sec)
                }
                rest = rest[rest.index(after: close)...]
            }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for t in times { out.append((t, line)) }
        }
        guard !out.isEmpty else { return nil }
        out.sort { $0.0 < $1.0 }
        let lines = out.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
        return Lyrics(lines: lines, synced: true)
    }

    private static func hash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(h, radix: 36)
    }
}

// MARK: - Экран текста

struct LyricsPanel: View {
    @Environment(\.playerControl) private var player
    @ObservedObject private var status = PlaybackStatus.shared
    @EnvironmentObject var library: LibraryStore
    /// Время не наблюдается напрямую: экран обновляется только при смене строки.
    let clock: PlayerClock
    let fg: Color

    @State private var lyrics: Lyrics?
    @State private var loading = true
    @State private var userScrolling = false
    @State private var currentLine: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func line(at time: Double) -> Int? {
        guard let l = lyrics, l.synced else { return nil }
        let t = time + 0.35
        return l.lines.lastIndex { ($0.time ?? .infinity) <= t }
    }

    var body: some View {
        Group {
            if status.currentID.map({ $0.hasPrefix(RadioID.prefix) }) ?? false {
                message("Для радио тексты недоступны", icon: "dot.radiowaves.left.and.right")
            } else if loading {
                ProgressView().tint(fg).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let l = lyrics, l.instrumental {
                message("Инструментальная композиция", icon: "pianokeys")
            } else if let l = lyrics, !l.lines.isEmpty {
                lines(l)
            } else {
                message("Текст не найден", icon: "quote.bubble")
            }
        }
        .task(id: status.currentID) { await load() }
        .onReceive(clock.$currentTime) { t in
            let c = line(at: t)
            if c != currentLine { currentLine = c }
        }
    }

    private func load() async {
        loading = true
        lyrics = nil
        currentLine = nil
        guard let t = player?.currentTrack, !RadioID.isRadio(t) else {
            loading = false
            return
        }
        let local = OnlineID.isOnline(t) ? nil : library.url(for: t)
        let l = await LyricsService.lyrics(for: t, localURL: local)
        if Task.isCancelled { return }
        withAnimation(.easeOut(duration: 0.3)) {
            lyrics = l
            loading = false
        }
        currentLine = line(at: clock.currentTime)
    }

    private func lines(_ l: Lyrics) -> some View {
        let current = currentLine
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(l.lines.enumerated()), id: \.element.id) { idx, line in
                        lineView(line, index: idx, current: current, synced: l.synced)
                            .id(line.id)
                    }
                    Text("Тексты: LRCLIB")
                        .font(.caption)
                        .foregroundStyle(fg.opacity(0.4))
                        .padding(.top, 12)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.08),
                                       .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            .onChange(of: current) { _, new in
                guard let new, !userScrolling else { return }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.6, dampingFraction: 0.85)) {
                    proxy.scrollTo(l.lines[new].id, anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
            .onAppear {
                if let c = current { proxy.scrollTo(l.lines[c].id, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, index: Int, current: Int?, synced: Bool) -> some View {
        let isCurrent = index == current
        let distance = current.map { abs($0 - index) } ?? 0
        let text = line.text.isEmpty ? "♪" : line.text
        Text(text)
            .font(.system(size: synced ? 28 : 22, weight: .bold))
            .foregroundStyle(fg.opacity(!synced ? 0.85 : (isCurrent ? 1 : 0.32)))
            // Размываются только ближайшие строки: дальние и так почти не видны,
            // а размытие каждой строки — лишняя работа для видеокарты.
            .blur(radius: synced && !isCurrent && !userScrolling && !reduceMotion && distance <= 3
                  ? Double(distance) * 0.6 : 0)
            .scaleEffect(isCurrent || reduceMotion ? 1.0 : 0.97, anchor: .leading)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isCurrent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if let t = line.time {
                    Haptics.tap()
                    player?.seek(to: t)
                }
            }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34))
            Text(text).font(.headline)
        }
        .foregroundStyle(fg.opacity(0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
