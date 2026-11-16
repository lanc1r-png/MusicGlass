import Foundation
import UIKit

// MARK: - Настройки

enum AudiusConfig {
    static let host = "https://api.audius.co/v1"
    static let appName = "Opal"
    /// Публичный ключ приложения (не секрет). Можно оставить пустым.
    /// Токены и секреты в клиентское приложение не кладём.
    static let apiKey = ""
}

enum AudiusError: LocalizedError {
    case badRequest, network, server(Int), decoding

    var errorDescription: String? {
        switch self {
        case .badRequest: return "Некорректный запрос."
        case .network: return "Нет соединения с Audius. Проверьте интернет."
        case .server(let code):
            return code == 429
                ? "Слишком много запросов. Подождите немного."
                : "Сервер Audius ответил ошибкой (\(code))."
        case .decoding: return "Не удалось разобрать ответ Audius."
        }
    }
}

// MARK: - Модели приложения

struct OnlineTrack: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var artistID: String
    var artistHandle: String
    var duration: Double
    var artworkSmall: String?
    var artworkMedium: String?
    var artworkLarge: String?
    var genre: String?

    var playerID: String { OnlineID.prefix + id }
}

struct OnlineArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let handle: String
    let avatar: String?
    let trackCount: Int
}

// MARK: - Идентификаторы онлайн-треков внутри плеера

enum OnlineID {
    static let prefix = "audius:"

    static func isOnline(_ t: Track) -> Bool { t.id.hasPrefix(prefix) }
    static func audiusID(of t: Track) -> String { String(t.id.dropFirst(prefix.count)) }
}

extension OnlineTrack {
    /// Представление онлайн-трека для существующего плеера.
    /// Если сборка ругается на эту строку, пришлите Library.swift: подгоню под ваш Track.
    var asTrack: Track {
        Track(id: playerID, folderID: "audius", relativePath: "",
              title: title, artist: artist, album: "Audius", duration: duration)
    }
}

/// Хранит сведения об онлайн-треках, которые сейчас в очереди (для обложек и т.п.).
@MainActor
final class OnlineCatalog {
    static let shared = OnlineCatalog()
    private var items: [String: OnlineTrack] = [:]

    func register(_ list: [OnlineTrack]) {
        for t in list { items[t.playerID] = t }
    }

    func info(for track: Track) -> OnlineTrack? {
        items[track.id]
    }
}

// MARK: - Обложки из сети

enum OnlineArtwork {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ urlString: String?) async -> UIImage? {
        guard let s = urlString, let url = URL(string: s) else { return nil }
        if let c = cache.object(forKey: s as NSString) { return c }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: s as NSString)
        return img
    }
}

// MARK: - Ответы API (устойчивое декодирование)

private struct AudiusEnvelope<T: Decodable>: Decodable {
    let data: T
}

/// Один «битый» элемент не ломает весь список.
private struct AudiusLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private struct ArtworkDTO: Decodable {
    let small: String?
    let medium: String?
    let large: String?

    enum CodingKeys: String, CodingKey {
        case small = "150x150"
        case medium = "480x480"
        case large = "1000x1000"
    }
}

private struct AccessDTO: Decodable {
    let stream: Bool?
}

private struct UserDTO: Decodable {
    let id: String
    let name: String?
    let handle: String?
    let profile_picture: ArtworkDTO?
    let track_count: Int?
}

private struct TrackDTO: Decodable {
    let id: String
    let title: String?
    let duration: Double?
    let user: UserDTO?
    let artwork: ArtworkDTO?
    let genre: String?
    let is_streamable: Bool?
    let access: AccessDTO?

    /// Закрытые, платные и снятые треки пропускаем.
    var isPlayable: Bool {
        if is_streamable == false { return false }
        if access?.stream == false { return false }
        return true
    }

    var model: OnlineTrack? {
        guard isPlayable else { return nil }
        return OnlineTrack(
            id: id,
            title: title ?? "Без названия",
            artist: user?.name ?? "Неизвестный исполнитель",
            artistID: user?.id ?? "",
            artistHandle: user?.handle ?? "",
            duration: duration ?? 0,
            artworkSmall: artwork?.small ?? artwork?.medium ?? artwork?.large,
            artworkMedium: artwork?.medium ?? artwork?.large ?? artwork?.small,
            artworkLarge: artwork?.large ?? artwork?.medium ?? artwork?.small,
            genre: genre
        )
    }
}

// MARK: - Клиент API

enum AudiusAPI {
    private static func url(_ path: String, _ items: [URLQueryItem] = []) -> URL? {
        var comps = URLComponents(string: AudiusConfig.host + path)
        var q = items
        q.append(URLQueryItem(name: "app_name", value: AudiusConfig.appName))
        if !AudiusConfig.apiKey.isEmpty {
            q.append(URLQueryItem(name: "api_key", value: AudiusConfig.apiKey))
        }
        comps?.queryItems = q
        return comps?.url
    }

    /// Адрес потока: сервер Audius сам перенаправит на ближайший узел. Файл не скачивается.
    static func streamURL(trackID: String) -> URL? {
        url("/tracks/\(trackID)/stream")
    }

    private static func fetch<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T {
        guard let url = url(path, items) else { throw AudiusError.badRequest }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw AudiusError.network
        }
        guard let http = resp as? HTTPURLResponse else { throw AudiusError.network }
        guard (200..<300).contains(http.statusCode) else { throw AudiusError.server(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AudiusError.decoding
        }
    }

    static func searchTracks(_ query: String, limit: Int = 30) async throws -> [OnlineTrack] {
        let r: AudiusEnvelope<[AudiusLossy<TrackDTO>]> = try await fetch("/tracks/search", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return r.data.compactMap { $0.value?.model }
    }

    static func searchArtists(_ query: String, limit: Int = 20) async throws -> [OnlineArtist] {
        let r: AudiusEnvelope<[AudiusLossy<UserDTO>]> = try await fetch("/users/search", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return r.data.compactMap { $0.value }.map {
            OnlineArtist(id: $0.id,
                         name: $0.name ?? "Без имени",
                         handle: $0.handle ?? "",
                         avatar: $0.profile_picture?.medium ?? $0.profile_picture?.small,
                         trackCount: $0.track_count ?? 0)
        }
    }

    static func trending(limit: Int = 30) async throws -> [OnlineTrack] {
        let r: AudiusEnvelope<[AudiusLossy<TrackDTO>]> = try await fetch("/tracks/trending", [
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return r.data.compactMap { $0.value?.model }
    }

    static func tracks(ofArtist id: String, limit: Int = 50) async throws -> [OnlineTrack] {
        let r: AudiusEnvelope<[AudiusLossy<TrackDTO>]> = try await fetch("/users/\(id)/tracks", [
            URLQueryItem(name: "limit", value: "\(limit)")
        ])
        return r.data.compactMap { $0.value?.model }
    }
}
