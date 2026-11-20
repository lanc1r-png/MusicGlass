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

/// Короткий стабильный хэш строки для имён файлов кэша (FNV-1a).
func stableFileHash(_ s: String) -> String {
    var h: UInt64 = 1469598103934665603
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 1099511628211
    }
    return String(h, radix: 36)
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

    /// Кэш в памяти с лимитом (~80 МБ), стоимость — объём картинки в байтах.
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()
    private let lock = NSLock()
    /// Номер правки обложки для каждого трека: после записи тегов меняется только он.
    private var revisions: [String: Int] = [:]
    /// Запросы, которые уже идут: одна и та же обложка не декодируется дважды.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Готовые уменьшенные обложки на диске: после перезапуска не нужно снова читать их из файлов.
    private let diskDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Несколько размеров сводятся к трём, чтобы одна обложка не хранилась в семи вариантах.
    static func bucket(_ maxSize: CGFloat) -> Int {
        if maxSize <= 200 { return 200 }
        if maxSize <= 600 { return 600 }
        return 1000
    }

    private func memoryKey(_ trackID: String, _ bucket: Int) -> String {
        let rev = lock.withLock { revisions[trackID] ?? 0 }
        return "\(trackID)|\(bucket)|\(rev)"
    }

    /// Мгновенная проверка памяти без обращения к диску (чтобы обложка не мигала заглушкой).
    func cached(for track: Track, maxSize: CGFloat) -> UIImage? {
        cache.object(forKey: memoryKey(track.id, Self.bucket(maxSize)) as NSString)
    }

    /// Обложка трека изменилась (записаны теги).
    func invalidate(trackID: String) {
        lock.withLock { revisions[trackID, default: 0] += 1 }
    }

    /// Удаляет из кэша файлы, которые не обновлялись больше 60 дней (обложки, логотипы радио, тексты, списки станций).
    /// Нужные снова появятся при первом показе.
    func pruneDiskCache(olderThanDays days: Double = 60) {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let limit = Date().addingTimeInterval(-days * 86400)
        for name in ["Artwork", "RadioCovers", "Lyrics", "RadioLists"] {
            let dir = caches.appendingPathComponent(name, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files {
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if date < limit { try? fm.removeItem(at: f) }
            }
        }
    }

    func image(for track: Track, url: URL, maxSize: CGFloat) async -> UIImage? {
        let bucket = Self.bucket(maxSize)
        let mKey = memoryKey(track.id, bucket)
        if let hit = cache.object(forKey: mKey as NSString) { return hit }

        let (task, isNew) = lock.withLock { () -> (Task<UIImage?, Never>, Bool) in
            if let running = inFlight[mKey] { return (running, false) }
            let t = Task<UIImage?, Never>.detached(priority: .userInitiated) { [self] in
                await self.load(track: track, url: url, bucket: bucket, memoryKey: mKey)
            }
            inFlight[mKey] = t
            return (t, true)
        }
        let result = await task.value
        if isNew { lock.withLock { inFlight[mKey] = nil } }
        return result
    }

    private func load(track: Track, url: URL, bucket: Int, memoryKey: String) async -> UIImage? {
        // Дата изменения файла входит в ключ на диске: после правки тегов обложка обновится сама.
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let name = stableFileHash("\(track.id)|\(bucket)|\(Int(modified))")
        let file = diskDir.appendingPathComponent(name + ".jpg")
        let noArt = diskDir.appendingPathComponent(name + ".none")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            let ready = await img.byPreparingForDisplay() ?? img
            store(ready, memoryKey)
            return ready
        }
        if FileManager.default.fileExists(atPath: noArt.path) { return nil }

        let asset = AVURLAsset(url: url)
        // Если теги прочитать не удалось (временный сбой), метку «обложки нет» не ставим.
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = try? await item.load(.dataValue),
              let full = UIImage(data: data) else {
            FileManager.default.createFile(atPath: noArt.path, contents: Data())
            return nil
        }
        let longest = max(full.size.width, full.size.height)
        let scale = min(1, CGFloat(bucket) / max(longest, 1))
        let target = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let thumb = await full.byPreparingThumbnail(ofSize: target) ?? full
        store(thumb, memoryKey)
        if let jpg = thumb.jpegData(compressionQuality: 0.85) {
            try? jpg.write(to: file, options: .atomic)
        }
        return thumb
    }

    private func store(_ img: UIImage, _ key: String) {
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        cache.setObject(img, forKey: key as NSString, cost: cost)
    }
}

// MARK: - Хранилище библиотеки

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = [] {
        didSet { scheduleRebuild() }
    }
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    /// Показывается только при первом сканировании или когда пользователь сам нажал «Обновить».
    @Published private(set) var isScanning = false
    /// Номер правки обложки по трекам: после записи тегов обновляется только обложка этого трека.
    @Published private(set) var artworkRevisions: [String: Int] = [:]

    func artworkRevision(for trackID: String) -> Int { artworkRevisions[trackID] ?? 0 }

    /// Быстрый доступ к трекам по id (для избранного и своих категорий).
    private(set) var trackIDs: Set<String> = []
    private(set) var byID: [String: Track] = [:]

    static let localID = "local"
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var scanning = false
    private var groupGeneration = 0

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
    private var tracksFile: URL { supportDir.appendingPathComponent("tracks.json") }

    init() {
        // Сохранённая медиатека читается не на главном потоке, затем идёт сканирование.
        isScanning = true
        let file = tracksFile
        Task {
            let saved = await Task.detached(priority: .userInitiated) { () -> [Track] in
                guard let data = try? Data(contentsOf: file),
                      let t = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
                return t
            }.value
            if self.tracks.isEmpty, !saved.isEmpty { self.tracks = saved }
            await self.rescan()
        }
    }

    func url(for track: Track) -> URL? {
        guard track.folderID == Self.localID else { return nil }
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
        ArtworkLoader.shared.invalidate(trackID: trackID)
        artworkRevisions[trackID, default: 0] += 1
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

        let existing = byID.isEmpty
            ? Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            : byID
        let found = await LibraryScanner.scan(folderID: Self.localID, root: root, existing: existing)
        // Сортировка не на главном потоке.
        let all = await Task.detached(priority: .userInitiated) {
            found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
        if all != tracks {
            tracks = all
            saveTracks()
        }
    }

    // Служебное

    /// Альбомы и исполнители пересобираются не на главном потоке.
    /// Если медиатека успела измениться ещё раз, устаревший результат отбрасывается.
    private func scheduleRebuild() {
        groupGeneration += 1
        let gen = groupGeneration
        let snapshot = tracks
        Task {
            let g = await Task.detached(priority: .userInitiated) {
                LibraryStore.computeGroups(snapshot)
            }.value
            guard gen == self.groupGeneration else { return }
            self.byID = g.byID
            self.trackIDs = Set(g.byID.keys)
            self.albums = g.albums
            self.artists = g.artists
        }
    }

    private struct Groups: Sendable {
        let byID: [String: Track]
        let albums: [Album]
        let artists: [Artist]
    }

    nonisolated private static func computeGroups(_ tracks: [Track]) -> Groups {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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
        let albums = buckets.map { key, group -> Album in
            let sorted = group.sorted {
                let a = $0.relativePath.isEmpty ? $0.title : $0.relativePath
                let b = $1.relativePath.isEmpty ? $1.title : $1.relativePath
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            let names = Set(sorted.map { $0.artist })
            let artist = names.count == 1 ? sorted[0].artist : "Разные исполнители"
            return Album(id: key, title: sorted[0].album, artist: artist, tracks: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let artists = Dictionary(grouping: tracks, by: { $0.artist }).map { name, group -> Artist in
            // Ключ сортировки собирается один раз на трек, а не на каждое сравнение.
            let sorted = group.map { ($0.album + "\u{1}" + $0.title, $0) }
                .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
                .map { $0.1 }
            return Artist(id: name, name: name, tracks: sorted)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return Groups(byID: byID, albums: albums, artists: artists)
    }

    private func saveTracks() {
        if let data = try? JSONEncoder().encode(tracks) { try? data.write(to: tracksFile, options: .atomic) }
    }
}
