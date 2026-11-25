import Foundation
import AVFoundation
import os

/// Plays the call's downlink audio streamed from the Android phone (16 kHz mono s16le, 20 ms chunks).
///
/// - Voice-call audio session (`.playAndRecord` + `.voiceChat`): plays on the earpiece like a phone
///   call (speaker / AirPods on request) with Apple's voice processing.
/// - Continuous jitter buffer: a pull-based source node reads from a ring buffer and plays silence
///   when nothing has arrived, so network hiccups never stop the engine (no stop/start clicks).
/// - Self-healing: iOS silently stops an `AVAudioEngine` on route / configuration changes,
///   interruptions and media-server resets. Each of those restarts it here (and the app's watchdog
///   checks every 2 s), so the call audio never just goes quiet.
final class CallAudioPlayer {
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private(set) var running = false
    /// true while CallKit owns (activates/deactivates) the audio session.
    private var managed = false
    private var speaker = false
    private var voiceProcessingSet = false
    private var observers: [NSObjectProtocol] = []
    private(set) var restarts = 0

    // Ring buffer shared with the real-time render thread.
    private static let capacity = 16_000 * 2              // 2 s
    private static let target = 16_000 * 20 / 100        // 200 ms before playback starts
    private static let refill = 16_000 * 10 / 100        // 100 ms after an underrun
    private static let maxLatency = 16_000 * 70 / 100    // > 700 ms queued: skip ahead
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: CallAudioPlayer.capacity)
    private var readIdx = 0
    private var writeIdx = 0
    private var count = 0
    private var primed = false
    private var startedPlaying = false
    private var underruns = 0
    private var peak: Int32 = 0
    private var lock = os_unfair_lock()

    init() {
        ring.initialize(repeating: 0, count: Self.capacity)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running, (n.object as? AVAudioEngine) === self.engine else { return }
            self.recover("audio configuration changed")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { dlog("call audio: interrupted"); return }
            self.recover("interruption ended")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running else { return }
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let out = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            dlog("call audio route: \(out) (reason \(raw))")
            // Something (another app, a category change) moved the call to the loudspeaker.
            if !self.speaker && !self.managed && reason == .categoryChange && out.contains("Speaker") {
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
            }
            if !self.engine.isRunning { self.recover("route changed") }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            dlog("call audio: media services reset")
            self.rebuildEngine()
            if self.running { self.running = false; self.start(managedByCallKit: self.managed) }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        ring.deallocate()
    }

    /// - Parameter managedByCallKit: CallKit already activated the voice session (the native call UI
    ///   controls earpiece / speaker / AirPods); otherwise a voice session is set up here.
    func start(managedByCallKit: Bool = false) {
        if running && managed == managedByCallKit {
            if !engine.isRunning { recover("start: engine was stopped") }
            return
        }
        if running { stop() }
        managed = managedByCallKit
        if !managedByCallKit { activateSession() }
        resetBuffer()
        attachSource()
        // Apple's voice processing (as in phone calls); needs microphone access, so it is optional.
        if !voiceProcessingSet {
            do { try engine.outputNode.setVoiceProcessingEnabled(true) } catch { dlog("voice processing off: \(error)") }
            voiceProcessingSet = true
        }
        if !startEngine() {
            dlog("audio engine failed — retrying without voice processing")
            try? engine.outputNode.setVoiceProcessingEnabled(false)
            if !startEngine() {
                rebuildEngine()
                attachSource()
                if !startEngine() { dlog("audio engine could not start"); return }
            }
        }
        running = true
        if !managed { try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none) }
    }

    func stop() {
        guard running else { return }
        engine.stop()
        running = false
        resetBuffer()
        if !managed { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        managed = false
        speaker = false
    }

    /// Called by the app's watchdog every 2 s while a call is up.
    func ensureRunning() {
        guard running, !engine.isRunning else { return }
        recover("watchdog: engine was stopped")
    }

    /// Routes the call audio to the iPhone's loudspeaker (true) or back to the earpiece / headset.
    func setSpeaker(_ on: Bool) {
        speaker = on
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    /// One line for the diagnostics log.
    var debugLine: String {
        os_unfair_lock_lock(&lock)
        let ms = count * 1000 / 16_000
        let u = underruns
        let p = Int(peak) * 100 / 32768
        peak = 0
        os_unfair_lock_unlock(&lock)
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let vol = AVAudioSession.sharedInstance().outputVolume
        return "engine \(engine.isRunning ? "on" : "OFF") · level \(p)% · volume \(Int(vol * 100))% · buffer \(ms)ms · underruns \(u) · restarts \(restarts) · \(managed ? "callkit" : "own") · \(out)"
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
                let a = abs(Int32(v))
                if a > peak { peak = a }
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

    // MARK: - Private

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try s.setActive(true)
            try? s.overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            dlog("audio session \(error)")
        }
    }

    private func attachSource() {
        guard source == nil else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl -> OSStatus in
            self.render(frameCount, abl)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    private func startEngine() -> Bool {
        engine.prepare()
        do { try engine.start(); return true } catch { dlog("audio engine \(error)"); return false }
    }

    /// A fresh engine (after a media-server reset, or when the old one refuses to start).
    private func rebuildEngine() {
        engine.stop()
        if let s = source { engine.detach(s) }
        source = nil
        engine = AVAudioEngine()
        voiceProcessingSet = false
    }

    /// Restarts the engine (and our own session) after iOS stopped it.
    private func recover(_ why: String) {
        guard running else { return }
        restarts += 1
        dlog("call audio: restarting (\(why))")
        if !managed { activateSession() }
        if engine.isRunning { return }
        if startEngine() { return }
        rebuildEngine()
        attachSource()
        if !voiceProcessingSet {
            try? engine.outputNode.setVoiceProcessingEnabled(true)
            voiceProcessingSet = true
        }
        if !startEngine() {
            try? engine.outputNode.setVoiceProcessingEnabled(false)
            if !startEngine() { dlog("call audio: restart failed, the watchdog tries again") }
        }
    }

    private func resetBuffer() {
        os_unfair_lock_lock(&lock)
        readIdx = 0
        writeIdx = 0
        count = 0
        primed = false
        startedPlaying = false
        underruns = 0
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
            if count == 0 { primed = false; underruns += 1 } // underrun: rebuild a short cushion
        }
        os_unfair_lock_unlock(&lock)
        while i < frames { out[i] = 0; i += 1 }
        for b in buffers.dropFirst() {
            if let d = b.mData { memcpy(d, out, frames * MemoryLayout<Float>.size) }
        }
    }
}
