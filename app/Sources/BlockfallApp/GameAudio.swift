// ============================================================================
// Blockfall — GameAudio
// Fully synthesized audio: no asset files. Uses AVAudioEngine + AVAudioPlayerNode
// with manually-filled AVAudioPCMBuffer(s). All synthesis is PCM Float32 at
// 44 100 Hz stereo. Safe to call from main thread; all methods become no-ops if
// the engine failed to initialize (headless / no-audio environment).
//
// NOTE FOR LEAD: add `.linkedFramework("AVFoundation")` to the BlockfallApp
// target in Package.swift — it is not yet listed there.
//
// PUBLIC API ADDITIONS vs original:
//   Sfx: + splash, pickup, openInventory, placeFail
//   func setAmbienceEnabled(_ on: Bool)
//   func setTimeOfDay(_ t: Float)   // 0.0 = midnight, 0.5 = noon, 1.0 = midnight
// ============================================================================
import Foundation
import AVFoundation

// ---------------------------------------------------------------------------
// MARK: - Public API
// ---------------------------------------------------------------------------

final class GameAudio {

    /// Sound-effect identifiers.
    enum Sfx {
        // --- original ---
        case mine           // soft thud — mining in progress
        case place          // low wooden click — placing a block
        case breakBlock     // brighter crumble/pop — block destroyed
        case step           // quiet soft tap — footstep
        case jump           // tiny upward chirp
        case craft          // two-note ding
        case befriend       // happy little arpeggio
        case questComplete  // cheerful fanfare
        // --- new ---
        case splash         // water entry — fizzy bubble whoosh
        case pickup         // item collected — bright sparkle ding
        case openInventory  // soft wooden drawer slide
        case placeFail      // dull thud — can't place here
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

    /// Start the engine and begin looping background music + ambience.
    func start() {
        guard let engine else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            // Audio unavailable at runtime — stay silent.
            return
        }
        if musicEnabled    { startMusic() }
        if ambienceEnabled { startAmbience() }
    }

    /// Stop everything.
    func stop() {
        musicNodes.forEach { $0.stop() }
        sfxPool.forEach    { $0.stop() }
        ambienceWindNode?.stop()
        birdTimer?.invalidate()
        birdTimer = nil
        trackTimer?.invalidate()
        trackTimer = nil
        engine?.stop()
    }

    // -----------------------------------------------------------------------
    // MARK: Controls
    // -----------------------------------------------------------------------

    func setMusicEnabled(_ on: Bool) {
        musicEnabled = on
        guard engine?.isRunning == true else { return }
        if on { startMusic() } else {
            musicNodes.forEach { $0.stop() }
            trackTimer?.invalidate()
            trackTimer = nil
        }
    }

    func setSfxEnabled(_ on: Bool) {
        sfxEnabled = on
    }

    /// Enable / disable the ambient wind + bird layer.
    func setAmbienceEnabled(_ on: Bool) {
        ambienceEnabled = on
        guard engine?.isRunning == true else { return }
        if on { startAmbience() } else {
            ambienceWindNode?.stop()
            birdTimer?.invalidate()
            birdTimer = nil
        }
    }

    /// Call each frame (or whenever time changes). t ∈ [0, 1]: 0/1 = midnight, 0.5 = noon.
    /// Picks the daytime vs evening music track and fades bird volume.
    func setTimeOfDay(_ t: Float) {
        let clampedT = max(0, min(1, t))
        let isDaytime = clampedT > 0.2 && clampedT < 0.8
        let targetTrackGroup: TrackGroup = isDaytime ? .day : .evening

        // Bird volume: louder at day, silent at night.
        let birdVol: Float
        if clampedT < 0.1 || clampedT > 0.9 {
            birdVol = 0
        } else if clampedT < 0.2 {
            birdVol = (clampedT - 0.1) / 0.1 * 0.25
        } else if clampedT > 0.8 {
            birdVol = (0.9 - clampedT) / 0.1 * 0.25
        } else {
            birdVol = 0.25
        }
        birdNode?.volume = birdVol

        if targetTrackGroup != currentTrackGroup {
            currentTrackGroup = targetTrackGroup
            // Cross-fade to the new group on the next natural track boundary
            // (we flag it so scheduleNextTrack picks the right group).
            // If music is running and we want an immediate feel, force a transition.
            if engine?.isRunning == true && musicEnabled {
                startMusic()
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: SFX playback (with ±pitch variation to avoid monotony)
    // -----------------------------------------------------------------------

    func play(_ sfx: Sfx) {
        guard sfxEnabled, let engine, engine.isRunning else { return }
        guard let buffer = sfxBuffers[sfx] else { return }

        let node = idleSfxNode()

        // Apply a tiny random pitch shift by adjusting the playback rate.
        // AVAudioPlayerNode doesn't expose rate directly; we accomplish it by
        // scheduling at a slightly varied sample-rate offset using a per-play
        // AVAudioPCMBuffer pitch-shift via a rate-scaled copy only for cases
        // where variation matters. We keep it simple: use a thin AVAudioUnitTimePitch
        // node per voice — BUT that would require re-wiring; instead we use a
        // lightweight approach: vary volume slightly + pitch via pitch node chain.
        // Simplest compile-correct approach: use the node's `rate` setter via
        // AVAudioPlayerNode scheduling with a slightly different format pitch.
        //
        // Actually the cleanest no-extra-node approach: build ±5% pitch variants
        // for the frequently-repeated sounds at startup, then pick one at random.

        let key = SfxVariantKey(sfx: sfx, variant: variantIndex(for: sfx))
        if let variantBuf = sfxVariantBuffers[key] {
            node.scheduleBuffer(variantBuf, completionHandler: nil)
        } else {
            node.scheduleBuffer(buffer, completionHandler: nil)
        }
        node.play()
    }

    // -----------------------------------------------------------------------
    // MARK: Private state
    // -----------------------------------------------------------------------

    private var engine:    AVAudioEngine?
    private let format   = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    private var musicEnabled    = true
    private var sfxEnabled      = true
    private var ambienceEnabled = true

    // -- Music --
    // Four distinct tracks across two groups (day / evening).
    // A timer schedules rotation; one music node used at a time per voice layer.
    private var musicNodes:  [AVAudioPlayerNode] = []   // 4 voice nodes
    private var musicMixer:  AVAudioMixerNode?

    private enum TrackGroup { case day, evening }
    private var currentTrackGroup: TrackGroup = .day
    private var currentTrackIndex: Int        = 0
    private var trackTimer: Timer?

    // Pre-rendered track buffers: [trackID][voiceIndex]
    // Tracks 0,1 = day; Tracks 2,3 = evening
    private var allTrackBuffers: [[AVAudioPCMBuffer]] = []   // [trackIdx] = array-of-4-voices

    // -- Ambience --
    private var ambienceWindNode:  AVAudioPlayerNode?
    private var birdNode:          AVAudioPlayerNode?
    private var ambienceMixer:     AVAudioMixerNode?
    private var windBuffer:        AVAudioPCMBuffer?
    private var birdMotifBuffers:  [AVAudioPCMBuffer] = []
    private var birdTimer:         Timer?

    // -- SFX --
    private let poolSize  = 8
    private var sfxPool:  [AVAudioPlayerNode] = []
    private var sfxMixer: AVAudioMixerNode?
    private var poolIndex = 0

    private var sfxBuffers: [Sfx: AVAudioPCMBuffer] = [:]

    // Pitch-variant pre-rendered buffers for frequently repeated SFX.
    private struct SfxVariantKey: Hashable {
        let sfx: Sfx
        let variant: Int
    }
    private var sfxVariantBuffers: [SfxVariantKey: AVAudioPCMBuffer] = [:]
    private var variantCounters:   [Sfx: Int] = [:]
    private let variantSfxCases: [Sfx] = [.mine, .place, .breakBlock, .step]

    // -----------------------------------------------------------------------
    // MARK: Engine setup
    // -----------------------------------------------------------------------

    private func setupEngine() {
        let eng = AVAudioEngine()
        let mainMixer = eng.mainMixerNode

        let outFormat = eng.outputNode.inputFormat(forBus: 0)
        guard outFormat.channelCount > 0 else { return }

        // --- Music mixer ---
        let mMix = AVAudioMixerNode()
        mMix.outputVolume = 0.20
        eng.attach(mMix)
        eng.connect(mMix, to: mainMixer, format: outFormat)
        musicMixer = mMix

        // --- Ambience mixer ---
        let aMix = AVAudioMixerNode()
        aMix.outputVolume = 0.18
        eng.attach(aMix)
        eng.connect(aMix, to: mainMixer, format: outFormat)
        ambienceMixer = aMix

        // --- SFX mixer ---
        let sMix = AVAudioMixerNode()
        sMix.outputVolume = 0.55
        eng.attach(sMix)
        eng.connect(sMix, to: mainMixer, format: outFormat)
        sfxMixer = sMix

        // --- Music nodes (4 voices for layered pad chords) ---
        for _ in 0 ..< 4 {
            let node = AVAudioPlayerNode()
            eng.attach(node)
            eng.connect(node, to: mMix, format: format)
            musicNodes.append(node)
        }

        // --- Ambience wind node ---
        let windNode = AVAudioPlayerNode()
        windNode.volume = 0.55
        eng.attach(windNode)
        eng.connect(windNode, to: aMix, format: format)
        ambienceWindNode = windNode

        // --- Ambience bird node ---
        let bNode = AVAudioPlayerNode()
        bNode.volume = 0.25
        eng.attach(bNode)
        eng.connect(bNode, to: aMix, format: format)
        birdNode = bNode

        // --- SFX pool ---
        for _ in 0 ..< poolSize {
            let node = AVAudioPlayerNode()
            eng.attach(node)
            eng.connect(node, to: sMix, format: format)
            sfxPool.append(node)
        }

        // Pre-generate all buffers synchronously at startup.
        buildAllTrackBuffers()
        buildAllSfxBuffers()
        buildSfxVariants()
        buildAmbienceBuffers()

        eng.prepare()
        self.engine = eng
    }

    // -----------------------------------------------------------------------
    // MARK: Music — four distinct tracks
    // -----------------------------------------------------------------------
    //
    // Track 0: "Bright Daytime"   — C major, open 5ths, brighter pad
    // Track 1: "Sunny Exploration"— G major, pentatonic feel, bouncy arpeggios
    // Track 2: "Mellow Evening"   — A minor, softer, slower chord rhythm
    // Track 3: "Gentle Dusk"      — F major → D minor, lullaby-ish, very soft
    //
    // Each track is pre-rendered into 4 voice buffers (root / 3rd / 5th / octave).
    // A Timer rotates tracks every ~48 s. On rotation we cross-fade (stop+restart).
    //
    // Tracks 0,1 belong to .day group; Tracks 2,3 to .evening group.

    private func startMusic() {
        if allTrackBuffers.isEmpty { buildAllTrackBuffers() }

        // Stop current
        musicNodes.forEach { $0.stop() }
        trackTimer?.invalidate()
        trackTimer = nil

        // Pick starting track from current group.
        currentTrackIndex = firstTrackIndex(for: currentTrackGroup)
        playTrack(currentTrackIndex)
        scheduleTrackRotation()
    }

    private func firstTrackIndex(for group: TrackGroup) -> Int {
        switch group {
        case .day:     return 0
        case .evening: return 2
        }
    }

    private func nextTrackIndex(after idx: Int) -> Int {
        // Cycle within the two tracks of the current group.
        let groupStart = firstTrackIndex(for: currentTrackGroup)
        let offset     = (idx - groupStart + 1) % 2
        return groupStart + offset
    }

    private func playTrack(_ idx: Int) {
        guard idx < allTrackBuffers.count else { return }
        let voiceBuffers = allTrackBuffers[idx]
        for (i, node) in musicNodes.enumerated() {
            guard i < voiceBuffers.count else { break }
            node.stop()
            node.scheduleBuffer(voiceBuffers[i], at: nil, options: .loops, completionHandler: nil)
            node.play()
        }
    }

    private func scheduleTrackRotation() {
        // Rotate every 48 seconds so the listener hears variety without a jarring cut.
        trackTimer = Timer.scheduledTimer(withTimeInterval: 48, repeats: false) { [weak self] _ in
            guard let self, self.musicEnabled, self.engine?.isRunning == true else { return }
            self.currentTrackIndex = self.nextTrackIndex(after: self.currentTrackIndex)
            self.crossFadeToTrack(self.currentTrackIndex)
            self.scheduleTrackRotation()
        }
    }

    /// Simple cross-fade: ramp music mixer volume down, switch track, ramp back up.
    private func crossFadeToTrack(_ idx: Int) {
        guard let mMix = musicMixer else { return }
        let steps    = 30
        let stepDur  = 1.5 / Double(steps)  // 1.5 s total fade

        // Fade out
        var count = 0
        Timer.scheduledTimer(withTimeInterval: stepDur, repeats: true) { [weak self, weak mMix] t in
            guard let mMix else { t.invalidate(); return }
            count += 1
            mMix.outputVolume = 0.20 * (1 - Float(count) / Float(steps))
            if count >= steps {
                t.invalidate()
                self?.playTrack(idx)
                // Fade in
                var inCount = 0
                Timer.scheduledTimer(withTimeInterval: stepDur, repeats: true) { [weak mMix] t2 in
                    guard let mMix else { t2.invalidate(); return }
                    inCount += 1
                    mMix.outputVolume = 0.20 * Float(inCount) / Float(steps)
                    if inCount >= steps { t2.invalidate() }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Track buffer synthesis
    // -----------------------------------------------------------------------
    //
    // Each track has its own chord progression + voice character.
    // Each track's full loop is a concatenation of chord segments.
    // 4 voices per track → stored as allTrackBuffers[trackIdx][voiceIdx].

    private func buildAllTrackBuffers() {
        allTrackBuffers = []
        allTrackBuffers.append(buildTrack0_BrightDaytime())
        allTrackBuffers.append(buildTrack1_SunnyExploration())
        allTrackBuffers.append(buildTrack2_MellowEvening())
        allTrackBuffers.append(buildTrack3_GentleDusk())
    }

    // MARK: Track 0 — Bright Daytime (C maj → F maj → G maj → C maj, 5 s each = 20 s loop)
    private func buildTrack0_BrightDaytime() -> [AVAudioPCMBuffer] {
        // Roots: C3, F3, G3, C3
        let roots:     [Float] = [130.81, 174.61, 196.00, 130.81]
        // All major chords: root, M3, P5, octave
        let intervals: [Float] = [1.0, 5.0/4, 3.0/2, 2.0]
        let chordDur:  Double  = 5.0
        let shapes: [OscShape] = [.sine, .triangle, .sine, .triangle]
        let vols:    [Float]   = [0.32, 0.22, 0.28, 0.16]
        return buildChordProgressionTrack(roots: roots, intervals: intervals,
                                          chordDur: chordDur, shapes: shapes,
                                          voiceVols: vols, attackMul: 1.0, releaseMul: 1.0)
    }

    // MARK: Track 1 — Sunny Exploration (G maj → D maj → A min → E min, 4 s each = 16 s)
    private func buildTrack1_SunnyExploration() -> [AVAudioPCMBuffer] {
        // Brighter — use octave-up roots (G3, D3, A2, E3)
        let roots:     [Float] = [196.00, 146.83, 110.00, 164.81]
        // Major / minor mix
        let chordTypes: [[Float]] = [
            [1.0, 5.0/4, 3.0/2, 2.0],    // G major
            [1.0, 5.0/4, 3.0/2, 2.0],    // D major
            [1.0, 6.0/5, 3.0/2, 2.0],    // A minor
            [1.0, 6.0/5, 3.0/2, 2.0],    // E minor
        ]
        let chordDur: Double = 4.0
        let shapes: [OscShape] = [.sine, .sine, .triangle, .triangle]
        let vols:   [Float]   = [0.28, 0.24, 0.26, 0.14]
        // Build per-voice by extracting each voice's intervals across chords.
        return buildMixedProgressionTrack(roots: roots, chordTypes: chordTypes,
                                          chordDur: chordDur, shapes: shapes, voiceVols: vols,
                                          attackMul: 0.7, releaseMul: 0.8)
    }

    // MARK: Track 2 — Mellow Evening (A min → C maj → G maj → E min, 6 s each = 24 s)
    private func buildTrack2_MellowEvening() -> [AVAudioPCMBuffer] {
        let roots: [Float] = [110.00, 130.81, 98.00, 82.41]   // A2, C3, G2, E2
        let chordTypes: [[Float]] = [
            [1.0, 6.0/5, 3.0/2, 2.0],    // A minor
            [1.0, 5.0/4, 3.0/2, 2.0],    // C major
            [1.0, 5.0/4, 3.0/2, 2.0],    // G major
            [1.0, 6.0/5, 3.0/2, 2.0],    // E minor
        ]
        let chordDur: Double = 6.0
        // Softer — all sine for a pure, calm feel.
        let shapes: [OscShape] = [.sine, .sine, .sine, .sine]
        let vols:   [Float]   = [0.28, 0.18, 0.24, 0.13]
        return buildMixedProgressionTrack(roots: roots, chordTypes: chordTypes,
                                          chordDur: chordDur, shapes: shapes, voiceVols: vols,
                                          attackMul: 1.5, releaseMul: 1.5)
    }

    // MARK: Track 3 — Gentle Dusk (F maj → D min → B♭ maj → C maj, 7 s each = 28 s)
    private func buildTrack3_GentleDusk() -> [AVAudioPCMBuffer] {
        let roots: [Float] = [87.31, 73.42, 116.54, 65.41]   // F2, D2, Bb2, C2
        let chordTypes: [[Float]] = [
            [1.0, 5.0/4, 3.0/2, 2.0],    // F major
            [1.0, 6.0/5, 3.0/2, 2.0],    // D minor
            [1.0, 5.0/4, 3.0/2, 2.0],    // Bb major
            [1.0, 5.0/4, 3.0/2, 2.0],    // C major
        ]
        let chordDur: Double = 7.0
        // Very soft triangle — lullaby warmth
        let shapes: [OscShape] = [.triangle, .triangle, .triangle, .triangle]
        let vols:   [Float]   = [0.24, 0.16, 0.20, 0.11]
        return buildMixedProgressionTrack(roots: roots, chordTypes: chordTypes,
                                          chordDur: chordDur, shapes: shapes, voiceVols: vols,
                                          attackMul: 2.0, releaseMul: 2.0)
    }

    // -----------------------------------------------------------------------
    // MARK: Track helpers
    // -----------------------------------------------------------------------

    /// All chords share the same interval ratios (e.g. all-major).
    private func buildChordProgressionTrack(roots: [Float],
                                            intervals: [Float],
                                            chordDur: Double,
                                            shapes: [OscShape],
                                            voiceVols: [Float],
                                            attackMul: Float,
                                            releaseMul: Float) -> [AVAudioPCMBuffer] {
        let chordTypes = roots.map { _ in intervals }
        return buildMixedProgressionTrack(roots: roots, chordTypes: chordTypes,
                                          chordDur: chordDur, shapes: shapes,
                                          voiceVols: voiceVols,
                                          attackMul: attackMul, releaseMul: releaseMul)
    }

    /// Each chord can have its own interval set.
    private func buildMixedProgressionTrack(roots: [Float],
                                            chordTypes: [[Float]],
                                            chordDur: Double,
                                            shapes: [OscShape],
                                            voiceVols: [Float],
                                            attackMul: Float,
                                            releaseMul: Float) -> [AVAudioPCMBuffer] {
        let sr              = Float(format.sampleRate)
        let chordSamples    = Int(sr * Float(chordDur))
        let chordCount      = roots.count
        let totalSamples    = chordSamples * chordCount
        let numVoices       = min(4, min(shapes.count, voiceVols.count))

        var result: [AVAudioPCMBuffer] = []

        for voiceIdx in 0 ..< numVoices {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(totalSamples)) else { continue }
            buf.frameLength = AVAudioFrameCount(totalSamples)
            guard let L = buf.floatChannelData?[0],
                  let R = buf.floatChannelData?[1] else { continue }

            let shape = shapes[voiceIdx]
            let vol   = voiceVols[voiceIdx]
            let atk   = Float(chordDur) * 0.15 * attackMul
            let rel   = Float(chordDur) * 0.22 * releaseMul

            for chordIdx in 0 ..< chordCount {
                let rootHz   = roots[chordIdx]
                let interval = chordTypes[chordIdx][min(voiceIdx, chordTypes[chordIdx].count - 1)]
                let hz       = rootHz * interval
                let baseOff  = chordIdx * chordSamples

                for i in 0 ..< chordSamples {
                    let t   = Float(i) / sr
                    let env = padEnvelope(t, attack: atk, release: rel, total: Float(chordDur))
                    let sample = vol * env * osc(shape, phase: hz * t)
                    L[baseOff + i] = sample
                    R[baseOff + i] = sample
                }
            }

            applyFadeIO(L, R, samples: totalSamples, fadeLen: min(512, totalSamples / 8))
            result.append(buf)
        }
        return result
    }

    /// Smooth pad envelope: fast attack → sustain → graceful release.
    @inline(__always)
    private func padEnvelope(_ t: Float, attack: Float, release: Float, total: Float) -> Float {
        if t < attack { return t / attack }
        let tail = total - release
        if t > tail  { return max(0, (total - t) / release) }
        return 1.0
    }

    // -----------------------------------------------------------------------
    // MARK: Ambience
    // -----------------------------------------------------------------------
    //
    // Wind: long filtered-noise buffer (60 s) with gentle amplitude LFO to give
    // the impression of swells. Scheduled on .loops.
    //
    // Birds: 3 distinct whistle motifs, played at random ~10–35 s intervals via
    // a self-rescheduling Timer. Volume controlled by setTimeOfDay.

    private func buildAmbienceBuffers() {
        windBuffer       = makeWindBuffer()
        birdMotifBuffers = makeBirdMotifBuffers()
    }

    private func startAmbience() {
        startWind()
        scheduleBirdChirp()
    }

    private func startWind() {
        guard let node = ambienceWindNode, let buf = windBuffer else { return }
        node.stop()
        node.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        node.play()
    }

    private func scheduleBirdChirp() {
        birdTimer?.invalidate()
        // Random interval 10–35 s between chirps.
        let delay = Double.random(in: 10 ... 35)
        birdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.ambienceEnabled, self.engine?.isRunning == true else { return }
            self.playBirdMotif()
            self.scheduleBirdChirp()
        }
    }

    private func playBirdMotif() {
        guard let node = birdNode, !birdMotifBuffers.isEmpty else { return }
        let buf = birdMotifBuffers[Int.random(in: 0 ..< birdMotifBuffers.count)]
        node.scheduleBuffer(buf, completionHandler: nil)
        if !node.isPlaying { node.play() }
    }

    // MARK: Wind synthesis
    //
    // 60-second buffer of brownian-filtered noise with a slow amplitude LFO
    // (~0.05 Hz) to simulate gentle gusts swelling in and out.

    private func makeWindBuffer() -> AVAudioPCMBuffer? {
        let dur: Float  = 60.0
        let sr          = Float(format.sampleRate)
        let n           = Int(sr * dur)
        guard n > 0 else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        guard let L = buf.floatChannelData?[0],
              let R = buf.floatChannelData?[1] else { return nil }

        // Simple low-pass via one-pole IIR: y[n] = α*x[n] + (1-α)*y[n-1]
        let alpha: Float  = 0.003   // very heavy LP → wind-like rumble
        var prevL: Float  = 0
        var prevR: Float  = 0
        let lfoFreq: Float = 0.04   // gentle swell frequency

        for i in 0 ..< n {
            let t    = Float(i) / sr
            let lfo  = 0.5 + 0.5 * sin(2 * .pi * lfoFreq * t + 0.7)   // 0…1 swell
            let amp  = 0.35 + 0.25 * lfo                                // 0.35…0.60

            let xL   = Float.random(in: -1 ... 1)
            let xR   = Float.random(in: -1 ... 1)
            prevL    = alpha * xL + (1 - alpha) * prevL
            prevR    = alpha * xR + (1 - alpha) * prevR

            // Normalize brownian noise (it drifts in energy; scale to reasonable level).
            L[i] = prevL * amp * 6.0
            R[i] = prevR * amp * 6.0
        }

        applyFadeIO(L, R, samples: n, fadeLen: min(8820, n / 4))   // 200 ms fade
        return buf
    }

    // MARK: Bird motif synthesis
    //
    // Three distinct whistle motifs made from fast FM-ish sine sweeps:
    //   Motif A: two-note rise (robin-like)
    //   Motif B: three-note descending trill (warbler-like)
    //   Motif C: single bright chirp + echo (sparrow-like)

    private func makeBirdMotifBuffers() -> [AVAudioPCMBuffer] {
        var motifs: [AVAudioPCMBuffer] = []
        if let m = makeBirdMotifA() { motifs.append(m) }
        if let m = makeBirdMotifB() { motifs.append(m) }
        if let m = makeBirdMotifC() { motifs.append(m) }
        return motifs
    }

    /// Motif A: two rising pure tones, ~0.3 s gap between, each ~150 ms
    private func makeBirdMotifA() -> AVAudioPCMBuffer? {
        let total:   Float = 0.70
        let noteDur: Float = 0.15
        // Note 1 at 0 s: 1800→2400 Hz sweep; Note 2 at 0.25 s: 2200→2800 Hz
        return synthesize(duration: total) { i, sr in
            let t = Float(i) / sr
            var s: Float = 0
            // Note 1
            if t < noteDur {
                let hz  = 1800 + 600 * (t / noteDur)
                let env = self.birdEnv(t, dur: noteDur)
                s += env * 0.45 * sin(2 * .pi * hz * t)
            }
            // Note 2
            let t2Start: Float = 0.28
            let t2 = t - t2Start
            if t2 >= 0 && t2 < noteDur {
                let hz  = 2200 + 600 * (t2 / noteDur)
                let env = self.birdEnv(t2, dur: noteDur)
                s += env * 0.40 * sin(2 * .pi * hz * t2)
            }
            return s
        }
    }

    /// Motif B: three descending notes (warbler), each ~120 ms, 0.15 s apart
    private func makeBirdMotifB() -> AVAudioPCMBuffer? {
        let total:    Float = 0.85
        let noteDur:  Float = 0.12
        let offsets:  [Float] = [0.00, 0.16, 0.32]
        let freqSets: [(Float, Float)] = [(2600, 2200), (2300, 1900), (2000, 1600)]
        return synthesize(duration: total) { i, sr in
            let t = Float(i) / sr
            var s: Float = 0
            for (idx, off) in offsets.enumerated() {
                let nt = t - off
                guard nt >= 0 && nt < noteDur else { continue }
                let (fStart, fEnd) = freqSets[idx]
                let hz  = fStart + (fEnd - fStart) * (nt / noteDur)
                let env = self.birdEnv(nt, dur: noteDur)
                s += env * 0.38 * sin(2 * .pi * hz * nt)
            }
            return s
        }
    }

    /// Motif C: single bright chirp + softer echo 0.35 s later
    private func makeBirdMotifC() -> AVAudioPCMBuffer? {
        let total:   Float = 0.60
        let noteDur: Float = 0.13
        return synthesize(duration: total) { i, sr in
            let t  = Float(i) / sr
            var s: Float = 0
            // Primary chirp
            if t < noteDur {
                let hz  = Float(3000) * pow(0.55, t * 5)    // fast pitch drop
                let env = self.birdEnv(t, dur: noteDur)
                s += env * 0.50 * sin(2 * .pi * hz * t)
            }
            // Echo (softer)
            let t2 = t - 0.32
            if t2 >= 0 && t2 < noteDur {
                let hz  = Float(2800) * pow(0.55, t2 * 5)
                let env = self.birdEnv(t2, dur: noteDur)
                s += env * 0.22 * sin(2 * .pi * hz * t2)
            }
            return s
        }
    }

    @inline(__always)
    private func birdEnv(_ t: Float, dur: Float) -> Float {
        let a: Float = 0.012
        let r: Float = dur * 0.45
        if t < a          { return t / a }
        if t > (dur - r)  { return max(0, (dur - t) / r) }
        return 1.0
    }

    // -----------------------------------------------------------------------
    // MARK: SFX synthesis — original 8 + 4 new
    // -----------------------------------------------------------------------

    private func buildAllSfxBuffers() {
        sfxBuffers[.mine]          = makeMineBuffer()
        sfxBuffers[.place]         = makePlaceBuffer()
        sfxBuffers[.breakBlock]    = makeBreakBlockBuffer()
        sfxBuffers[.step]          = makeStepBuffer()
        sfxBuffers[.jump]          = makeJumpBuffer()
        sfxBuffers[.craft]         = makeCraftBuffer()
        sfxBuffers[.befriend]      = makeBefriendBuffer()
        sfxBuffers[.questComplete] = makeQuestCompleteBuffer()
        // New
        sfxBuffers[.splash]        = makeSplashBuffer()
        sfxBuffers[.pickup]        = makePickupBuffer()
        sfxBuffers[.openInventory] = makeOpenInventoryBuffer()
        sfxBuffers[.placeFail]     = makePlaceFailBuffer()
    }

    // MARK: Pitch-variant pre-render
    //
    // For frequently-repeated SFX (mine, place, breakBlock, step) we pre-render
    // 4 pitch variants (±3 semitones) and rotate through them so repeated
    // sounds don't feel machine-gun identical.

    private func buildSfxVariants() {
        let semitoneRatios: [Float] = [
            pow(2, -2.0/12),   // -2 semitones
            pow(2, -0.5/12),   // -0.5 st
            pow(2,  0.5/12),   // +0.5 st
            pow(2,  2.0/12),   // +2 semitones
        ]
        for sfxCase in variantSfxCases {
            guard let base = sfxBuffers[sfxCase] else { continue }
            for (variantIdx, ratio) in semitoneRatios.enumerated() {
                if let vBuf = pitchShift(base, ratio: ratio) {
                    sfxVariantBuffers[SfxVariantKey(sfx: sfxCase, variant: variantIdx)] = vBuf
                }
            }
        }
    }

    /// Returns an index into the 4 variants for this SFX, cycling each call.
    private func variantIndex(for sfx: Sfx) -> Int {
        guard variantSfxCases.contains(sfx) else { return 0 }
        let idx = (variantCounters[sfx] ?? 0) % 4
        variantCounters[sfx] = idx + 1
        return idx
    }

    /// Naive pitch shift via linear resampling (changes duration slightly — fine for short SFX).
    private func pitchShift(_ src: AVAudioPCMBuffer, ratio: Float) -> AVAudioPCMBuffer? {
        guard let srcL = src.floatChannelData?[0],
              let srcR = src.floatChannelData?[1] else { return nil }
        let srcN   = Int(src.frameLength)
        let dstN   = Int(Float(srcN) / ratio)
        guard dstN > 0 else { return nil }

        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(dstN)) else { return nil }
        buf.frameLength = AVAudioFrameCount(dstN)
        guard let dstL = buf.floatChannelData?[0],
              let dstR = buf.floatChannelData?[1] else { return nil }

        for i in 0 ..< dstN {
            let srcPos = Float(i) * ratio
            let lo     = min(Int(srcPos), srcN - 1)
            let hi     = min(lo + 1, srcN - 1)
            let frac   = srcPos - Float(lo)
            dstL[i]   = srcL[lo] + frac * (srcL[hi] - srcL[lo])
            dstR[i]   = srcR[lo] + frac * (srcR[hi] - srcR[lo])
        }
        return buf
    }

    // MARK: Original SFX

    /// mine — soft thud: low sine tone + filtered noise burst, ~120 ms
    private func makeMineBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.12
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.005, d: 0.04, s: 0.4, sLen: 0.05, r: 0.03, total: dur)
            let tone  = 0.5 * sin(2 * .pi * 90 * t)
            let noise = 0.25 * self.whitenoise()
            return env * (tone + noise)
        }
    }

    /// place — low wooden click: short sine pop at ~200 Hz, ~80 ms
    private func makePlaceBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.08
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.002, d: 0.02, s: 0.3, sLen: 0.03, r: 0.03, total: dur)
            let hz   = Float(200) * pow(0.5, t * 8)
            let tone  = 0.7 * sin(2 * .pi * hz * t)
            let noise = 0.1 * self.whitenoise()
            return env * (tone + noise)
        }
    }

    /// breakBlock — brighter crumble/pop: mid-freq tone + noise burst, ~180 ms
    private func makeBreakBlockBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.18
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.003, d: 0.05, s: 0.35, sLen: 0.06, r: 0.07, total: dur)
            let hz   = Float(400) * pow(0.4, t * 4)
            let tone  = 0.4 * self.osc(.triangle, phase: hz * t)
            let noise = 0.45 * self.whitenoise()
            return env * (tone + noise)
        }
    }

    /// step — quiet soft tap: very short low tone, ~60 ms
    private func makeStepBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.06
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.002, d: 0.015, s: 0.2, sLen: 0.01, r: 0.03, total: dur)
            let tone  = 0.45 * sin(2 * .pi * 120 * t)
            let noise = 0.2 * self.whitenoise()
            return env * (tone + noise) * 0.6
        }
    }

    /// jump — tiny upward chirp: sine swept 300→600 Hz, ~140 ms
    private func makeJumpBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.14
        var phase: Float = 0
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.005, d: 0.04, s: 0.5, sLen: 0.05, r: 0.05, total: dur)
            let hz  = 300 + 300 * (t / dur)
            phase  += hz / sr
            return env * 0.55 * sin(2 * .pi * phase)
        }
    }

    /// craft — two-note ding: C5 then E5, each ~200 ms, 400 ms total
    private func makeCraftBuffer() -> AVAudioPCMBuffer? {
        let noteDur: Float = 0.20
        let total:   Float = noteDur * 2
        let notes:   [Float] = [523.25, 659.25]
        return synthesize(duration: total) { i, sr in
            let t       = Float(i) / sr
            let noteIdx = Int(t / noteDur)
            let nt      = t - Float(noteIdx) * noteDur
            let hz      = notes[min(noteIdx, notes.count - 1)]
            let env     = self.envelope(nt, a: 0.005, d: 0.05, s: 0.6, sLen: 0.08, r: 0.07, total: noteDur)
            return env * 0.5 * (sin(2 * .pi * hz * nt) + 0.3 * sin(2 * .pi * hz * 2 * nt))
        }
    }

    /// befriend — happy arpeggio: C5 E5 G5 C6, each ~160 ms, 640 ms total
    private func makeBefriendBuffer() -> AVAudioPCMBuffer? {
        let noteDur: Float = 0.16
        let total:   Float = noteDur * 4
        let notes:   [Float] = [523.25, 659.25, 783.99, 1046.50]
        return synthesize(duration: total) { i, sr in
            let t       = Float(i) / sr
            let noteIdx = Int(t / noteDur)
            let nt      = t - Float(noteIdx) * noteDur
            let hz      = notes[min(noteIdx, notes.count - 1)]
            let env     = self.envelope(nt, a: 0.004, d: 0.03, s: 0.7, sLen: 0.08, r: 0.05, total: noteDur)
            return env * 0.45 * (self.osc(.triangle, phase: hz * nt) + 0.25 * sin(2 * .pi * hz * 2 * nt))
        }
    }

    /// questComplete — cheerful fanfare: C5+E5+G5 chord then C6 accent, ~800 ms
    private func makeQuestCompleteBuffer() -> AVAudioPCMBuffer? {
        let total:      Float  = 0.80
        let chordEnd:   Float  = 0.50
        let chordNotes: [Float] = [523.25, 659.25, 783.99]
        let accentHz:   Float  = 1046.50
        return synthesize(duration: total) { i, sr in
            let t = Float(i) / sr
            var sample: Float = 0
            if t < chordEnd {
                let env = self.envelope(t, a: 0.01, d: 0.05, s: 0.8, sLen: chordEnd - 0.1, r: 0.05, total: chordEnd)
                for hz in chordNotes {
                    sample += env * (0.22 * sin(2 * .pi * hz * t) + 0.08 * self.osc(.triangle, phase: hz * t))
                }
            } else {
                let nt  = t - chordEnd
                let dur = total - chordEnd
                let env = self.envelope(nt, a: 0.005, d: 0.03, s: 0.7, sLen: dur - 0.08, r: 0.05, total: dur)
                sample = env * 0.55 * (sin(2 * .pi * accentHz * nt) + 0.2 * self.osc(.triangle, phase: accentHz * nt))
            }
            return sample
        }
    }

    // MARK: New SFX

    /// splash — water entry: filtered white-noise burst with fizzy high-end, ~280 ms
    private func makeSplashBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.28
        // State for two-pole LP filter (simulate water body)
        var prevY1: Float = 0
        let cutoff: Float  = 0.08    // normalized cutoff (0..1) — mid-water

        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.005, d: 0.06, s: 0.5, sLen: 0.08, r: 0.13, total: dur)
            // Two-pole LP: simple biquad-lite
            let x = self.whitenoise()
            let y = cutoff * x + (1 - cutoff) * prevY1
            prevY1 = y
            // Mix LP (body) + raw (fizz)
            let sample = 0.55 * y + 0.30 * x
            return env * sample * 1.2
        }
    }

    /// pickup — item collected: bright sparkle ding, E6→G6→B6 upward arpeggio, ~360 ms
    private func makePickupBuffer() -> AVAudioPCMBuffer? {
        let noteDur: Float = 0.10
        let total:   Float = noteDur * 3 + 0.06
        let notes:   [Float] = [1318.51, 1567.98, 1975.53]   // E6, G6, B6
        return synthesize(duration: total) { i, sr in
            let t   = Float(i) / sr
            var s: Float = 0
            for (idx, hz) in notes.enumerated() {
                let onset = Float(idx) * noteDur
                let nt    = t - onset
                guard nt >= 0 && nt < noteDur * 1.4 else { continue }
                let env = self.envelope(nt, a: 0.003, d: 0.02, s: 0.55, sLen: 0.04, r: 0.05, total: noteDur)
                s += env * 0.28 * (sin(2 * .pi * hz * nt) + 0.18 * sin(2 * .pi * hz * 2 * nt))
            }
            return s
        }
    }

    /// openInventory — soft wooden drawer slide: low filtered noise sweep, ~220 ms
    private func makeOpenInventoryBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.22
        var prevLow: Float = 0
        return synthesize(duration: dur) { i, sr in
            let t    = Float(i) / sr
            // Envelope: quick attack, long release (slide in)
            let env  = self.envelope(t, a: 0.01, d: 0.05, s: 0.6, sLen: 0.05, r: 0.10, total: dur)
            // Cutoff sweeps from low → mid as drawer opens
            let alpha = 0.005 + 0.04 * (t / dur)
            let x    = self.whitenoise()
            prevLow  = alpha * x + (1 - alpha) * prevLow
            // Mix with a very low resonant tone for the "thump" of contact
            let tone = 0.3 * sin(2 * .pi * 160 * t) * max(0, 1 - t * 10)
            return env * (0.8 * prevLow * 3.5 + tone)
        }
    }

    /// placeFail — dull thud: low, short, dampened — like bumping against something solid, ~150 ms
    private func makePlaceFailBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.15
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.004, d: 0.06, s: 0.15, sLen: 0.02, r: 0.06, total: dur)
            // Low fundamental with heavy decay
            let hz  = Float(80) * pow(0.3, t * 6)
            let tone  = 0.55 * sin(2 * .pi * hz * t)
            let noise = 0.20 * self.whitenoise()
            return env * (tone + noise) * 0.85
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
        if t < a { return t / a }
        let afterA = t - a
        if afterA < d { return 1.0 - (1.0 - s) * (afterA / d) }
        let afterD = afterA - d
        if afterD < sLen { return s }
        let afterS = afterD - sLen
        if afterS < r  { return s * (1.0 - afterS / r) }
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
    private func idleSfxNode() -> AVAudioPlayerNode {
        let node = sfxPool[poolIndex % poolSize]
        poolIndex = (poolIndex + 1) % poolSize
        node.stop()
        return node
    }
}
