import Foundation
import AVFoundation

/// "Always connected": keeps the app running in the background by playing an inaudible audio loop
/// (mixed with other audio, so music and other apps are not interrupted). That keeps the link to the
/// Android phone open, so calls and SMS arrive instantly instead of waiting for a Bluetooth wake.
final class BackgroundKeeper {
    private var player: AVAudioPlayer?
    /// Returns false while a call or call audio owns the audio session. The keeper must never
    /// re-apply its media-playback category then: that would move the call to the loudspeaker.
    var mayTouchSession: () -> Bool = { true }
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { player?.isPlaying == true }

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            // After a phone call, Siri, an alarm… resume the loop.
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            guard let self, self.mayTouchSession() else { return }
            self.resume()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.player = nil
            guard let self, self.mayTouchSession() else { return }
            self.start()
        })
    }

    /// Must first be called while the app is in the foreground (iOS does not allow starting audio
    /// from the background).
    func start() {
        guard mayTouchSession() else { return }
        configureSession()
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWav)
            player?.numberOfLoops = -1
            player?.volume = 0
            player?.prepareToPlay()
        }
        if player?.isPlaying != true { player?.play() }
        dlog("keeper running: \(isRunning)")
    }

    /// Re-applies the session and continues the loop (e.g. after the call audio session ended).
    func resume() {
        guard player != nil else { return }
        start()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    /// One second of silence, 8 kHz mono 16-bit PCM WAV.
    private static let silentWav: Data = {
        let sampleRate: UInt32 = 8000
        let samples = Int(sampleRate)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2))
        d.append(Data(count: samples * 2))
        return d
    }()
}
