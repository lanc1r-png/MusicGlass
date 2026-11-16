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

@MainActor
final class PlayerStore: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: UIImage?
    @Published private(set) var shuffleOn = false
    @Published var repeatMode: RepeatMode = .off
    /// Текст ошибки воспроизведения (недоступный трек, нет сети).
    @Published var playbackError: String?

    let clock = PlayerClock()

    private let player = AVPlayer()
    private weak var library: LibraryStore?
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: AnyCancellable?

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
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
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadCurrent(autoplay: true)
        } else {
            seek(to: 0)
            pause()
        }
    }

    func previous() {
        guard let i = currentIndex else { return }
        if clock.currentTime > 3 || i == 0 {
            seek(to: 0)
        } else {
            currentIndex = i - 1
            loadCurrent(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
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

        // Откуда играть: из сети (Audius) или из файла.
        let url: URL
        let localURL: URL?
        let isOnline = OnlineID.isOnline(track)
        if isOnline {
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
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        // Ошибка загрузки (трек недоступен, нет сети)
        statusObserver = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard status == .failed else { return }
                Task { @MainActor in self?.handleFailure(online: isOnline) }
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
            } else {
                img = await OnlineArtwork.image(OnlineCatalog.shared.info(for: track)?.artworkLarge)
            }
            if self.currentTrack?.id == track.id {
                self.artwork = img
                self.updateNowPlaying()
            }
        }
    }

    private func handleFailure(online: Bool) {
        player.pause()
        isPlaying = false
        playbackError = online
            ? "Не удалось воспроизвести трек. Проверьте интернет или выберите другой: он мог стать недоступным."
            : "Не удалось открыть файл."
        updateNowPlaying()
    }

    private func trackEnded() {
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
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - clock.duration) > 1 {
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
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(art)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
