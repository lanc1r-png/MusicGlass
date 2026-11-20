import Foundation
import SwiftUI
import AVFoundation
import MediaPlayer
import UIKit
import Combine

enum RepeatMode { case off, all, one }

/// Время вынесено отдельно, чтобы списки не перерисовывались дважды в секунду.
final class PlayerClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

/// Лёгкое состояние «что играет»: на него подписаны строки списков,
/// поэтому они не перерисовываются от каждой мелочи в плеере (обложка, ошибки, эфир).
@MainActor
final class PlaybackStatus: ObservableObject {
    static let shared = PlaybackStatus()
    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false

    func update(id: String?, playing: Bool) {
        if currentID != id { currentID = id }
        if isPlaying != playing { isPlaying = playing }
    }
}

/// Ссылка на плеер для кнопок и списков без подписки на его изменения.
extension EnvironmentValues {
    @Entry var playerControl: PlayerStore? = nil
}

/// Окно ошибки воспроизведения. Подписано на плеер только оно само,
/// поэтому большие экраны (радио, онлайн) не перерисовываются от каждой мелочи.
struct PlaybackErrorAlert: ViewModifier {
    @EnvironmentObject var player: PlayerStore

    func body(content: Content) -> some View {
        content.alert("Не удалось воспроизвести",
                      isPresented: Binding(
                        get: { player.playbackError != nil },
                        set: { if !$0 { player.playbackError = nil } }
                      )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.playbackError ?? "")
        }
    }
}

extension View {
    func playbackErrorAlert() -> some View { modifier(PlaybackErrorAlert()) }
}

/// Настройка плавного перехода между треками (0 = выключен, треки идут без паузы).
enum PlaybackSettings {
    static let crossfadeKey = "crossfadeSeconds"
}

/// Читает название песни, которое радиостанция передаёт в потоке (ICY).
final class LiveMetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onTitle: ((String) -> Void)?

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        guard let item = groups.flatMap({ $0.items })
            .first(where: { $0.identifier == .icyMetadataStreamTitle }) else { return }
        Task { [weak self] in
            if let s = try? await item.load(.stringValue) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                // Колбэк читается и вызывается только на главном потоке.
                if !t.isEmpty { await MainActor.run { self?.onTitle?(t) } }
            }
        }
    }
}

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var queue: [Track] = [] { didSet { syncStatus() } }
    @Published private(set) var currentIndex: Int? { didSet { syncStatus() } }
    @Published private(set) var isPlaying = false { didSet { syncStatus() } }
    @Published private(set) var artwork: UIImage? {
        // Картинка для экрана блокировки создаётся один раз на обложку, а не при каждой паузе.
        didSet { lockScreenArtwork = artwork.map { Self.makeArtwork($0) } }
    }
    private var lockScreenArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    @Published private(set) var shuffleOn = false
    @Published var repeatMode: RepeatMode = .off {
        didSet { cancelPrepared() }
    }
    /// Текст ошибки воспроизведения (недоступный трек или станция, нет сети).
    @Published var playbackError: String?
    /// true, если сейчас играет радиостанция (прямой эфир).
    @Published private(set) var isLive = false
    /// Название песни из эфира радио, если станция его передаёт.
    @Published private(set) var liveTitle: String?

    let clock = PlayerClock()

    // Два плеера: пока играет основной, следующий трек заранее загружается во второй.
    // Так переход идёт без паузы или с плавным затуханием.
    private var player = AVPlayer()
    private var standby = AVPlayer()
    private var prepared: (index: Int, trackID: String)?
    private var fading = false
    private var fadeTask: Task<Void, Never>?

    private weak var library: LibraryStore?
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private weak var timeObserverOwner: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: AnyCancellable?
    private let metadataReader = LiveMetadataReader()
    private var metadataOutput: AVPlayerItemMetadataOutput?

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    private var crossfade: Double {
        max(0, UserDefaults.standard.double(forKey: PlaybackSettings.crossfadeKey))
    }

    /// Что показывать в заголовке (для радио это песня или название станции).
    var displayTitle: String {
        guard let t = currentTrack else { return "Не играет" }
        if isLive, let lt = liveTitle { return parsedLive(lt).title }
        return t.title
    }

    var displaySubtitle: String {
        guard let t = currentTrack else { return " " }
        if isLive {
            if let lt = liveTitle {
                if let artist = parsedLive(lt).artist { return artist }
                return t.title
            }
            return t.artist
        }
        return t.artist
    }

    private func parsedLive(_ s: String) -> (title: String, artist: String?) {
        if let r = s.range(of: " - ") {
            let a = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let t = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty && !t.isEmpty { return (t, a) }
        }
        return (s, nil)
    }

    init() {
        configureAudioSession()
        setupRemoteCommands()
        observeInterruptions()
        installTimeObserver()
    }

    func attach(_ library: LibraryStore) {
        self.library = library
    }

    private func syncStatus() {
        PlaybackStatus.shared.update(id: currentTrack?.id, playing: isPlaying)
    }

    // MARK: Управление

    func play(_ tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        originalQueue = tracks
        if shuffleOn {
            var rest = tracks
            let first = rest.remove(at: index)
            queue = [first] + rest.shuffled()
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }
        loadCurrent(autoplay: true)
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleOn = true
        play(tracks, startAt: Int.random(in: 0..<tracks.count))
    }

    func toggleShuffle() {
        shuffleOn.toggle()
        cancelPrepared()
        guard let current = currentTrack else { return }
        let base = originalQueue.isEmpty ? queue : originalQueue
        if shuffleOn {
            var rest = base
            rest.removeAll { $0.id == current.id }
            queue = [current] + rest.shuffled()
            currentIndex = 0
        } else {
            queue = base
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func resume() {
        guard currentTrack != nil else { return }
        player.volume = 1
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        stopFade()
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        guard let i = currentIndex else { return }
        if i + 1 < queue.count {
            currentIndex = i + 1
            loadCurrent(autoplay: true)
        } else if (repeatMode == .all || isLive), !queue.isEmpty {
            currentIndex = 0
            loadCurrent(autoplay: true)
        } else {
            seek(to: 0)
            pause()
        }
    }

    func previous() {
        guard currentIndex != nil else { return }
        if isLive || clock.currentTime <= 3 {
            skipBack()
        } else {
            seek(to: 0)
        }
    }

    /// Всегда на предыдущий трек (для свайпа по мини-плееру).
    func skipBack() {
        guard let i = currentIndex else { return }
        if i > 0 {
            currentIndex = i - 1
            loadCurrent(autoplay: true)
        } else if (repeatMode == .all || isLive), queue.count > 1 {
            currentIndex = queue.count - 1
            loadCurrent(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: Double) {
        guard !isLive else { return }
        stopFade()
        let t = max(0, seconds)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTime = t
        updateNowPlaying()
    }

    // MARK: Очередь

    /// Треки после текущего.
    var upcoming: [Track] {
        guard let i = currentIndex, i + 1 < queue.count else { return [] }
        return Array(queue[(i + 1)...])
    }

    /// Включает трек из очереди по его месту в общем списке.
    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent(autoplay: true)
    }

    /// Перестановка внутри «Далее» (индексы считаются от первого трека после текущего).
    func moveUpcoming(from source: IndexSet, to destination: Int) {
        let base = (currentIndex ?? -1) + 1
        guard base <= queue.count else { return }
        var up = Array(queue[base...])
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[..<base]) + up
        if !shuffleOn { originalQueue = queue }
        cancelPrepared()
    }

    func removeUpcoming(at offset: Int) {
        let index = (currentIndex ?? -1) + 1 + offset
        guard queue.indices.contains(index), index != currentIndex else { return }
        let removed = queue.remove(at: index)
        originalQueue.removeAll { $0.id == removed.id }
        cancelPrepared()
    }

    /// Ставит треки сразу после текущего.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let i = currentIndex, !queue.isEmpty else {
            play(tracks, startAt: 0)
            return
        }
        queue.insert(contentsOf: tracks, at: i + 1)
        if let oi = originalQueue.firstIndex(where: { $0.id == queue[i].id }) {
            originalQueue.insert(contentsOf: tracks, at: oi + 1)
        } else {
            originalQueue.append(contentsOf: tracks)
        }
        cancelPrepared()
        Haptics.tap()
    }

    /// Добавляет треки в конец очереди.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard currentIndex != nil, !queue.isEmpty else {
            play(tracks, startAt: 0)
            return
        }
        queue.append(contentsOf: tracks)
        originalQueue.append(contentsOf: tracks)
        cancelPrepared()
        Haptics.tap()
    }

    // MARK: Источник трека

    private func source(for track: Track) -> (url: URL, localURL: URL?)? {
        if RadioID.isRadio(track) {
            guard let s = RadioCatalog.shared.info(for: track), let u = URL(string: s.streamURL) else { return nil }
            return (u, nil)
        }
        if OnlineID.isOnline(track) {
            guard let u = AudiusAPI.streamURL(trackID: OnlineID.audiusID(of: track)) else { return nil }
            return (u, nil)
        }
        guard let u = library?.url(for: track) else { return nil }
        return (u, u)
    }

    private func failMessage(for track: Track) -> String {
        if RadioID.isRadio(track) { return "Станция недоступна. Выберите другую." }
        if OnlineID.isOnline(track) {
            return "Не удалось воспроизвести трек. Проверьте интернет или выберите другой: он мог стать недоступным."
        }
        return "Не удалось открыть файл."
    }

    // MARK: Загрузка трека

    private func loadCurrent(autoplay: Bool) {
        stopFade()
        cancelPrepared()
        guard let track = currentTrack else {
            pause()
            return
        }
        let isRadio = RadioID.isRadio(track)
        guard let src = source(for: track) else {
            pause()
            if isRadio { playbackError = "Не удалось открыть станцию." }
            return
        }

        playbackError = nil
        isLive = isRadio
        liveTitle = nil
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isRadio

        let item = AVPlayerItem(url: src.url)
        if isRadio {
            let out = AVPlayerItemMetadataOutput(identifiers: nil)
            metadataReader.onTitle = { [weak self] title in
                Task { @MainActor in self?.setLiveTitle(title) }
            }
            out.setDelegate(metadataReader, queue: .main)
            item.add(out)
            metadataOutput = out
        } else {
            metadataOutput = nil
        }

        player.volume = 1
        player.replaceCurrentItem(with: item)
        observe(item, track: track)

        clock.currentTime = 0
        clock.duration = track.duration
        artwork = nil
        if autoplay {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
        loadArtwork(for: track, localURL: src.localURL)
    }

    private func observe(_ item: AVPlayerItem, track: Track) {
        let message = failMessage(for: track)
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                Task { @MainActor in self?.handleFailure(message: message) }
            }

        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackEnded() }
        }
    }

    private func loadArtwork(for track: Track, localURL: URL?) {
        let isRadio = RadioID.isRadio(track)
        // При быстром листании прошлая загрузка отменяется.
        artworkTask?.cancel()
        artworkTask = Task {
            let img: UIImage?
            if let localURL {
                img = await ArtworkLoader.shared.image(for: track, url: localURL, maxSize: 900)
            } else if isRadio {
                if let station = RadioCatalog.shared.info(for: track) {
                    img = await StationArt.cover(for: station, side: 900)
                } else {
                    img = nil
                }
            } else {
                img = await OnlineArtwork.image(OnlineCatalog.shared.info(for: track)?.artworkLarge)
            }
            if !Task.isCancelled, self.currentTrack?.id == track.id {
                self.artwork = img
                self.updateNowPlaying()
            }
        }
    }

    // MARK: Бесшовный переход и плавное затухание

    private func upcomingIndex() -> Int? {
        guard let i = currentIndex, repeatMode != .one, !isLive else { return nil }
        if i + 1 < queue.count { return i + 1 }
        if repeatMode == .all, queue.count > 1 { return 0 }
        return nil
    }

    /// Заранее загружает следующий трек во второй плеер.
    private func prepareNext() {
        guard prepared == nil, !fading, let ni = upcomingIndex() else { return }
        let t = queue[ni]
        guard !RadioID.isRadio(t), let src = source(for: t) else { return }
        standby.replaceCurrentItem(with: AVPlayerItem(url: src.url))
        standby.volume = 0
        standby.pause()
        prepared = (ni, t.id)
    }

    private func cancelPrepared() {
        guard prepared != nil else { return }
        prepared = nil
        if !fading {
            standby.pause()
            standby.replaceCurrentItem(with: nil)
        }
    }

    /// Переключается на заранее загруженный трек; при fade > 0 с плавным затуханием.
    private func transitionToPrepared(fade: Double) -> Bool {
        guard let p = prepared, queue.indices.contains(p.index), queue[p.index].id == p.trackID,
              standby.currentItem != nil else {
            cancelPrepared()
            return false
        }
        let track = queue[p.index]
        let old = player
        player = standby
        standby = old
        prepared = nil
        installTimeObserver()

        currentIndex = p.index
        isLive = false
        liveTitle = nil
        playbackError = nil
        metadataOutput = nil
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = true
        if let item = player.currentItem { observe(item, track: track) }

        clock.currentTime = 0
        clock.duration = track.duration
        player.volume = fade > 0 ? 0 : 1
        player.play()
        isPlaying = true
        artwork = nil
        updateNowPlaying()
        loadArtwork(for: track, localURL: library?.url(for: track))

        if fade > 0 {
            fading = true
            let incoming = player
            fadeTask = Task { @MainActor [weak self] in
                let steps = max(10, Int(fade * 20))
                for s in 1...steps {
                    try? await Task.sleep(nanoseconds: UInt64(fade / Double(steps) * 1_000_000_000))
                    if Task.isCancelled { return }
                    let k = Double(s) / Double(steps)
                    // Равномощная кривая: громкость не «проваливается» в середине.
                    incoming.volume = Float(sin(k * .pi / 2))
                    old.volume = Float(cos(k * .pi / 2))
                }
                self?.stopFade()
            }
        } else {
            old.pause()
            old.replaceCurrentItem(with: nil)
        }
        return true
    }

    /// Мгновенно завершает затухание: старый трек выключается, новый звучит в полную силу.
    private func stopFade() {
        fadeTask?.cancel()
        fadeTask = nil
        guard fading else { return }
        fading = false
        standby.pause()
        standby.replaceCurrentItem(with: nil)
        standby.volume = 1
        player.volume = 1
    }

    private func installTimeObserver() {
        if let o = timeObserver { timeObserverOwner?.removeTimeObserver(o) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // Колбэк уже приходит на главный поток, лишний переход не нужен.
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        timeObserverOwner = player
    }

    // MARK: Внутреннее

    private func setLiveTitle(_ title: String) {
        liveTitle = title
        updateNowPlaying()
    }

    private func handleFailure(message: String) {
        stopFade()
        player.pause()
        isPlaying = false
        playbackError = message
        updateNowPlaying()
    }

    private func trackEnded() {
        if isLive {
            handleFailure(message: "Станция прервала трансляцию. Попробуйте ещё раз или выберите другую.")
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            resume()
            return
        }
        // Следующий трек уже загружен: включаем его без паузы.
        if transitionToPrepared(fade: 0) { return }
        next()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        clock.currentTime = seconds
        guard !isLive else { return }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - clock.duration) > 1 {
            clock.duration = d
            // Уточнённая длина сразу уходит на экран блокировки.
            updateNowPlaying()
        }
        guard isPlaying, !fading else { return }
        let d = clock.duration
        guard d > 0 else { return }
        let remaining = d - seconds
        let fade = crossfade
        if remaining < fade + 12 { prepareNext() }
        if fade > 0, d > fade * 2 + 5, remaining <= fade, remaining > 0.5 {
            _ = transitionToPrepared(fade: remaining)
        }
    }

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    self.stopFade()
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self.resume()
                }
            }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlaying() {
        guard let t = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any]
        if isLive {
            info = [
                MPMediaItemPropertyTitle: displayTitle,
                MPMediaItemPropertyArtist: displaySubtitle,
                MPMediaItemPropertyAlbumTitle: t.title,
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
            ]
        } else {
            info = [
                MPMediaItemPropertyTitle: t.title,
                MPMediaItemPropertyArtist: t.artist,
                MPMediaItemPropertyAlbumTitle: t.album,
                MPMediaItemPropertyPlaybackDuration: clock.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTime,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
            ]
        }
        if let art = lockScreenArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
