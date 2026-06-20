// ============================================================================
// Blockfall — GameAudio
// Fully synthesized audio: no asset files. Uses AVAudioEngine + AVAudioPlayerNode
// with manually-filled AVAudioPCMBuffer(s). All synthesis is PCM Float32 at
// 44 100 Hz stereo. Safe to call from main thread; all methods become no-ops if
// the engine failed to initialize (headless / no-audio environment).
//
// NOTE FOR LEAD: add `.linkedFramework("AVFoundation")` to the BlockfallApp
// target in Package.swift — it is not yet listed there.
// ============================================================================
import Foundation
import AVFoundation

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

final class GameAudio {

    /// Sound-effect identifiers.
    enum Sfx {
        case mine           // soft thud — mining in progress
        case place          // low wooden click — placing a block
        case breakBlock     // brighter crumble/pop — block destroyed
        case step           // quiet soft tap — footstep
        case jump           // tiny upward chirp
        case craft          // two-note ding
        case befriend       // happy little arpeggio
        case questComplete  // cheerful fanfare
    }

    // -----------------------------------------------------------------------
    // MARK: Init
    // -----------------------------------------------------------------------

    init() {
        setupEngine()
    }

    // -----------------------------------------------------------------------
    // MARK: Lifecycle
    // -----------------------------------------------------------------------

    /// Start the engine and begin looping background music.
    func start() {
        guard let engine else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            // Audio unavailable at runtime — stay silent.
            return
        }
        if musicEnabled { startMusic() }
    }

    /// Stop everything.
    func stop() {
        musicNodes.forEach { $0.stop() }
        sfxPool.forEach { $0.stop() }
        engine?.stop()
    }

    // -----------------------------------------------------------------------
    // MARK: Controls
    // -----------------------------------------------------------------------

    func setMusicEnabled(_ on: Bool) {
        musicEnabled = on
        guard engine?.isRunning == true else { return }
        if on { startMusic() } else { musicNodes.forEach { $0.stop() } }
    }

    func setSfxEnabled(_ on: Bool) {
        sfxEnabled = on
    }

    // -----------------------------------------------------------------------
    // MARK: SFX playback
    // -----------------------------------------------------------------------

    func play(_ sfx: Sfx) {
        guard sfxEnabled, let engine, engine.isRunning else { return }
        guard let buffer = sfxBuffers[sfx] else { return }

        // Grab an idle node from the pool (or reuse the least-recently-used).
        let node = idleSfxNode()
        node.scheduleBuffer(buffer, completionHandler: nil)
        node.play()
    }

    // -----------------------------------------------------------------------
    // MARK: Private state
    // -----------------------------------------------------------------------

    private var engine: AVAudioEngine?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    private var musicEnabled = true
    private var sfxEnabled   = true

    // Music: multiple layered player nodes (one per voice / chord layer).
    private var musicNodes: [AVAudioPlayerNode] = []
    private var musicMixer: AVAudioMixerNode?

    // SFX: small pool of reusable player nodes.
    private let poolSize = 8
    private var sfxPool: [AVAudioPlayerNode] = []
    private var sfxMixer: AVAudioMixerNode?
    private var poolIndex = 0

    // Pre-generated SFX buffers keyed by Sfx case.
    private var sfxBuffers: [Sfx: AVAudioPCMBuffer] = [:]

    // -----------------------------------------------------------------------
    // MARK: Engine setup
    // -----------------------------------------------------------------------

    private func setupEngine() {
        // Wrap everything so a headless / no-audio environment doesn't crash.
        // If we can't get a usable output format we bail and leave engine = nil.
        let eng = AVAudioEngine()
        let mainMixer = eng.mainMixerNode

        // outputNode.inputFormat(forBus:) can be zero-channel in headless CI.
        let outFormat = eng.outputNode.inputFormat(forBus: 0)
        guard outFormat.channelCount > 0 else { return }

        // --- Music mixer ---
        let mMix = AVAudioMixerNode()
        mMix.outputVolume = 0.22   // gentle background level
        eng.attach(mMix)
        eng.connect(mMix, to: mainMixer, format: outFormat)
        musicMixer = mMix

        // --- SFX mixer ---
        let sMix = AVAudioMixerNode()
        sMix.outputVolume = 0.55
        eng.attach(sMix)
        eng.connect(sMix, to: mainMixer, format: outFormat)
        sfxMixer = sMix

        // --- Music nodes (4 voices for layered pad) ---
        for _ in 0 ..< 4 {
            let node = AVAudioPlayerNode()
            eng.attach(node)
            eng.connect(node, to: mMix, format: format)
            musicNodes.append(node)
        }

        // --- SFX pool ---
        for _ in 0 ..< poolSize {
            let node = AVAudioPlayerNode()
            eng.attach(node)
            eng.connect(node, to: sMix, format: format)
            sfxPool.append(node)
        }

        // Pre-generate all SFX buffers now (synchronous; done once at startup).
        buildAllSfxBuffers()

        // Prepare engine but don't start yet — start() does that.
        eng.prepare()

        self.engine = eng
    }

    // -----------------------------------------------------------------------
    // MARK: Music synthesis
    // -----------------------------------------------------------------------
    //
    // Approach: a slow chord progression (C maj → A min → F maj → G maj)
    // rendered as layered sine+triangle pad voices with long ADSR envelopes.
    // Each chord is ~4 seconds; the whole 16-second loop is scheduled to repeat.
    // Four player nodes play the four chord tones of each chord simultaneously,
    // each carrying a different oscillator shape for warmth.
    //
    // Voice layout (per chord block, 16 sec total):
    //   Node 0 — root (sine, octave 3)
    //   Node 1 — third (triangle, octave 4)
    //   Node 2 — fifth (sine, octave 4)
    //   Node 3 — root+octave (triangle, octave 4, softer)

    private func startMusic() {
        // Build music buffers if not already done.
        guard musicBuffers.isEmpty else {
            scheduleMusic(); return
        }
        buildMusicBuffers()
        scheduleMusic()
    }

    private var musicBuffers: [[AVAudioPCMBuffer]] = []   // [nodeIndex][chordIndex]

    private func buildMusicBuffers() {
        // Chord progression: C3, Am3, F3, G3 — frequencies for root notes.
        // Notes: C3=130.81, A2=110, F3=174.61, G3=196
        let chordRoots: [Float] = [130.81, 110.0, 174.61, 196.0]
        // Major/minor intervals (ratio above root): root, third, fifth, octave
        // C maj: 1, 5/4, 3/2, 2  |  A min: 1, 6/5, 3/2, 2  |  F maj: same as Cmaj  |  G maj: same as Cmaj
        let intervalSets: [[Float]] = [
            [1.0, 5.0/4, 3.0/2, 2.0],   // C major
            [1.0, 6.0/5, 3.0/2, 2.0],   // A minor
            [1.0, 5.0/4, 3.0/2, 2.0],   // F major
            [1.0, 5.0/4, 3.0/2, 2.0],   // G major
        ]
        let chordDuration: Double = 4.0   // seconds per chord
        let sr = Float(format.sampleRate)
        let chordSamples = Int(sr * Float(chordDuration))
        let shapes: [OscShape] = [.sine, .triangle, .sine, .triangle]
        let voiceVolumes: [Float] = [0.35, 0.25, 0.30, 0.18]

        // musicBuffers[voiceIdx] = array of 4 chord buffers (one per chord)
        musicBuffers = Array(repeating: [], count: 4)

        for voiceIdx in 0 ..< 4 {
            for chordIdx in 0 ..< 4 {
                let rootHz = chordRoots[chordIdx]
                let hz = rootHz * intervalSets[chordIdx][voiceIdx]
                let shape = shapes[voiceIdx]
                let vol   = voiceVolumes[voiceIdx]

                guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: AVAudioFrameCount(chordSamples)) else { continue }
                buf.frameLength = AVAudioFrameCount(chordSamples)

                guard let L = buf.floatChannelData?[0],
                      let R = buf.floatChannelData?[1] else { continue }

                let attackSamples  = Int(sr * 0.8)
                let releaseSamples = Int(sr * 1.2)

                for i in 0 ..< chordSamples {
                    // Envelope
                    let env: Float
                    if i < attackSamples {
                        env = Float(i) / Float(attackSamples)
                    } else if i > chordSamples - releaseSamples {
                        env = Float(chordSamples - i) / Float(releaseSamples)
                    } else {
                        env = 1.0
                    }
                    let t = Float(i) / sr
                    let phase = hz * t
                    let sample = vol * env * osc(shape, phase: phase)
                    L[i] = sample
                    R[i] = sample
                }
                applyFadeIO(L, R, samples: chordSamples, fadeLen: min(256, chordSamples / 8))
                musicBuffers[voiceIdx].append(buf)
            }
        }
    }

    private func scheduleMusic() {
        guard musicBuffers.count == 4 else { return }

        // Chain the 4 chords per voice into one big looping buffer per voice.
        let totalChordSamples: Int = musicBuffers[0].reduce(0) { $0 + Int($1.frameLength) }

        for voiceIdx in 0 ..< 4 {
            guard voiceIdx < musicNodes.count else { break }
            let node = musicNodes[voiceIdx]
            node.stop()

            guard let loopBuf = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: AVAudioFrameCount(totalChordSamples)) else { continue }
            loopBuf.frameLength = AVAudioFrameCount(totalChordSamples)

            guard let dstL = loopBuf.floatChannelData?[0],
                  let dstR = loopBuf.floatChannelData?[1] else { continue }

            var offset = 0
            for chordBuf in musicBuffers[voiceIdx] {
                guard let srcL = chordBuf.floatChannelData?[0],
                      let srcR = chordBuf.floatChannelData?[1] else { continue }
                let n = Int(chordBuf.frameLength)
                for i in 0 ..< n {
                    dstL[offset + i] = srcL[i]
                    dstR[offset + i] = srcR[i]
                }
                offset += n
            }

            node.scheduleBuffer(loopBuf, at: nil, options: .loops, completionHandler: nil)
            node.play()
        }
    }

    // -----------------------------------------------------------------------
    // MARK: SFX synthesis
    // -----------------------------------------------------------------------
    //
    // Each SFX is synthesized once and cached. All use short ADSR tone or
    // tone+noise envelopes. Fade in/out applied to avoid clicks.

    private func buildAllSfxBuffers() {
        sfxBuffers[.mine]          = makeMineBuffer()
        sfxBuffers[.place]         = makePlaceBuffer()
        sfxBuffers[.breakBlock]    = makeBreakBlockBuffer()
        sfxBuffers[.step]          = makeStepBuffer()
        sfxBuffers[.jump]          = makeJumpBuffer()
        sfxBuffers[.craft]         = makeCraftBuffer()
        sfxBuffers[.befriend]      = makeBefriendBuffer()
        sfxBuffers[.questComplete] = makeQuestCompleteBuffer()
    }

    /// mine — soft thud: low sine tone + filtered noise burst, ~120 ms
    private func makeMineBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.12
        return synthesize(duration: dur) { i, sr in
            let t = Float(i) / sr
            let env = envelope(t, a: 0.005, d: 0.04, s: 0.4, sLen: 0.05, r: 0.03, total: dur)
            let tone  = 0.5 * sin(2 * .pi * 90 * t)
            let noise = 0.25 * whitenoise()
            return env * (tone + noise)
        }
    }

    /// place — low wooden click: short sine pop at ~200 Hz, ~80 ms
    private func makePlaceBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.08
        return synthesize(duration: dur) { i, sr in
            let t = Float(i) / sr
            let env = envelope(t, a: 0.002, d: 0.02, s: 0.3, sLen: 0.03, r: 0.03, total: dur)
            let hz  = Float(200) * pow(0.5, t * 8)   // slight pitch drop for woodiness
            let tone = 0.7 * sin(2 * .pi * hz * t)
            let noise = 0.1 * whitenoise()
            return env * (tone + noise)
        }
    }

    /// breakBlock — brighter crumble/pop: mid-freq tone + noise burst, ~180 ms
    private func makeBreakBlockBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.18
        return synthesize(duration: dur) { i, sr in
            let t = Float(i) / sr
            let env = envelope(t, a: 0.003, d: 0.05, s: 0.35, sLen: 0.06, r: 0.07, total: dur)
            let hz  = Float(400) * pow(0.4, t * 4)
            let tone  = 0.4 * osc(.triangle, phase: hz * t)
            let noise = 0.45 * whitenoise()
            return env * (tone + noise)
        }
    }

    /// step — quiet soft tap: very short low tone, ~60 ms
    private func makeStepBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.06
        return synthesize(duration: dur) { i, sr in
            let t = Float(i) / sr
            let env = envelope(t, a: 0.002, d: 0.015, s: 0.2, sLen: 0.01, r: 0.03, total: dur)
            let tone  = 0.45 * sin(2 * .pi * 120 * t)
            let noise = 0.2 * whitenoise()
            return env * (tone + noise) * 0.6
        }
    }

    /// jump — tiny upward chirp: sine swept 300→600 Hz, ~140 ms
    private func makeJumpBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.14
        var phase: Float = 0
        return synthesize(duration: dur) { i, sr in
            let t = Float(i) / sr
            let env = envelope(t, a: 0.005, d: 0.04, s: 0.5, sLen: 0.05, r: 0.05, total: dur)
            let hz  = 300 + 300 * (t / dur)          // sweep upward
            phase  += hz / sr
            return env * 0.55 * sin(2 * .pi * phase)
        }
    }

    /// craft — two-note ding: C5 then E5, each ~200 ms, 400 ms total
    private func makeCraftBuffer() -> AVAudioPCMBuffer? {
        let noteDur: Float = 0.20
        let total:   Float = noteDur * 2
        let notes:   [Float] = [523.25, 659.25]   // C5, E5
        return synthesize(duration: total) { i, sr in
            let t = Float(i) / sr
            let noteIdx = Int(t / noteDur)
            let nt = t - Float(noteIdx) * noteDur
            let hz = notes[min(noteIdx, notes.count - 1)]
            let env = envelope(nt, a: 0.005, d: 0.05, s: 0.6, sLen: 0.08, r: 0.07, total: noteDur)
            return env * 0.5 * (sin(2 * .pi * hz * nt) + 0.3 * sin(2 * .pi * hz * 2 * nt))
        }
    }

    /// befriend — happy arpeggio: C5 E5 G5 C6, each ~160 ms, 640 ms total
    private func makeBefriendBuffer() -> AVAudioPCMBuffer? {
        let noteDur: Float = 0.16
        let total:   Float = noteDur * 4
        let notes:   [Float] = [523.25, 659.25, 783.99, 1046.50]   // C5 E5 G5 C6
        return synthesize(duration: total) { i, sr in
            let t = Float(i) / sr
            let noteIdx = Int(t / noteDur)
            let nt = t - Float(noteIdx) * noteDur
            let hz = notes[min(noteIdx, notes.count - 1)]
            let env = envelope(nt, a: 0.004, d: 0.03, s: 0.7, sLen: 0.08, r: 0.05, total: noteDur)
            return env * 0.45 * (osc(.triangle, phase: hz * nt) + 0.25 * sin(2 * .pi * hz * 2 * nt))
        }
    }

    /// questComplete — cheerful fanfare: C5 E5 G5 (together) then C6 accent, ~800 ms
    private func makeQuestCompleteBuffer() -> AVAudioPCMBuffer? {
        let total: Float = 0.80
        // Chord: C5+E5+G5 for 0.5 s, then C6 accent for 0.3 s
        let chordEnd: Float = 0.50
        let chordNotes: [Float] = [523.25, 659.25, 783.99]
        let accentHz:    Float  = 1046.50
        return synthesize(duration: total) { i, sr in
            let t = Float(i) / sr
            var sample: Float = 0
            if t < chordEnd {
                let env = envelope(t, a: 0.01, d: 0.05, s: 0.8, sLen: chordEnd - 0.1, r: 0.05, total: chordEnd)
                for hz in chordNotes {
                    sample += env * (0.22 * sin(2 * .pi * hz * t) + 0.08 * osc(.triangle, phase: hz * t))
                }
            } else {
                let nt  = t - chordEnd
                let dur = total - chordEnd
                let env = envelope(nt, a: 0.005, d: 0.03, s: 0.7, sLen: dur - 0.08, r: 0.05, total: dur)
                sample = env * 0.55 * (sin(2 * .pi * accentHz * nt) + 0.2 * osc(.triangle, phase: accentHz * nt))
            }
            return sample
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Synthesis helpers
    // -----------------------------------------------------------------------

    private enum OscShape { case sine, triangle }

    @inline(__always)
    private func osc(_ shape: OscShape, phase: Float) -> Float {
        switch shape {
        case .sine:
            return sin(2 * .pi * phase)
        case .triangle:
            let p = phase.truncatingRemainder(dividingBy: 1.0)
            let q = p < 0 ? p + 1 : p
            return q < 0.5 ? 4 * q - 1 : 3 - 4 * q
        }
    }

    /// Simple ADSR-ish envelope. `sLen` is the sustain duration in seconds.
    @inline(__always)
    private func envelope(_ t: Float, a: Float, d: Float, s: Float, sLen: Float, r: Float, total: Float) -> Float {
        if t < 0 { return 0 }
        if t < a { return t / a }                               // attack
        let afterA = t - a
        if afterA < d { return 1.0 - (1.0 - s) * (afterA / d) } // decay
        let afterD = afterA - d
        if afterD < sLen { return s }                           // sustain
        let afterS = afterD - sLen
        if afterS < r { return s * (1.0 - afterS / r) }        // release
        return 0
    }

    @inline(__always)
    private func whitenoise() -> Float {
        return Float.random(in: -1 ... 1)
    }

    /// Allocate a stereo buffer, call `generator(sampleIndex, sampleRate)` for each sample, apply
    /// a short click-prevention fade at both ends, return the buffer.
    private func synthesize(duration: Float,
                            generator: (Int, Float) -> Float) -> AVAudioPCMBuffer? {
        let sr = Float(format.sampleRate)
        let n  = Int(sr * duration)
        guard n > 0 else { return nil }

        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)

        guard let L = buf.floatChannelData?[0],
              let R = buf.floatChannelData?[1] else { return nil }

        for i in 0 ..< n {
            let s = generator(i, sr)
            L[i] = s
            R[i] = s
        }

        applyFadeIO(L, R, samples: n, fadeLen: min(64, n / 8))
        return buf
    }

    /// Apply a linear fade-in and fade-out of `fadeLen` samples to prevent clicks.
    private func applyFadeIO(_ L: UnsafeMutablePointer<Float>,
                             _ R: UnsafeMutablePointer<Float>,
                             samples: Int, fadeLen: Int) {
        guard fadeLen > 0 else { return }
        for i in 0 ..< min(fadeLen, samples) {
            let g = Float(i) / Float(fadeLen)
            L[i] *= g; R[i] *= g
        }
        for i in 0 ..< min(fadeLen, samples) {
            let idx = samples - 1 - i
            let g   = Float(i) / Float(fadeLen)
            L[idx] *= g; R[idx] *= g
        }
    }

    // -----------------------------------------------------------------------
    // MARK: SFX node pool
    // -----------------------------------------------------------------------

    /// Return an idle node from the round-robin pool.
    /// Stops any currently playing audio on the node so it's ready for a new buffer.
    /// The caller is responsible for scheduling a buffer and calling play().
    private func idleSfxNode() -> AVAudioPlayerNode {
        let node = sfxPool[poolIndex % poolSize]
        poolIndex = (poolIndex + 1) % poolSize
        node.stop()   // clear any in-progress playback; play() called by the caller
        return node
    }
}
