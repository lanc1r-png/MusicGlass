import Foundation
import UIKit

struct MetaCandidate: Identifiable {
    let id = UUID()
    var title: String
    var artist: String
    var album: String
    var year: String
    var genre: String
    var coverURL: URL?
    var thumbURL: URL?
    var source: String
}

private struct ITunesResponse: Decodable {
    let results: [ITunesItem]
}

private struct ITunesItem: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let releaseDate: String?
    let primaryGenreName: String?
    let artworkUrl100: String?
}

private struct MBResponse: Decodable {
    let recordings: [MBRecording]
}

private struct MBRecording: Decodable {
    let id: String
    let title: String
    let firstReleaseDate: String?
    let artistCredit: [MBCredit]?
    let releases: [MBRelease]?

    enum CodingKeys: String, CodingKey {
        case id, title, releases
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
    }
}

private struct MBCredit: Decodable {
    let name: String?
}

private struct MBRelease: Decodable {
    let id: String
    let title: String?
    let date: String?
}

enum MetadataSearch {
    static let userAgent = "MusicGlass/1.0 (personal music player)"

    // MARK: iTunes

    static func itunes(_ query: String) async throws -> [MetaCandidate] {
        var all: [MetaCandidate] = []
        await withTaskGroup(of: [MetaCandidate].self) { group in
            for country in ["US", "JP", "RU"] {
                group.addTask {
                    (try? await MetadataSearch.itunesOne(query, country: country)) ?? []
                }
            }
            for await part in group {
                all.append(contentsOf: part)
            }
        }
        var seen = Set<String>()
        return all.filter { item in
            let key = "\(item.title)|\(item.artist)|\(item.album)".lowercased()
            return seen.insert(key).inserted
        }
    }

    private static func itunesOne(_ query: String, country: String) async throws -> [MetaCandidate] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country)
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let decoded = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return decoded.results.compactMap { r -> MetaCandidate? in
            guard let title = r.trackName else { return nil }
            let thumb = r.artworkUrl100
            let big = thumb?.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
            return MetaCandidate(
                title: title,
                artist: r.artistName ?? "",
                album: r.collectionName ?? "",
                year: String((r.releaseDate ?? "").prefix(4)),
                genre: r.primaryGenreName ?? "",
                coverURL: big.flatMap { URL(string: $0) },
                thumbURL: thumb.flatMap { URL(string: $0) },
                source: "iTunes"
            )
        }
    }

    // MARK: MusicBrainz + Cover Art Archive

    static func musicBrainz(_ query: String) async throws -> [MetaCandidate] {
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        let cleaned = String(query.map { special.contains($0) ? " " : $0 })
        let lucene = "recording:(\(cleaned)) OR artist:(\(cleaned)) OR release:(\(cleaned))"

        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: lucene),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "20")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(MBResponse.self, from: data)

        var out: [MetaCandidate] = []
        for rec in decoded.recordings {
            let artist = (rec.artistCredit ?? []).compactMap { $0.name }.joined(separator: ", ")
            let releases = rec.releases ?? []
            if releases.isEmpty {
                out.append(MetaCandidate(
                    title: rec.title, artist: artist, album: "",
                    year: String((rec.firstReleaseDate ?? "").prefix(4)), genre: "",
                    coverURL: nil, thumbURL: nil, source: "MusicBrainz"))
            }
            for rel in releases.prefix(3) {
                let date = rel.date ?? rec.firstReleaseDate ?? ""
                out.append(MetaCandidate(
                    title: rec.title, artist: artist, album: rel.title ?? "",
                    year: String(date.prefix(4)), genre: "",
                    coverURL: URL(string: "https://coverartarchive.org/release/\(rel.id)/front-1200"),
                    thumbURL: URL(string: "https://coverartarchive.org/release/\(rel.id)/front-250"),
                    source: "MusicBrainz"))
            }
        }
        return out
    }

    // MARK: Обложка

    static func downloadCover(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 1000 else {
            throw URLError(.badServerResponse)
        }
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.92) {
            return jpeg
        }
        throw URLError(.cannotDecodeContentData)
    }
}
