import Foundation
import AVFoundation
import UIKit

// MARK: - Модели

struct Track: Identifiable, Codable, Hashable {
    let id: String
    let folderID: String
    let relativePath: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

struct MusicFolder: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var bookmark: Data
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
}

struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let tracks: [Track]
}

// MARK: - Сканер файлов

enum LibraryScanner {
    static let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf"]

    static func listFiles(in root: URL) -> [URL] {
        var result: [URL] = []
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in en {
            if extensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    static func scan(folderID: String, root: URL, existing: [String: Track]) async -> [Track] {
        let files = listFiles(in: root)
        let rootPath = root.standardizedFileURL.path
        var out: [Track] = []
        for file in files {
            var rel = file.standardizedFileURL.path
            if rel.hasPrefix(rootPath) { rel.removeFirst(rootPath.count) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            let id = folderID + "/" + rel
            if let old = existing[id] {
                out.append(old)
                continue
            }
            out.append(await readTrack(id: id, folderID: folderID, rel: rel, file: file))
        }
        return out
    }

    private static func readTrack(id: String, folderID: String, rel: String, file: URL) async -> Track {
        let asset = AVURLAsset(url: file)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        var seconds: Double = 0
        if let d = try? await asset.load(.duration) {
            let s = CMTimeGetSeconds(d)
            if s.isFinite { seconds = s }
        }
        let title = await text(.commonIdentifierTitle, in: items) ?? file.deletingPathExtension().lastPathComponent
        let artist = await text(.commonIdentifierArtist, in: items) ?? "Неизвестный артист"
        let album = await text(.commonIdentifierAlbumName, in: items) ?? "Неизвестный альбом"
        return Track(id: id, folderID: folderID, relativePath: rel,
                     title: title, artist: artist, album: album, duration: seconds)
    }

    private static func text(_ id: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Обложки

final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSString, UIImage>()

    func image(for track: Track, url: URL, maxSize: CGFloat) async -> UIImage? {
        let key = "\(track.id)|\(Int(maxSize))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue),
              let full = UIImage(data: data) else { return nil }
        let longest = max(full.size.width, full.size.height)
        let scale = min(1, maxSize / max(longest, 1))
        let target = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let thumb = await full.byPreparingThumbnail(ofSize: target) ?? full
        cache.setObject(thumb, forKey: key)
        return thumb
    }
}

// MARK: - Хранилище библиотеки

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var folders: [MusicFolder] = []
    @Published private(set) var tracks: [Track] = [] {
        didSet { rebuildGroups() }
    }
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var isScanning = false

    static let localID = "local"
    private var roots: [String: URL] = [:]

    private var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private var foldersFile: URL { supportDir.appendingPathComponent("folders.json") }
    private var tracksFile: URL { supportDir.appendingPathComponent("tracks.json") }

    init() {
        load()
        resolveFolders()
        Task { await rescan() }
    }

    func url(for track: Track) -> URL? {
        roots[track.folderID]?.appendingPathComponent(track.relativePath)
    }

    // Папки

    func addFolders(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            let path = url.standardizedFileURL.path
            let duplicate = roots.values.contains { $0.standardizedFileURL.path == path }
            guard !duplicate, let data = try? url.bookmarkData() else {
                url.stopAccessingSecurityScopedResource()
                continue
            }
            let folder = MusicFolder(id: UUID().uuidString, name: url.lastPathComponent, bookmark: data)
            folders.append(folder)
            roots[folder.id] = url
        }
        saveFolders()
        Task { await rescan() }
    }

    func removeFolder(_ folder: MusicFolder) {
        roots[folder.id]?.stopAccessingSecurityScopedResource()
        roots[folder.id] = nil
        folders.removeAll { $0.id == folder.id }
        tracks = tracks.filter { $0.folderID != folder.id }
        saveFolders()
        saveTracks()
    }

    // Сканирование

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let existing = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sources: [(String, URL)] = []
        if let docs = roots[Self.localID] { sources.append((Self.localID, docs)) }
        for f in folders {
            if let u = roots[f.id] { sources.append((f.id, u)) }
        }

        var all: [Track] = []
        for (id, url) in sources {
            let found = await LibraryScanner.scan(folderID: id, root: url, existing: existing)
            all.append(contentsOf: found)
            tracks = all
        }
        all.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        tracks = all
        saveTracks()
    }

    // Служебное

    private func resolveFolders() {
        roots[Self.localID] = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for folder in folders {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            roots[folder.id] = url
            if stale, let fresh = try? url.bookmarkData(),
               let i = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[i].bookmark = fresh
                saveFolders()
            }
        }
    }

    private func rebuildGroups() {
        var buckets: [String: [Track]] = [:]
        for t in tracks {
            let dir = (t.relativePath as NSString).deletingLastPathComponent
            buckets[t.album + "|" + t.folderID + "/" + dir, default: []].append(t)
        }
        albums = buckets.map { key, group -> Album in
            let sorted = group.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            let names = Set(sorted.map { $0.artist })
            let artist = names.count == 1 ? sorted[0].artist : "Разные исполнители"
            return Album(id: key, title: sorted[0].album, artist: artist, tracks: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        artists = Dictionary(grouping: tracks, by: { $0.artist }).map { name, group -> Artist in
            let sorted = group.sorted {
                ($0.album + $0.relativePath).localizedStandardCompare($1.album + $1.relativePath) == .orderedAscending
            }
            return Artist(id: name, name: name, tracks: sorted)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func load() {
        if let data = try? Data(contentsOf: foldersFile),
           let f = try? JSONDecoder().decode([MusicFolder].self, from: data) { folders = f }
        if let data = try? Data(contentsOf: tracksFile),
           let t = try? JSONDecoder().decode([Track].self, from: data) { tracks = t }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: foldersFile) }
    }

    private func saveTracks() {
        if let data = try? JSONEncoder().encode(tracks) { try? data.write(to: tracksFile) }
    }
}
