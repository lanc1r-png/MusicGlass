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
    /// true, если источник — отдельный файл, а не папка
    var isFile: Bool? = nil
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

    static func scan(folderID: String, root: URL, isFile: Bool, existing: [String: Track]) async -> [Track] {
        if isFile {
            let id = folderID + "/"
            if let old = existing[id] { return [old] }
            return [await readTrack(id: id, folderID: folderID, rel: "", file: root)]
        }

        let files = listFiles(in: root)
        let rootPath = root.standardizedFileURL.path
        var out: [Track] = []
        var fresh: [(id: String, rel: String, file: URL)] = []
        for file in files {
            var rel = file.standardizedFileURL.path
            if rel.hasPrefix(rootPath) { rel.removeFirst(rootPath.count) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            let id = folderID + "/" + rel
            if let old = existing[id] {
                out.append(old)
            } else {
                fresh.append((id, rel, file))
            }
        }
        guard !fresh.isEmpty else { return out }

        // Новые файлы читаем параллельно, но не больше 6 одновременно.
        let read = await withTaskGroup(of: Track.self, returning: [Track].self) { group in
            var result: [Track] = []
            var next = 0
            while next < min(6, fresh.count) {
                let f = fresh[next]
                next += 1
                group.addTask { await readTrack(id: f.id, folderID: folderID, rel: f.rel, file: f.file) }
            }
            while let t = await group.next() {
                result.append(t)
                if next < fresh.count {
                    let f = fresh[next]
                    next += 1
                    group.addTask { await readTrack(id: f.id, folderID: folderID, rel: f.rel, file: f.file) }
                }
            }
            return result
        }
        out.append(contentsOf: read)
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

    /// Готовые уменьшенные обложки на диске: после перезапуска не нужно снова читать их из файлов.
    private let diskDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func clear() {
        cache.removeAllObjects()
    }

    func image(for track: Track, url: URL, maxSize: CGFloat) async -> UIImage? {
        // Дата изменения файла входит в ключ: после правки тегов обложка обновится сама.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let keyString = "\(track.id)|\(Int(maxSize))|\(Int(modified))"
        let key = keyString as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let name = Self.hash(keyString)
        let file = diskDir.appendingPathComponent(name + ".jpg")
        let noArt = diskDir.appendingPathComponent(name + ".none")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            let ready = await img.byPreparingForDisplay() ?? img
            cache.setObject(ready, forKey: key)
            return ready
        }
        if FileManager.default.fileExists(atPath: noArt.path) { return nil }

        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue),
              let full = UIImage(data: data) else {
            FileManager.default.createFile(atPath: noArt.path, contents: Data())
            return nil
        }
        let longest = max(full.size.width, full.size.height)
        let scale = min(1, maxSize / max(longest, 1))
        let target = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let thumb = await full.byPreparingThumbnail(ofSize: target) ?? full
        cache.setObject(thumb, forKey: key)
        if let jpg = thumb.jpegData(compressionQuality: 0.85) {
            try? jpg.write(to: file, options: .atomic)
        }
        return thumb
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

// MARK: - Хранилище библиотеки

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var folders: [MusicFolder] = []
    @Published private(set) var tracks: [Track] = [] {
        didSet { rebuildGroups() }
    }
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    /// Показывается только при первом сканировании или когда пользователь сам нажал «Обновить».
    @Published private(set) var isScanning = false
    @Published private(set) var artworkVersion = 0

    /// Быстрый доступ к трекам по id (для избранного и своих категорий).
    private(set) var trackIDs: Set<String> = []
    private(set) var byID: [String: Track] = [:]

    static let localID = "local"
    private var roots: [String: URL] = [:]
    private var scanning = false

    /// Папка «Музыка» в «Файлах».
    var musicFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Музыка", isDirectory: true)
    }

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
        guard let root = roots[track.folderID] else { return nil }
        return track.relativePath.isEmpty ? root : root.appendingPathComponent(track.relativePath)
    }

    /// Применяет новые данные к треку после записи тегов в файл.
    func applyMetadata(trackID: String, title: String, artist: String, album: String) {
        guard let i = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var t = tracks[i]
        if !title.isEmpty { t.title = title }
        if !artist.isEmpty { t.artist = artist }
        if !album.isEmpty { t.album = album }
        tracks[i] = t
        artworkVersion += 1
        saveTracks()
    }

    // Сканирование

    /// Пересканирует папки. Если ничего не изменилось, экраны не перерисовываются.
    func rescan(userInitiated: Bool = false) async {
        guard !scanning else { return }
        scanning = true
        let showProgress = userInitiated || tracks.isEmpty
        if showProgress { isScanning = true }
        defer {
            scanning = false
            if isScanning { isScanning = false }
        }

        let existing = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sources: [(String, URL, Bool)] = []
        if let docs = roots[Self.localID] { sources.append((Self.localID, docs, false)) }
        for f in folders {
            if let u = roots[f.id] { sources.append((f.id, u, f.isFile == true)) }
        }

        let firstLoad = tracks.isEmpty
        var all: [Track] = []
        for (id, url, isFile) in sources {
            let found = await LibraryScanner.scan(folderID: id, root: url, isFile: isFile, existing: existing)
            all.append(contentsOf: found)
            // При самом первом сканировании показываем песни по мере нахождения.
            if firstLoad && !found.isEmpty { tracks = all }
        }
        all.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if all != tracks {
            tracks = all
            saveTracks()
        }
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
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        trackIDs = Set(byID.keys)
        var buckets: [String: [Track]] = [:]
        for t in tracks {
            let key: String
            if t.relativePath.isEmpty {
                key = t.album + "|files"
            } else {
                let dir = (t.relativePath as NSString).deletingLastPathComponent
                key = t.album + "|" + t.folderID + "/" + dir
            }
            buckets[key, default: []].append(t)
        }
        albums = buckets.map { key, group -> Album in
            let sorted = group.sorted {
                let a = $0.relativePath.isEmpty ? $0.title : $0.relativePath
                let b = $1.relativePath.isEmpty ? $1.title : $1.relativePath
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            let names = Set(sorted.map { $0.artist })
            let artist = names.count == 1 ? sorted[0].artist : "Разные исполнители"
            return Album(id: key, title: sorted[0].album, artist: artist, tracks: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        artists = Dictionary(grouping: tracks, by: { $0.artist }).map { name, group -> Artist in
            let sorted = group.sorted {
                ($0.album + $0.title).localizedStandardCompare($1.album + $1.title) == .orderedAscending
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
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: foldersFile, options: .atomic) }
    }

    private func saveTracks() {
        if let data = try? JSONEncoder().encode(tracks) { try? data.write(to: tracksFile, options: .atomic) }
    }
}
