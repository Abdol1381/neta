import Foundation
import AVFoundation
import os

/// Plays the call's downlink audio streamed from the Android phone (16 kHz mono s16le, 20 ms chunks).
///
/// - Voice-call audio session (`.playAndRecord` + `.voiceChat`): plays on the earpiece like a phone
///   call (speaker / AirPods on request) with Apple's voice processing.
/// - Continuous jitter buffer: a pull-based source node reads from a ring buffer and plays silence
///   when nothing has arrived, so network hiccups never stop the engine (no stop/start clicks).
///   Latency is kept around 120 ms; if audio piles up it skips ahead to stay live.
final class CallAudioPlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private(set) var running = false
    /// true while CallKit owns (activates/deactivates) the audio session.
    private var managed = false

    // Ring buffer shared with the real-time render thread.
    private static let capacity = 16_000 * 2              // 2 s
    private static let target = 16_000 * 12 / 100        // 120 ms before playback starts
    private static let refill = 16_000 * 6 / 100          // 60 ms after an underrun
    private static let maxLatency = 16_000 * 40 / 100     // > 400 ms queued: skip ahead
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: CallAudioPlayer.capacity)
    private var readIdx = 0
    private var writeIdx = 0
    private var count = 0
    private var primed = false
    private var startedOnce = false
    private var lock = os_unfair_lock()

    init() {
        ring.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        ring.deallocate()
    }

    /// - Parameter managedByCallKit: CallKit already activated the voice session (the native call UI
    ///   controls earpiece / speaker / AirPods); otherwise a voice session is set up here.
    func start(managedByCallKit: Bool = false) {
        if running && managed == managedByCallKit { return }
        if running { stop() }
        managed = managedByCallKit
        if !managedByCallKit {
            let s = AVAudioSession.sharedInstance()
            do {
                try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
                try s.setActive(true)
                try? s.overrideOutputAudioPort(.none)
            } catch {
                dlog("audio session \(error)")
            }
        }
        resetBuffer()
        if source == nil {
            let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl -> OSStatus in
                self.render(frameCount, abl)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        // Apple's voice processing (as in phone calls); needs microphone access, so it is optional.
        if !startedOnce {
            do { try engine.outputNode.setVoiceProcessingEnabled(true) } catch { dlog("voice processing off: \(error)") }
            startedOnce = true
        }
        do {
            try engine.start()
        } catch {
            dlog("audio engine \(error) — retrying without voice processing")
            try? engine.outputNode.setVoiceProcessingEnabled(false)
            do { try engine.start() } catch { dlog("audio engine \(error)"); return }
        }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.stop()
        running = false
        resetBuffer()
        if !managed { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        managed = false
    }

    /// Routes the call audio to the iPhone's loudspeaker (true) or back to the earpiece / headset.
    func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    /// Any thread. 16 kHz mono s16le.
    func enqueue(_ data: Data) {
        guard running else { return }
        let n = data.count / 2
        guard n > 0 else { return }
        os_unfair_lock_lock(&lock)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                ring[writeIdx] = Float(v) / 32768
                writeIdx = (writeIdx + 1) % Self.capacity
                if count < Self.capacity { count += 1 } else { readIdx = (readIdx + 1) % Self.capacity }
            }
        }
        if count > Self.maxLatency {
            // Fell behind (e.g. after a Wi-Fi stall): drop the oldest audio, keep it live.
            let drop = count - Self.target
            readIdx = (readIdx + drop) % Self.capacity
            count -= drop
        }
        os_unfair_lock_unlock(&lock)
    }

    private func resetBuffer() {
        os_unfair_lock_lock(&lock)
        readIdx = 0
        writeIdx = 0
        count = 0
        primed = false
        startedPlaying = false
        os_unfair_lock_unlock(&lock)
    }

    /// Real-time render thread.
    private func render(_ frameCount: AVAudioFrameCount, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = Int(frameCount)
        os_unfair_lock_lock(&lock)
        if !primed && count >= (startedPlaying ? Self.refill : Self.target) { primed = true; startedPlaying = true }
        var i = 0
        if primed {
            let take = min(frames, count)
            while i < take {
                out[i] = ring[readIdx]
                readIdx = (readIdx + 1) % Self.capacity
                i += 1
            }
            count -= take
            if count == 0 { primed = false } // underrun: rebuild a short cushion
        }
        os_unfair_lock_unlock(&lock)
        while i < frames { out[i] = 0; i += 1 }
        for b in buffers.dropFirst() {
            if let d = b.mData { memcpy(d, out, frames * MemoryLayout<Float>.size) }
        }
    }

    private var startedPlaying = false
}
