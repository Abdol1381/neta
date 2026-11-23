import Foundation
import AVFoundation

/// Plays the call's downlink audio streamed from the Android phone (16 kHz mono s16le, 20 ms chunks).
/// A small jitter buffer (~80 ms) smooths Wi-Fi timing; if latency builds up, old audio is dropped
/// so the call stays live.
final class CallAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var attached = false
    private(set) var running = false
    private var playing = false
    private var queued = 0
    private var pending: [AVAudioPCMBuffer] = []

    private static let prebuffer = 4      // 80 ms before starting playback
    private static let maxQueued = 12     // ~240 ms; beyond that drop to keep latency low

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            dlog("audio session \(error)")
        }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        do {
            try engine.start()
        } catch {
            dlog("audio engine \(error)")
            return
        }
        running = true
        playing = false
        queued = 0
        pending.removeAll()
    }

    func stop() {
        guard running else { return }
        node.stop()
        engine.stop()
        running = false
        playing = false
        queued = 0
        pending.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Main thread.
    func enqueue(_ data: Data) {
        guard running else { return }
        let n = data.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        if !playing {
            pending.append(buf)
            if pending.count >= Self.prebuffer {
                pending.forEach(schedule)
                pending.removeAll()
                node.play()
                playing = true
            }
            return
        }
        if queued >= Self.maxQueued { return } // too far behind: skip to stay real-time
        schedule(buf)
    }

    private func schedule(_ buf: AVAudioPCMBuffer) {
        queued += 1
        node.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.queued = max(0, self.queued - 1)
                // Ran dry: rebuild the jitter buffer before resuming.
                if self.queued == 0 && self.running { self.playing = false; self.node.pause() }
            }
        }
    }
}
