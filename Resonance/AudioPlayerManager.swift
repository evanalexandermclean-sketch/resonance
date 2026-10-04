import Foundation
import AVFoundation
import MediaPlayer
import Combine

final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int? = nil
    @Published var isPlaying = false
    @Published var progress: Double = 0 // 0...1
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isShuffle = false
    @Published var repeatOne = false

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupAudioSession()
        setupTimeObserver()
        setupRemoteCommands()
        setupInterruptions()
    }

    // MARK: - Queue control (Spotify-like)

    func play(_ track: Track, in context: [Track]? = nil) {
        if let context {
            queue = context
            currentIndex = context.firstIndex(of: track) ?? 0
        } else {
            if let idx = queue.firstIndex(of: track) {
                currentIndex = idx
            } else {
                queue.insert(track, at: 0)
                currentIndex = 0
            }
        }
        playCurrent()
    }

    func play(queue newQueue: [Track], startingAt index: Int = 0) {
        guard !newQueue.isEmpty else { return }
        queue = isShuffle ? newQueue.shuffled() : newQueue
        currentIndex = min(index, queue.count - 1)
        playCurrent()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    func next() {
        guard let i = currentIndex else { return }
        if repeatOne { seek(to: 0); resume(); return }
        let nextIdx = i + 1
        if nextIdx < queue.count {
            currentIndex = nextIdx
            playCurrent()
        } else {
            // End of queue: stop like Spotify (no auto-repeat unless enabled)
            pause()
        }
    }

    func previous() {
        guard let i = currentIndex else { return }
        if elapsed > 3 {
            seek(to: 0) // restart like Spotify
            return
        }
        if i > 0 { currentIndex = i - 1; playCurrent() }
        else { seek(to: 0) }
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        seek(to: fraction * duration)
    }

    // MARK: - Internals

    private func playCurrent() {
        guard let track = currentTrack else { return }
        let item = AVPlayerItem(url: track.streamURL)
        // Forward DLNA auth headers if needed in future via AVURLAsset options
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        duration = track.duration > 0 ? track.duration : 0
        updateNowPlayingInfo()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let item = self.player.currentItem else { return }
            let el = time.seconds.isFinite ? time.seconds : 0
            let dur = item.duration.seconds.isFinite ? item.duration.seconds : (self.currentTrack?.duration ?? 0)
            self.elapsed = el
            if dur > 0 {
                self.duration = dur
                self.progress = el / dur
            }
            // Auto-next
            if let _ = self.player.currentItem, self.player.rate > 0 { self.isPlaying = true }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            self?.next()
        }
    }

    private func setupInterruptions() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            if type == .began { self?.pause() }
        }
    }

    // MARK: - Lock screen / Control Center

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let ev = e as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: ev.positionTime); return .success
            }
            return .commandFailed
        }
    }

    private func updateNowPlayingInfo() {
        guard let t = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // Async artwork (DLNA albumArtURI or local)
        if let url = t.artworkURL {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    var full = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    full[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = full
                }
            }.resume()
        }
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
