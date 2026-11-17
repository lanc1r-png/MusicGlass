import Foundation
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
                if !t.isEmpty { self?.onTitle?(t) }
            }
        }
    }
}

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: UIImage?
    @Published private(set) var shuffleOn = false
    @Published var repeatMode: RepeatMode = .off
    /// Текст ошибки воспроизведения (недоступный трек или станция, нет сети).
    @Published var playbackError: String?
    /// true, если сейчас играет радиостанция (прямой эфир).
    @Published private(set) var isLive = false
    /// Название песни из эфира радио, если станция его передаёт.
    @Published private(set) var liveTitle: String?

    let clock = PlayerClock()

    private let player = AVPlayer()
    private weak var library: LibraryStore?
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: AnyCancellable?
    private let metadataReader = LiveMetadataReader()
    private var metadataOutput: AVPlayerItemMetadataOutput?

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
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
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
    }

    func attach(_ library: LibraryStore) {
        self.library = library
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
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
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
        guard let i = currentIndex else { return }
        if isLive {
            guard queue.count > 1 else { return }
            currentIndex = i > 0 ? i - 1 : queue.count - 1
            loadCurrent(autoplay: true)
            return
        }
        if clock.currentTime > 3 || i == 0 {
            seek(to: 0)
        } else {
            currentIndex = i - 1
            loadCurrent(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        guard !isLive else { return }
        let t = max(0, seconds)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTime = t
        updateNowPlaying()
    }

    // MARK: Внутреннее

    private func loadCurrent(autoplay: Bool) {
        guard let track = currentTrack else {
            pause()
            return
        }

        let isRadio = RadioID.isRadio(track)
        let isOnline = OnlineID.isOnline(track)

        // Откуда играть: радиостанция, онлайн-трек (Audius) или файл.
        let url: URL
        let localURL: URL?
        if isRadio {
            guard let station = RadioCatalog.shared.info(for: track),
                  let u = URL(string: station.streamURL) else {
                pause()
                playbackError = "Не удалось открыть станцию."
                return
            }
            url = u
            localURL = nil
        } else if isOnline {
            guard let u = AudiusAPI.streamURL(trackID: OnlineID.audiusID(of: track)) else {
                pause()
                return
            }
            url = u
            localURL = nil
        } else if let u = library?.url(for: track) {
            url = u
            localURL = u
        } else {
            pause()
            return
        }

        playbackError = nil
        isLive = isRadio
        liveTitle = nil
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isRadio

        let item = AVPlayerItem(url: url)

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

        player.replaceCurrentItem(with: item)

        let failMessage: String
        if isRadio {
            failMessage = "Станция недоступна. Выберите другую."
        } else if isOnline {
            failMessage = "Не удалось воспроизвести трек. Проверьте интернет или выберите другой: он мог стать недоступным."
        } else {
            failMessage = "Не удалось открыть файл."
        }

        // Ошибка загрузки (трек недоступен, нет сети)
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                Task { @MainActor in self?.handleFailure(message: failMessage) }
            }

        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackEnded() }
        }

        clock.currentTime = 0
        clock.duration = track.duration
        artwork = nil
        if autoplay {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()

        Task {
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
            if self.currentTrack?.id == track.id {
                self.artwork = img
                self.updateNowPlaying()
            }
        }
    }

    private func setLiveTitle(_ title: String) {
        liveTitle = title
        updateNowPlaying()
    }

    private func handleFailure(message: String) {
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
        } else {
            next()
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        clock.currentTime = seconds
        if !isLive, let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - clock.duration) > 1 {
            clock.duration = d
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
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(art)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
