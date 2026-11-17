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

// MARK: - Обложка станции

enum StationArt {
    private static let cache = NSCache<NSString, UIImage>()

    static func cover(for station: RadioStation, side: CGFloat) async -> UIImage {
        let key = "\(station.id)|\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let logo = await OnlineArtwork.image(station.favicon.isEmpty ? nil : station.favicon)
        let img = compose(logo: logo, name: station.name, side: side)
        cache.setObject(img, forKey: key)
        return img
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

    static func search(name: String? = nil, tag: String? = nil,
                       countryCode: String? = nil, limit: Int = 60) async throws -> [RadioStation] {
        var items = [
            URLQueryItem(name: "limit", value: "\(limit * 2)"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "votes"),
            URLQueryItem(name: "reverse", value: "true")
        ]
        if let name, !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
        if let tag, !tag.isEmpty { items.append(URLQueryItem(name: "tag", value: tag)) }
        if let countryCode, !countryCode.isEmpty {
            items.append(URLQueryItem(name: "countrycode", value: countryCode))
        }

        var lastError: Error = RadioError.network
        for server in servers.shuffled() {
            guard var comps = URLComponents(string: server + "/json/stations/search") else { continue }
            comps.queryItems = items
            guard let url = comps.url else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue("Opal/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    lastError = RadioError.network
                    continue
                }
                let list = try JSONDecoder().decode([RadioLossy<StationDTO>].self, from: data)
                var seen = Set<String>()
                var out: [RadioStation] = []
                for s in list.compactMap({ $0.value?.model }) {
                    if seen.insert(s.name.lowercased()).inserted { out.append(s) }
                    if out.count >= limit { break }
                }
                return out
            } catch is DecodingError {
                lastError = RadioError.decoding
            } catch {
                if Task.isCancelled { throw error }
                lastError = RadioError.network
            }
        }
        throw lastError
    }
}
