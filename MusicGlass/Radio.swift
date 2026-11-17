import SwiftUI
import UIKit

// MARK: - Модель станции

struct RadioStation: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var streamURL: String
    var homepage: String
    var favicon: String
    var tags: String
    var country: String
    var countryCode: String
    var codec: String
    var bitrate: Int

    var playerID: String { RadioID.prefix + id }

    /// Главный жанр (первый тег).
    var genre: String {
        let first = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !first.isEmpty else { return "" }
        return String(first.prefix(1)).uppercased() + String(first.dropFirst())
    }

    var subtitle: String {
        let parts = [genre, country].filter { !$0.isEmpty }
        return parts.isEmpty ? "Интернет-радио" : parts.joined(separator: " · ")
    }
}

enum RadioID {
    static let prefix = "radio:"
    static func isRadio(_ t: Track) -> Bool { t.id.hasPrefix(prefix) }
}

extension RadioStation {
    /// Представление станции для существующего плеера.
    var asTrack: Track {
        Track(id: playerID, folderID: "radio", relativePath: "",
              title: name, artist: subtitle, album: "Радио", duration: 0)
    }
}

/// Станции, которые сейчас в очереди (для адреса потока и обложки).
@MainActor
final class RadioCatalog {
    static let shared = RadioCatalog()
    private var items: [String: RadioStation] = [:]

    func register(_ list: [RadioStation]) {
        for s in list { items[s.playerID] = s }
    }

    func info(for track: Track) -> RadioStation? {
        items[track.id]
    }
}

@MainActor
func playRadio(_ list: [RadioStation], at index: Int, player: PlayerStore) {
    guard list.indices.contains(index) else { return }
    RadioCatalog.shared.register(list)
    player.play(list.map { $0.asTrack }, startAt: index)
}

// MARK: - Избранные станции

@MainActor
final class RadioLibrary: ObservableObject {
    static let shared = RadioLibrary()
    @Published private(set) var favorites: [RadioStation] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("radio.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([RadioStation].self, from: data) {
            favorites = list
        }
        RadioCatalog.shared.register(favorites)
    }

    func isFavorite(_ id: String) -> Bool {
        favorites.contains { $0.id == id }
    }

    func toggle(_ station: RadioStation) {
        if let i = favorites.firstIndex(where: { $0.id == station.id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(station, at: 0)
            RadioCatalog.shared.register([station])
        }
        if let data = try? JSONEncoder().encode(favorites) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Загрузка логотипов

/// Быстрый загрузчик логотипов: короткие таймауты, чтобы «мёртвые» сайты не тормозили сетку.
enum LogoLoader {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 8
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    static func image(from urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let (data, resp) = try? await session.data(from: url) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return nil }
        guard data.count < 3_000_000 else { return nil }
        return UIImage(data: data)
    }
}

/// Готовые обложки на диске (папка кэша), чтобы при повторном открытии они появлялись мгновенно.
enum DiskCovers {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RadioCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func file(_ id: String, _ side: Int, _ tag: String) -> URL {
        dir.appendingPathComponent("\(id)_\(side)_\(tag).jpg")
    }

    static func load(id: String, side: Int) -> UIImage? {
        // Обложка с настоящим логотипом хранится бессрочно.
        if let img = UIImage(contentsOfFile: file(id, side, "L").path) { return img }
        // Обложку с инициалами через 3 дня пробуем сделать заново: вдруг логотип найдётся.
        let f = file(id, side, "I")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
           let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 3 * 86400,
           let img = UIImage(contentsOfFile: f.path) {
            return img
        }
        return nil
    }

    static func save(_ image: UIImage, id: String, side: Int, hasLogo: Bool) {
        guard let data = image.jpegData(compressionQuality: 0.86) else { return }
        try? data.write(to: file(id, side, hasLogo ? "L" : "I"), options: .atomic)
    }
}

// MARK: - Обложка станции

enum StationArt {
    private static let cache = NSCache<NSString, UIImage>()
    private static let logos = NSCache<NSString, UIImage>()

    static func cover(for station: RadioStation, side: CGFloat) async -> UIImage {
        let key = "\(station.id)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let disk = DiskCovers.load(id: station.id, side: Int(side)) {
            cache.setObject(disk, forKey: key)
            return disk
        }
        let logo = await logo(for: station)
        let img = compose(logo: logo, name: station.name, side: side)
        // Если карточку уже пролистали и загрузка оборвалась, результат не запоминаем.
        if Task.isCancelled { return img }
        cache.setObject(img, forKey: key)
        DiskCovers.save(img, id: station.id, side: Int(side), hasLogo: logo != nil)
        return img
    }

    /// Ищем логотип: из каталога, затем по сайту станции.
    static func logo(for station: RadioStation) async -> UIImage? {
        let key = station.id as NSString
        if let hit = logos.object(forKey: key) { return hit }
        for u in logoCandidates(for: station) {
            if Task.isCancelled { return nil }
            if let img = await LogoLoader.image(from: u),
               min(img.size.width, img.size.height) >= 32 {
                logos.setObject(img, forKey: key)
                return img
            }
        }
        return nil
    }

    private static func logoCandidates(for s: RadioStation) -> [String] {
        var out: [String] = []
        if !s.favicon.isEmpty { out.append(s.favicon) }
        let page = s.homepage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !page.isEmpty {
            let full = page.contains("://") ? page : "http://" + page
            if let host = URL(string: full)?.host, !host.isEmpty {
                out.append("https://t1.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&url=https://\(host)&size=128")
                out.append("https://\(host)/apple-touch-icon.png")
            }
        }
        return out
    }

    /// Градиент из цветов логотипа, по центру логотип на белой плитке (или инициалы).
    static func compose(logo: UIImage?, name: String, side: CGFloat) -> UIImage {
        let (c1, c2) = gradientColors(logo: logo, name: name)
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: space,
                                     colors: [c1.cgColor, c2.cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: .zero,
                                      end: CGPoint(x: side, y: side), options: [])
            }
            let tile = side * 0.56
            let tileRect = CGRect(x: (side - tile) / 2, y: (side - tile) / 2,
                                  width: tile, height: tile)
            if let logo {
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: side * 0.02),
                             blur: side * 0.05,
                             color: UIColor.black.withAlphaComponent(0.3).cgColor)
                UIColor.white.withAlphaComponent(0.96).setFill()
                UIBezierPath(roundedRect: tileRect, cornerRadius: tile * 0.22).fill()
                cg.restoreGState()

                let inner = tileRect.insetBy(dx: tile * 0.12, dy: tile * 0.12)
                let ratio = logo.size.width / max(logo.size.height, 1)
                var w = inner.width
                var h = w / max(ratio, 0.01)
                if h > inner.height {
                    h = inner.height
                    w = h * ratio
                }
                logo.draw(in: CGRect(x: inner.midX - w / 2, y: inner.midY - h / 2,
                                     width: w, height: h))
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: side * 0.3, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let s = NSAttributedString(string: initials(name), attributes: attrs)
                let ts = s.size()
                s.draw(at: CGPoint(x: (side - ts.width) / 2, y: (side - ts.height) / 2))
            }
        }
    }

    private static func gradientColors(logo: UIImage?, name: String) -> (UIColor, UIColor) {
        var base: [UIColor] = []
        if let logo { base = ArtPalette.colors(from: logo, count: 2) }
        let hue = CGFloat(stableHash(name) % 360) / 360
        let c1 = base.first ?? UIColor(hue: hue, saturation: 0.62, brightness: 0.78, alpha: 1)
        let c2 = base.count > 1 ? base[1] : shifted(c1)
        return (c1, c2)
    }

    private static func shifted(_ c: UIColor) -> UIColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: (h + 0.08).truncatingRemainder(dividingBy: 1),
                       saturation: min(1, s + 0.05),
                       brightness: max(0.3, b - 0.25),
                       alpha: 1)
    }

    private static func stableHash(_ s: String) -> Int {
        var h = 5381
        for u in s.unicodeScalars {
            h = (h &* 33 &+ Int(u.value)) & 0x7fffffff
        }
        return h
    }

    private static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "♪" : s
    }
}

struct StationCover: View {
    let station: RadioStation
    var corner: CGFloat = 14
    var side: CGFloat = 400
    @State private var image: UIImage?

    var body: some View {
        ArtworkImage(image: image, corner: corner)
            .task(id: station.id) {
                image = await StationArt.cover(for: station, side: side)
            }
    }
}

// MARK: - Кэш списков станций

private struct RadioCacheEntry: Codable {
    let date: Date
    let stations: [RadioStation]
}

/// Запоминает списки станций (в памяти и на диске), чтобы страны и жанры открывались мгновенно.
enum RadioCache {
    private static let lock = NSLock()
    private static var memory: [String: RadioCacheEntry] = [:]
    static let freshFor: TimeInterval = 600
    private static let keepFor: TimeInterval = 7 * 86400

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RadioLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func key(name: String?, tag: String?, countryCode: String?, limit: Int) -> String {
        "n=\(name ?? "")|t=\(tag ?? "")|c=\(countryCode ?? "")|l=\(limit)"
    }

    private static func file(for key: String) -> URL {
        var h = 5381
        for u in key.unicodeScalars { h = (h &* 33 &+ Int(u.value)) & 0x7fffffff }
        return dir.appendingPathComponent("\(h).json")
    }

    static func get(_ key: String) -> (stations: [RadioStation], fresh: Bool)? {
        lock.lock()
        var entry = memory[key]
        lock.unlock()
        if entry == nil,
           let data = try? Data(contentsOf: file(for: key)),
           let e = try? JSONDecoder().decode(RadioCacheEntry.self, from: data) {
            entry = e
            lock.lock()
            memory[key] = e
            lock.unlock()
        }
        guard let e = entry, !e.stations.isEmpty else { return nil }
        let age = Date().timeIntervalSince(e.date)
        guard age < keepFor else { return nil }
        return (e.stations, age < freshFor)
    }

    static func put(_ key: String, _ list: [RadioStation]) {
        guard !list.isEmpty else { return }
        let e = RadioCacheEntry(date: Date(), stations: list)
        lock.lock()
        memory[key] = e
        lock.unlock()
        if let data = try? JSONEncoder().encode(e) {
            try? data.write(to: file(for: key), options: .atomic)
        }
    }
}

// MARK: - API каталога Radio Browser

enum RadioError: LocalizedError {
    case network, decoding

    var errorDescription: String? {
        switch self {
        case .network: return "Не удалось связаться с каталогом станций. Проверьте интернет."
        case .decoding: return "Не удалось разобрать ответ каталога станций."
        }
    }
}

private struct RadioLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private struct StationDTO: Decodable {
    let stationuuid: String
    let name: String?
    let url_resolved: String?
    let url: String?
    let homepage: String?
    let favicon: String?
    let tags: String?
    let country: String?
    let countrycode: String?
    let codec: String?
    let bitrate: Int?
    let lastcheckok: Int?

    var model: RadioStation? {
        let stream = (url_resolved?.isEmpty == false ? url_resolved : url) ?? ""
        guard !stream.isEmpty, lastcheckok != 0 else { return nil }
        // AVPlayer не играет Ogg/Vorbis/Opus, такие станции пропускаем.
        let c = (codec ?? "").uppercased()
        if c.contains("OGG") || c.contains("VORBIS") || c.contains("OPUS") { return nil }
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        return RadioStation(id: stationuuid, name: n, streamURL: stream,
                            homepage: homepage ?? "", favicon: favicon ?? "",
                            tags: tags ?? "", country: country ?? "",
                            countryCode: countrycode ?? "", codec: codec ?? "",
                            bitrate: bitrate ?? 0)
    }
}

enum RadioAPI {
    private static let servers = [
        "https://de1.api.radio-browser.info",
        "https://de2.api.radio-browser.info",
        "https://nl1.api.radio-browser.info",
        "https://at1.api.radio-browser.info"
    ]

    /// Сохранённый список (если есть) и признак, что он ещё свежий.
    static func cached(name: String? = nil, tag: String? = nil,
                       countryCode: String? = nil,
                       limit: Int = 60) -> (stations: [RadioStation], fresh: Bool)? {
        RadioCache.get(RadioCache.key(name: name, tag: tag, countryCode: countryCode, limit: limit))
    }

    static func search(name: String? = nil, tag: String? = nil,
                       countryCode: String? = nil, limit: Int = 60) async throws -> [RadioStation] {
        var items = [
            URLQueryItem(name: "limit", value: "\(limit + 30)"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        if let tag, !tag.isEmpty { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let countryCode, !countryCode.isEmpty {
            items.append(URLQueryItem(name: "countrycode", value: countryCode))
        }

        // Спрашиваем сразу два сервера, берём того, кто ответил первым.
        // Если оба недоступны, пробуем два оставшихся.
        let shuffled = servers.shuffled()
        let list: [RadioStation]
        do {
            list = try await race(Array(shuffled.prefix(2)), items: items, limit: limit)
        } catch {
            if Task.isCancelled { throw error }
            list = try await race(Array(shuffled.suffix(2)), items: items, limit: limit)
        }
        RadioCache.put(RadioCache.key(name: name, tag: tag, countryCode: countryCode, limit: limit), list)
        return list
    }

    private static func race(_ servers: [String], items: [URLQueryItem],
                             limit: Int) async throws -> [RadioStation] {
        try await withThrowingTaskGroup(of: [RadioStation].self) { group -> [RadioStation] in
            for s in servers {
                group.addTask { try await fetchOne(server: s, items: items, limit: limit) }
            }
            var lastError: Error = RadioError.network
            while true {
                do {
                    guard let list = try await group.next() else { break }
                    group.cancelAll()
                    return list
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }

    private static func fetchOne(server: String, items: [URLQueryItem],
                                 limit: Int) async throws -> [RadioStation] {
        guard var comps = URLComponents(string: server + "/json/stations/search") else {
            throw RadioError.network
        }
        comps.queryItems = items
        guard let url = comps.url else { throw RadioError.network }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("Opal/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RadioError.network }
        let decoded: [RadioLossy<StationDTO>]
        do {
            decoded = try JSONDecoder().decode([RadioLossy<StationDTO>].self, from: data)
        } catch {
            throw RadioError.decoding
        }
        var seen = Set<String>()
        var out: [RadioStation] = []
        for s in decoded.compactMap({ $0.value?.model }) {
            if seen.insert(s.name.lowercased()).inserted { out.append(s) }
            if out.count >= limit { break }
        }
        return out
    }
}
