import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Off-trail audio (Phase 4): silent within the threshold, then a continuous
/// tone whose pitch rises the further you stray. Hysteresis stops it chattering
/// at the boundary. A synthesised sine via AVAudioSourceNode so pitch is
/// continuously adjustable.
final class HikeAudio {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double = 44_100

    // Render-thread state (read in the audio callback).
    private var phase: Double = 0
    private var targetFrequency: Double = 0     // 0 = silent
    private var currentFrequency: Double = 0
    private var targetAmplitude: Float = 0
    private var currentAmplitude: Float = 0

    // Tone shaping.
    private let onThreshold: Double = 100        // start beyond this many metres
    private let offThreshold: Double = 90        // stop below this (hysteresis)
    private let spanMeters: Double = 500         // distance over which pitch sweeps
    private let minHz: Double = 300
    private let maxHz: Double = 1_200
    private var isSounding = false
    private var configured = false

    func startEngineIfNeeded() {
        guard !configured else { return }
        configureSession()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let step = 1.0 / self.sampleRate
            for frame in 0..<Int(frameCount) {
                // Glide toward targets so changes aren't clicky.
                self.currentFrequency += (self.targetFrequency - self.currentFrequency) * 0.001
                self.currentAmplitude += (self.targetAmplitude - self.currentAmplitude) * 0.0005
                let value = sin(2 * .pi * self.phase) * Double(self.currentAmplitude)
                self.phase += self.currentFrequency * step
                if self.phase >= 1 { self.phase -= 1 }
                let sample = Float(value)
                for buffer in buffers {
                    let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
                    ptr[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
        configured = true
        try? engine.start()
    }

    /// Update the tone for the current off-trail distance.
    func update(offTrackMeters: Double) {
        startEngineIfNeeded()
        if isSounding {
            if offTrackMeters < offThreshold { isSounding = false }
        } else {
            if offTrackMeters > onThreshold { isSounding = true }
        }
        guard isSounding else {
            targetAmplitude = 0
            targetFrequency = 0
            return
        }
        let over = min(max(offTrackMeters - onThreshold, 0), spanMeters)
        let frac = over / spanMeters
        targetFrequency = minHz + frac * (maxHz - minHz)
        targetAmplitude = 0.18
    }

    func stop() {
        targetAmplitude = 0
        targetFrequency = 0
        isSounding = false
        engine.stop()
        configured = false
    }

    private func configureSession() {
        #if !targetEnvironment(macCatalyst)
        // no-op placeholder; category set below applies on both
        #endif
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }
}
