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
//   func playBreak(materialClass: Int)
//         0=generic  1=stone/rock  2=wood   3=dirt/grass
//         4=sand/gravel  5=glass   6=leaves/plant  7=metal/ore
//   play(.breakBlock) routes to playBreak(materialClass:0) automatically.
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
        musicBankNodes.forEach { $0.stop() }
        sfxPool.forEach        { $0.stop() }
        ambienceWindNode?.stop()
        birdTimer?.invalidate()
        birdTimer = nil
        trackTimer?.invalidate()
        trackTimer = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        engine?.stop()
    }

    // -----------------------------------------------------------------------
    // MARK: Controls
    // -----------------------------------------------------------------------

    func setMusicEnabled(_ on: Bool) {
        musicEnabled = on
        guard engine?.isRunning == true else { return }
        if on { startMusic() } else {
            crossfadeTimer?.invalidate()
            crossfadeTimer = nil
            musicBankNodes.forEach { $0.stop() }
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

    /// Call each frame (or whenever time changes). t in [0, 1]: 0/1 = midnight, 0.5 = noon.
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
    // MARK: SFX playback (with +/-pitch variation to avoid monotony)
    // -----------------------------------------------------------------------

    func play(_ sfx: Sfx) {
        guard sfxEnabled, let engine, engine.isRunning else { return }

        // Route breakBlock through the per-material path so legacy callers
        // automatically get the punchier generic sound + variant cycling.
        if sfx == .breakBlock {
            playBreak(materialClass: 0)
            return
        }

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
        // Actually the cleanest no-extra-node approach: build +/-5% pitch variants
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
    // A/B bank architecture: two independent banks of 4 voice nodes, each fed
    // through its own AVAudioMixerNode so their volumes can be ramped
    // simultaneously during a crossfade without touching one another.
    //
    //   musicBankNodes[0..3] → musicBankMixers[0] → musicMixer → mainMixer
    //   musicBankNodes[4..7] → musicBankMixers[1] → musicMixer → mainMixer
    //
    // During playback one bank is "active" (volume 1) and the other is silent.
    // On a transition both banks play simultaneously while the outgoing bank
    // fades from 1→0 and the incoming bank fades from 0→1 over kCrossfadeDur.
    private var musicBankNodes:  [AVAudioPlayerNode] = []   // 8 nodes (4 per bank)
    private var musicBankMixers: [AVAudioMixerNode]  = []   // 2 per-bank sub-mixers
    private var musicMixer:      AVAudioMixerNode?
    private var activeBank:      Int = 0                    // 0 or 1

    // Crossfade duration in seconds (linear gain curve, no shared-mixer touch).
    private let kCrossfadeDur: Double = 3.5
    // How long before scheduling the next rotation.
    private let kTrackRotationInterval: Double = 60.0

    private enum TrackGroup { case day, evening }
    private var currentTrackGroup: TrackGroup = .day
    private var currentTrackIndex: Int        = 0
    private var trackTimer:     Timer?
    private var crossfadeTimer: Timer?   // running crossfade step timer

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
    // breakBlock is intercepted in play(_:) and handled via playBreak(materialClass:0);
    // its SFX variant pre-render is not needed here.
    private let variantSfxCases: [Sfx] = [.mine, .place, .step]

    // -----------------------------------------------------------------------
    // MARK: Engine setup
    // -----------------------------------------------------------------------

    private func setupEngine() {
        let eng = AVAudioEngine()
        let mainMixer = eng.mainMixerNode

        let outFormat = eng.outputNode.inputFormat(forBus: 0)
        guard outFormat.channelCount > 0 else { return }

        // --- Music mixer (master gain only — never touched during crossfades) ---
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

        // --- A/B music banks ---
        // Each bank has its own sub-mixer so its volume can be ramped independently
        // during crossfades. Bank A starts at full volume, Bank B at zero.
        for bankIdx in 0 ..< 2 {
            let bankMix = AVAudioMixerNode()
            bankMix.outputVolume = bankIdx == 0 ? 1.0 : 0.0
            eng.attach(bankMix)
            eng.connect(bankMix, to: mMix, format: outFormat)
            musicBankMixers.append(bankMix)

            for _ in 0 ..< 4 {
                let node = AVAudioPlayerNode()
                eng.attach(node)
                eng.connect(node, to: bankMix, format: format)
                musicBankNodes.append(node)
            }
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
    // MARK: Music — four fun, upbeat, kid-friendly tracks
    // -----------------------------------------------------------------------
    //
    // Track 0: "Sunshine Sprint"  — C major, 120 BPM, 16 s loop  [DAY]
    //   Bouncy melody over walking bass + sparkling arpeggios.
    //
    // Track 1: "Pixel Bounce"     — G major, 132 BPM, ~14.5 s loop [DAY]
    //   Skippy pentatonic melody, bright triangle arpeggios, punchy bass.
    //
    // Track 2: "Cozy Campfire"    — F major, 108 BPM, ~17.8 s loop [EVENING]
    //   Warm and cheerful — still all-major, a touch softer and dreamier.
    //
    // Track 3: "Starlight Waltz"  — D major, 120 BPM, 12 s loop  [EVENING]
    //   Lilting 3/4 feel, gentle melody, happy but calm.
    //
    // Each track is synthesized as 4 independent looping voice buffers:
    //   Voice 0 = melody   (sine + slight harmonic blend, medium vol)
    //   Voice 1 = bass     (triangle, lower octave, punchy envelope)
    //   Voice 2 = arpeggio (sine, fast ascending broken chord, light vol)
    //   Voice 3 = pad      (sine, sustained chord, very soft backing)
    //
    // Tracks 0,1 belong to .day group; Tracks 2,3 to .evening group.
    // Rotation: tracks alternate within their group every 60 s via crossFadeToTrack.

    private func startMusic() {
        if allTrackBuffers.isEmpty { buildAllTrackBuffers() }

        // Cancel any in-progress crossfade and stop all nodes cleanly.
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        trackTimer?.invalidate()
        trackTimer = nil
        musicBankNodes.forEach { $0.stop() }

        // Reset bank volumes: A = 1, B = 0.
        activeBank = 0
        musicBankMixers[0].outputVolume = 1.0
        musicBankMixers[1].outputVolume = 0.0

        // Pick starting track from current group.
        currentTrackIndex = firstTrackIndex(for: currentTrackGroup)
        playTrackOnBank(currentTrackIndex, bank: activeBank)
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

    /// Start looping a track's voice buffers on the four nodes of `bank` (0 or 1).
    /// The caller is responsible for setting `musicBankMixers[bank].outputVolume` beforehand.
    private func playTrackOnBank(_ idx: Int, bank: Int) {
        guard idx < allTrackBuffers.count else { return }
        let voiceBuffers  = allTrackBuffers[idx]
        let nodeOffset    = bank * 4
        for i in 0 ..< 4 {
            let node = musicBankNodes[nodeOffset + i]
            node.stop()
            guard i < voiceBuffers.count else { continue }
            node.scheduleBuffer(voiceBuffers[i], at: nil, options: .loops, completionHandler: nil)
            node.play()
        }
    }

    private func scheduleTrackRotation() {
        // Rotate every 60 seconds — long enough to enjoy a melody before it transitions.
        trackTimer = Timer.scheduledTimer(withTimeInterval: kTrackRotationInterval, repeats: false) { [weak self] _ in
            guard let self, self.musicEnabled, self.engine?.isRunning == true else { return }
            self.currentTrackIndex = self.nextTrackIndex(after: self.currentTrackIndex)
            self.crossFadeToTrack(self.currentTrackIndex)
            self.scheduleTrackRotation()
        }
    }

    /// True A/B crossfade: the outgoing bank fades 1→0 while the incoming bank
    /// fades 0→1 simultaneously over kCrossfadeDur seconds (linear gain curve).
    /// Both banks play audio concurrently during the overlap — no gap, no cut.
    private func crossFadeToTrack(_ idx: Int) {
        // Cancel any still-running crossfade before starting a new one.
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil

        let outBank = activeBank
        let inBank  = 1 - activeBank
        activeBank  = inBank

        // Pre-start the incoming bank at volume 0 so it is audibly silent.
        musicBankMixers[inBank].outputVolume = 0.0
        playTrackOnBank(idx, bank: inBank)

        let steps    = 70                               // ~70 steps over 3.5 s → 50 ms/step
        let stepDur  = kCrossfadeDur / Double(steps)
        var step     = 0

        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: stepDur, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1
            // Linear ramp: inBank 0→1, outBank 1→0.
            let progress = Float(step) / Float(steps)
            self.musicBankMixers[inBank].outputVolume  = progress
            self.musicBankMixers[outBank].outputVolume = 1.0 - progress
            if step >= steps {
                timer.invalidate()
                self.crossfadeTimer = nil
                // Clamp to exact endpoints and stop outgoing voices to free resources.
                self.musicBankMixers[inBank].outputVolume  = 1.0
                self.musicBankMixers[outBank].outputVolume = 0.0
                let nodeOffset = outBank * 4
                for i in 0 ..< 4 {
                    self.musicBankNodes[nodeOffset + i].stop()
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Track buffer synthesis
    // -----------------------------------------------------------------------
    //
    // Each track is built from 4 note-sequence voices (melody, bass, arpeggio, pad).
    // All voices within a track share the same totalSamples so they loop in sync.
    // The note-sequence helper buildNoteVoice() renders note events sample-by-sample
    // using a continuous phase accumulator (no audible pops at note transitions) and
    // applies a short linear fade-in/out at the buffer boundary for clean looping.

    private func buildAllTrackBuffers() {
        allTrackBuffers = []
        allTrackBuffers.append(buildTrack0_SunshineSprint())
        allTrackBuffers.append(buildTrack1_PixelBounce())
        allTrackBuffers.append(buildTrack2_CozyCampfire())
        allTrackBuffers.append(buildTrack3_StarlightWaltz())
    }

    // -----------------------------------------------------------------------
    // MARK: Note-sequence voice builder
    // -----------------------------------------------------------------------
    //
    // A MusicalNote specifies:
    //   hz      — equal-temperament frequency (0 = rest/silence for this slot)
    //   dur     — gate duration in seconds (how long the note sounds)
    //   gap     — silence after the gate before the next note starts
    //
    // The sequence loops to fill totalSamples exactly.
    //
    // Per-note envelope:
    //   attack  = min(0.010, dur * 0.08)   — very fast, punchy
    //   sustain = ramp from 1.0 down to 0.78 over the held portion (light duck)
    //   release = starts dur - max(0.005, gap*0.4 + dur*0.12) seconds in
    //
    // Oscillator: main shape + 18% second harmonic for warmth; both scaled so
    // combined peak stays within +-1.0 at vol=1.

    private struct MusicalNote {
        let hz:  Float   // 0 = rest
        let dur: Float   // gate duration in seconds
        let gap: Float   // silence after gate before next note
    }

    /// Render a note sequence into a stereo buffer of exactly `totalSamples` frames.
    private func buildNoteVoice(notes: [MusicalNote],
                                shape: OscShape,
                                vol: Float,
                                totalSamples: Int) -> AVAudioPCMBuffer? {
        guard !notes.isEmpty, totalSamples > 0 else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(totalSamples)) else { return nil }
        buf.frameLength = AVAudioFrameCount(totalSamples)
        guard let L = buf.floatChannelData?[0],
              let R = buf.floatChannelData?[1] else { return nil }

        let sr = Float(format.sampleRate)

        // Pre-compute cumulative note-slot start times (in seconds).
        var starts = [Float]()
        starts.reserveCapacity(notes.count)
        var cursor: Float = 0
        for n in notes {
            starts.append(cursor)
            cursor += n.dur + n.gap
        }
        let seqLen = cursor   // total duration of one sequence pass

        // Phase accumulator — we reset it each time the note pitch changes so the
        // waveform restarts cleanly at phase 0, avoiding inter-note clicks.
        var phase: Float  = 0
        var prevHz: Float = 0
        var noteIdx = 0

        for i in 0 ..< totalSamples {
            let globalT = Float(i) / sr
            // Map into one sequence repeat.
            let seqT    = globalT.truncatingRemainder(dividingBy: seqLen)

            // Locate active note (linear scan; note count is small, typically 4-16).
            noteIdx = 0
            while noteIdx < notes.count - 1 && starts[noteIdx + 1] <= seqT {
                noteIdx += 1
            }

            let note  = notes[noteIdx]
            let noteT = seqT - starts[noteIdx]   // elapsed time within this note slot

            // Reset phase when note pitch changes (clean restart, no pop).
            if note.hz != prevHz {
                phase  = 0
                prevHz = note.hz
            }
            // Advance phase accumulator regardless of gate (keeps tracking).
            if note.hz > 0 {
                phase += note.hz / sr
                if phase > 1.0 { phase -= 1.0 }
            }

            var sample: Float = 0
            if note.hz > 0 && noteT < note.dur {
                // Per-note envelope.
                let atk      = min(0.010, note.dur * 0.08)
                let relStart = note.dur - max(0.005, note.gap * 0.4 + note.dur * 0.12)
                let env: Float
                if noteT < atk {
                    env = noteT / atk
                } else if noteT >= relStart {
                    let relLen = max(0.001, note.dur - relStart)
                    env = max(0, 1.0 - (noteT - relStart) / relLen)
                } else {
                    // Gentle sustain duck: 1.0 at attack end, 0.78 at release start.
                    let sustProg = (noteT - atk) / max(0.001, relStart - atk)
                    env = 1.0 - 0.22 * min(sustProg, 1.0)
                }
                // Main osc + gentle 2nd harmonic (normalised so peak stays <= 1.0).
                let mainOsc = osc(shape, phase: phase)
                let harm2   = sin(2 * .pi * phase * 2) * 0.18
                sample = vol * env * (mainOsc + harm2) * (1.0 / 1.18)
            }
            L[i] = sample
            R[i] = sample
        }

        // Short fade in/out to guarantee a clean loop point (~11.6 ms at 44.1 kHz).
        applyFadeIO(L, R, samples: totalSamples, fadeLen: min(512, totalSamples / 8))
        return buf
    }

    // -----------------------------------------------------------------------
    // MARK: Track 0 — "Sunshine Sprint" (C major, 120 BPM, 16 s loop) [DAY]
    // -----------------------------------------------------------------------
    // Quarter note (q) = 0.500 s.  Loop = 32 q = 16.0 s exactly.
    // Melody: two 8-q phrases — ascending run then resolved peak.
    // Bass: C3-G3-F3-G3 (half notes), steady and bouncy.
    // Arpeggio: C4-E4-G4-C5 (eighth notes), sparkly constant motion.
    // Pad: C4-G4-F4-G4 (half notes), very soft harmonic warmth.

    private func buildTrack0_SunshineSprint() -> [AVAudioPCMBuffer] {
        let q: Float = 0.500
        let e: Float = q / 2
        let h: Float = q * 2

        // Equal-temperament Hz values (A4 = 440 Hz).
        let C3: Float = 130.813; let G3: Float = 195.998; let F3: Float = 174.614
        let C4: Float = 261.626; let E4: Float = 329.628; let G4: Float = 391.995; let F4: Float = 349.228
        let C5: Float = 523.251; let E5: Float = 659.255; let G5: Float = 783.991
        let A5: Float = 880.000; let C6: Float = 1046.502

        let totalSamples = Int(Float(format.sampleRate) * 16.0)

        // Melody — 16 quarter notes (one full sequence = 8 s, loops twice in 16 s buffer).
        let melodyNotes: [MusicalNote] = [
            .init(hz: C5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: E5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: G5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: A5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: G5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: E5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: C5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: G4, dur: q * 0.85, gap: q * 0.15),
            .init(hz: C5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: E5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: G5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: A5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: C6, dur: q * 0.85, gap: q * 0.15),
            .init(hz: A5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: G5, dur: q * 0.85, gap: q * 0.15),
            .init(hz: E5, dur: q * 0.85, gap: q * 0.15),
        ]

        // Bass — C3 G3 F3 G3 (half notes, 4 notes = 8 s, loops twice).
        let bassNotes: [MusicalNote] = [
            .init(hz: C3, dur: h * 0.80, gap: h * 0.20),
            .init(hz: G3, dur: h * 0.80, gap: h * 0.20),
            .init(hz: F3, dur: h * 0.80, gap: h * 0.20),
            .init(hz: G3, dur: h * 0.80, gap: h * 0.20),
        ]

        // Arpeggio — C4 E4 G4 C5 (eighth notes, repeats to fill).
        let arpNotes: [MusicalNote] = [
            .init(hz: C4, dur: e * 0.75, gap: e * 0.25),
            .init(hz: E4, dur: e * 0.75, gap: e * 0.25),
            .init(hz: G4, dur: e * 0.75, gap: e * 0.25),
            .init(hz: C5, dur: e * 0.75, gap: e * 0.25),
        ]

        // Pad — C4 G4 F4 G4 (half notes), very soft.
        let padNotes: [MusicalNote] = [
            .init(hz: C4, dur: h * 0.92, gap: h * 0.08),
            .init(hz: G4, dur: h * 0.92, gap: h * 0.08),
            .init(hz: F4, dur: h * 0.92, gap: h * 0.08),
            .init(hz: G4, dur: h * 0.92, gap: h * 0.08),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildNoteVoice(notes: melodyNotes, shape: .sine,     vol: 0.28, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: bassNotes,   shape: .triangle, vol: 0.22, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: arpNotes,    shape: .sine,     vol: 0.13, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: padNotes,    shape: .sine,     vol: 0.10, totalSamples: totalSamples) { voices.append(v) }
        return voices
    }

    // -----------------------------------------------------------------------
    // MARK: Track 1 — "Pixel Bounce" (G major, 132 BPM, ~14.55 s loop) [DAY]
    // -----------------------------------------------------------------------
    // Quarter note = 60/132 = 0.4545... s.  Loop = 32 q = 14.545... s.
    // Melody: skippy pentatonic G-major phrases with a rest beat for breathing room.
    // Bass: G3-D4-G3-B3 (half notes, staccato).
    // Arpeggio: G4-B4-D5-G5 (eighth notes, triangle for brightness).
    // Pad: G4-D4-G4-B4 (half notes), very soft.

    private func buildTrack1_PixelBounce() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 132.0
        let e: Float = q / 2
        let h: Float = q * 2

        let G3: Float = 195.998; let D4: Float = 293.665; let B3: Float = 246.942
        let G4: Float = 391.995; let B4: Float = 493.883; let D5: Float = 587.330
        let G5: Float = 783.991; let A5: Float = 880.000; let E5: Float = 659.255

        let loopDur: Float    = q * 32
        let totalSamples: Int = Int(Float(format.sampleRate) * loopDur)

        // Melody — 16 q slots (8 s per pass, loops twice in ~14.5 s buffer).
        let melodyNotes: [MusicalNote] = [
            .init(hz: G5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: E5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: D5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: B4,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: G4,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: B4,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: D5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: G5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: A5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: G5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: E5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: D5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: B4,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: D5,  dur: q * 0.75, gap: q * 0.25),
            .init(hz: G5,  dur: q * 0.60, gap: q * 0.40),
            .init(hz:   0, dur: q * 0.90, gap: q * 0.10),   // rest beat for bounce feel
        ]

        // Bass — G3 D4 G3 B3 (staccato half notes).
        let bassNotes: [MusicalNote] = [
            .init(hz: G3, dur: h * 0.65, gap: h * 0.35),
            .init(hz: D4, dur: h * 0.65, gap: h * 0.35),
            .init(hz: G3, dur: h * 0.65, gap: h * 0.35),
            .init(hz: B3, dur: h * 0.65, gap: h * 0.35),
        ]

        // Arpeggio — G4 B4 D5 G5 (eighth notes).
        let arpNotes: [MusicalNote] = [
            .init(hz: G4, dur: e * 0.70, gap: e * 0.30),
            .init(hz: B4, dur: e * 0.70, gap: e * 0.30),
            .init(hz: D5, dur: e * 0.70, gap: e * 0.30),
            .init(hz: G5, dur: e * 0.70, gap: e * 0.30),
        ]

        // Pad — G4 D4 G4 B4.
        let padNotes: [MusicalNote] = [
            .init(hz: G4, dur: h * 0.90, gap: h * 0.10),
            .init(hz: D4, dur: h * 0.90, gap: h * 0.10),
            .init(hz: G4, dur: h * 0.90, gap: h * 0.10),
            .init(hz: B4, dur: h * 0.90, gap: h * 0.10),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildNoteVoice(notes: melodyNotes, shape: .sine,     vol: 0.27, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: bassNotes,   shape: .triangle, vol: 0.21, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: arpNotes,    shape: .triangle, vol: 0.12, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: padNotes,    shape: .sine,     vol: 0.09, totalSamples: totalSamples) { voices.append(v) }
        return voices
    }

    // -----------------------------------------------------------------------
    // MARK: Track 2 — "Cozy Campfire" (F major, 108 BPM, ~17.78 s loop) [EVENING]
    // -----------------------------------------------------------------------
    // Quarter note = 60/108 = 0.5556 s.  Loop = 32 q = 17.778 s.
    // Happy and warm F major — a touch more relaxed than the day tracks but
    // still bright and major throughout. Melody has a gentle sing-along arc.

    private func buildTrack2_CozyCampfire() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 108.0
        let e: Float = q / 2
        let h: Float = q * 2

        let F3: Float = 174.614; let C4: Float = 261.626; let A3: Float = 220.000
        let F4: Float = 349.228; let A4: Float = 440.000; let C5: Float = 523.251
        let F5: Float = 698.456; let G5: Float = 783.991; let E5: Float = 659.255
        let Bb4: Float = 466.164; let D5: Float = 587.330; let G4: Float = 391.995

        let loopDur: Float    = q * 32
        let totalSamples: Int = Int(Float(format.sampleRate) * loopDur)

        // Melody — warm singable F-major phrase (16 q slots = 8.89 s, loops twice).
        let melodyNotes: [MusicalNote] = [
            .init(hz: F5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: E5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: F5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: G5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: F5,  dur: h * 0.88, gap: h * 0.12),    // half note — phrase peak
            .init(hz: C5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: D5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: C5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: A4,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: Bb4, dur: h * 0.88, gap: h * 0.12),
            .init(hz: A4,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: G4,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: A4,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: C5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: F4,  dur: h * 0.80, gap: h * 0.20),    // half note resolution
            .init(hz:   0, dur: q * 0.95, gap: q * 0.05),    // breath rest
        ]

        // Bass — F3 C4 F3 A3 (walking half notes, gentle).
        let bassNotes: [MusicalNote] = [
            .init(hz: F3, dur: h * 0.75, gap: h * 0.25),
            .init(hz: C4, dur: h * 0.75, gap: h * 0.25),
            .init(hz: F3, dur: h * 0.75, gap: h * 0.25),
            .init(hz: A3, dur: h * 0.75, gap: h * 0.25),
        ]

        // Arpeggio — F4 A4 C5 F5 (eighth notes).
        let arpNotes: [MusicalNote] = [
            .init(hz: F4, dur: e * 0.78, gap: e * 0.22),
            .init(hz: A4, dur: e * 0.78, gap: e * 0.22),
            .init(hz: C5, dur: e * 0.78, gap: e * 0.22),
            .init(hz: F5, dur: e * 0.78, gap: e * 0.22),
        ]

        // Pad — F4 C4 F4 A4 (half notes), very soft.
        let padNotes: [MusicalNote] = [
            .init(hz: F4, dur: h * 0.93, gap: h * 0.07),
            .init(hz: C4, dur: h * 0.93, gap: h * 0.07),
            .init(hz: F4, dur: h * 0.93, gap: h * 0.07),
            .init(hz: A4, dur: h * 0.93, gap: h * 0.07),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildNoteVoice(notes: melodyNotes, shape: .sine,     vol: 0.26, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: bassNotes,   shape: .triangle, vol: 0.19, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: arpNotes,    shape: .sine,     vol: 0.11, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: padNotes,    shape: .sine,     vol: 0.09, totalSamples: totalSamples) { voices.append(v) }
        return voices
    }

    // -----------------------------------------------------------------------
    // MARK: Track 3 — "Starlight Waltz" (D major, 120 BPM, 12 s loop) [EVENING]
    // -----------------------------------------------------------------------
    // Quarter note = 0.500 s.  Loop = 24 q (8 bars of 3/4) = 12.0 s exactly.
    // Lilting waltz feel — happy but gentle, like a cheerful music-box tune.
    // D major uses F# (Fs) = 369.994 Hz.

    private func buildTrack3_StarlightWaltz() -> [AVAudioPCMBuffer] {
        let q: Float = 0.500
        let e: Float = q / 2
        let h: Float = q * 2

        let D3: Float  = 146.832; let A3: Float  = 220.000; let Fs3: Float = 184.997
        let D4: Float  = 293.665; let Fs4: Float = 369.994; let A4: Float  = 440.000
        let D5: Float  = 587.330; let Fs5: Float = 739.989; let A5: Float  = 880.000
        let E5: Float  = 659.255; let G5: Float  = 783.991

        let loopDur: Float    = q * 24   // 12.0 s
        let totalSamples: Int = Int(Float(format.sampleRate) * loopDur)

        // Melody — 24 quarter-note events (8 x 3/4 bars).
        // Last bar uses a 2.8q note + 0.2q gap = 3q total to complete the phrase.
        let melodyNotes: [MusicalNote] = [
            // Bar 1: D5 Fs5 A5
            .init(hz: D5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: Fs5, dur: q * 0.88, gap: q * 0.12),
            .init(hz: A5,  dur: q * 0.88, gap: q * 0.12),
            // Bar 2: A5 G5 E5
            .init(hz: A5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: G5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: E5,  dur: q * 0.88, gap: q * 0.12),
            // Bar 3: Fs5 A5 D5
            .init(hz: Fs5, dur: q * 0.88, gap: q * 0.12),
            .init(hz: A5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: D5,  dur: q * 0.88, gap: q * 0.12),
            // Bar 4: E5 Fs5 (dotted half = two q)
            .init(hz: E5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: Fs5, dur: h * 0.85, gap: h * 0.15),
            // Bar 5: D5 Fs5 A5
            .init(hz: D5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: Fs5, dur: q * 0.88, gap: q * 0.12),
            .init(hz: A5,  dur: q * 0.88, gap: q * 0.12),
            // Bar 6: G5 E5 D5
            .init(hz: G5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: E5,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: D5,  dur: q * 0.88, gap: q * 0.12),
            // Bar 7: A4 Fs5 A5
            .init(hz: A4,  dur: q * 0.88, gap: q * 0.12),
            .init(hz: Fs5, dur: q * 0.88, gap: q * 0.12),
            .init(hz: A5,  dur: q * 0.88, gap: q * 0.12),
            // Bar 8: D5 dotted half (3 q = fills bar, total = 24 q)
            .init(hz: D5,  dur: q * 2.80, gap: q * 0.20),
        ]

        // Bass — D3 A3 D3 Fs3 (half notes, gentle waltz feel).
        let bassNotes: [MusicalNote] = [
            .init(hz: D3,  dur: h * 0.72, gap: h * 0.28),
            .init(hz: A3,  dur: h * 0.72, gap: h * 0.28),
            .init(hz: D3,  dur: h * 0.72, gap: h * 0.28),
            .init(hz: Fs3, dur: h * 0.72, gap: h * 0.28),
        ]

        // Arpeggio — D4 Fs4 A4 D5 (eighth notes, music-box sparkle).
        let arpNotes: [MusicalNote] = [
            .init(hz: D4,  dur: e * 0.72, gap: e * 0.28),
            .init(hz: Fs4, dur: e * 0.72, gap: e * 0.28),
            .init(hz: A4,  dur: e * 0.72, gap: e * 0.28),
            .init(hz: D5,  dur: e * 0.72, gap: e * 0.28),
        ]

        // Pad — D4 A4 D4 A4 (half notes, soft sustained notes).
        let padNotes: [MusicalNote] = [
            .init(hz: D4,  dur: h * 0.92, gap: h * 0.08),
            .init(hz: A4,  dur: h * 0.92, gap: h * 0.08),
            .init(hz: D4,  dur: h * 0.92, gap: h * 0.08),
            .init(hz: A4,  dur: h * 0.92, gap: h * 0.08),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildNoteVoice(notes: melodyNotes, shape: .sine,     vol: 0.25, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: bassNotes,   shape: .triangle, vol: 0.18, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: arpNotes,    shape: .sine,     vol: 0.11, totalSamples: totalSamples) { voices.append(v) }
        if let v = buildNoteVoice(notes: padNotes,    shape: .sine,     vol: 0.08, totalSamples: totalSamples) { voices.append(v) }
        return voices
    }

    /// Smooth pad envelope: retained for any future callers.
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
    // Birds: 3 distinct whistle motifs, played at random ~10-35 s intervals via
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
        // Random interval 10-35 s between chirps.
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

        // Simple low-pass via one-pole IIR: y[n] = alpha*x[n] + (1-alpha)*y[n-1]
        let alpha: Float  = 0.003   // very heavy LP — wind-like rumble
        var prevL: Float  = 0
        var prevR: Float  = 0
        let lfoFreq: Float = 0.04   // gentle swell frequency

        for i in 0 ..< n {
            let t    = Float(i) / sr
            let lfo  = 0.5 + 0.5 * sin(2 * .pi * lfoFreq * t + 0.7)   // 0...1 swell
            let amp  = 0.35 + 0.25 * lfo                                // 0.35...0.60

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
        // Note 1 at 0 s: 1800-2400 Hz sweep; Note 2 at 0.25 s: 2200-2800 Hz
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
    // MARK: Per-material break sounds
    // -----------------------------------------------------------------------
    //
    // materialClass: 0=generic, 1=stone/rock, 2=wood, 3=dirt/grass,
    //                4=sand/gravel, 5=glass, 6=leaves/plant, 7=metal/ore
    //
    // Each class has kBreakVariants pre-rendered pitch variants so rapid
    // repeated hits sound different from one another.

    private let kBreakVariants = 4
    // breakMaterialBuffers[materialClass][variantIndex]
    private var breakMaterialBuffers: [[AVAudioPCMBuffer]] = []
    private var breakVariantCounters: [Int] = []

    /// Call from the renderer when a block of a given material class breaks.
    /// materialClass out of range falls back to 0.
    func playBreak(materialClass: Int) {
        guard sfxEnabled, let engine, engine.isRunning else { return }
        let cls = (materialClass >= 0 && materialClass < breakMaterialBuffers.count)
                  ? materialClass : 0
        guard !breakMaterialBuffers[cls].isEmpty else { return }

        let varIdx = breakVariantCounters[cls] % kBreakVariants
        breakVariantCounters[cls] = varIdx + 1
        let buf = breakMaterialBuffers[cls][varIdx % breakMaterialBuffers[cls].count]

        let node = idleSfxNode()
        node.scheduleBuffer(buf, completionHandler: nil)
        node.play()
    }

    private func buildBreakMaterialBuffers() {
        let makers: [() -> AVAudioPCMBuffer?] = [
            makeBreakGeneric,    // 0
            makeBreakStone,      // 1
            makeBreakWood,       // 2
            makeBreakDirt,       // 3
            makeBreakSand,       // 4
            makeBreakGlass,      // 5
            makeBreakLeaves,     // 6
            makeBreakMetal,      // 7
        ]

        // Pitch-shift ratios for 4 variants (in semitones: -2, -0.7, +0.7, +2)
        let ratios: [Float] = [
            pow(2, -2.0/12),
            pow(2, -0.7/12),
            pow(2,  0.7/12),
            pow(2,  2.0/12),
        ]

        breakMaterialBuffers = []
        breakVariantCounters = Array(repeating: 0, count: makers.count)

        for make in makers {
            var variants: [AVAudioPCMBuffer] = []
            if let base = make() {
                for ratio in ratios {
                    if let v = pitchShift(base, ratio: ratio) {
                        variants.append(v)
                    }
                }
                if variants.isEmpty { variants.append(base) }
            }
            breakMaterialBuffers.append(variants)
        }
    }

    // MARK: Generic break (class 0) — punchy crumble: layered noise burst + pitched thud
    private func makeBreakGeneric() -> AVAudioPCMBuffer? {
        let dur: Float = 0.22
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            // Two-stage envelope: sharp initial crack + short tail
            let crackEnv = self.envelope(t, a: 0.002, d: 0.03, s: 0.0, sLen: 0.0, r: 0.04, total: 0.07)
            let tailEnv  = self.envelope(t, a: 0.01,  d: 0.06, s: 0.2, sLen: 0.04, r: 0.09, total: dur)
            // Pitched thud sweeping down
            let hz    = Float(280) * pow(0.25, t * 5)
            let tone  = 0.45 * sin(2 * .pi * hz * t)
            // Noise with band emphasis
            let noise = 0.55 * self.whitenoise()
            let crack = crackEnv * noise * 0.9
            let body  = tailEnv  * (tone + noise * 0.4)
            return (crack + body) * 0.80
        }
    }

    // MARK: Stone (class 1) — sharp cracky crunch + low thud + gravel rattle tail
    private func makeBreakStone() -> AVAudioPCMBuffer? {
        let dur: Float = 0.28
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            // Crack transient: very fast bright noise spike
            let crackEnv = self.envelope(t, a: 0.001, d: 0.025, s: 0.0, sLen: 0.0, r: 0.03, total: 0.06)
            // Low thud body: low sine sweeping down, medium noise
            let thudEnv  = self.envelope(t, a: 0.003, d: 0.05, s: 0.25, sLen: 0.05, r: 0.10, total: dur)
            // Gravel rattle tail (starts at 0.08 s)
            let rattleT  = t - 0.08
            let rattleEnv: Float = rattleT > 0
                ? self.envelope(rattleT, a: 0.005, d: 0.04, s: 0.15, sLen: 0.06, r: 0.07, total: 0.19)
                : 0
            let hz    = Float(180) * pow(0.18, t * 4)
            let tone  = 0.50 * sin(2 * .pi * hz * t)
            let rawNoise = self.whitenoise()
            let crack = crackEnv * rawNoise * 1.0
            let thud  = thudEnv  * (tone * 0.7 + rawNoise * 0.45)
            let rattle = rattleEnv * rawNoise * 0.30
            return (crack + thud + rattle) * 0.82
        }
    }

    // MARK: Wood (class 2) — hollow woody snap/crack: resonant body + knock
    private func makeBreakWood() -> AVAudioPCMBuffer? {
        let dur: Float = 0.24
        return synthesize(duration: dur) { i, sr in
            let t = Float(i) / sr
            // Sharp initial snap transient (very short noise burst)
            let snapEnv = self.envelope(t, a: 0.001, d: 0.015, s: 0.0, sLen: 0.0, r: 0.02, total: 0.04)
            // Resonant hollow body: two sine tones (fundamental + 2nd harmonic of wood)
            let bodyEnv = self.envelope(t, a: 0.003, d: 0.04, s: 0.30, sLen: 0.06, r: 0.11, total: dur)
            // Wood hollow resonance ~ 220-280 Hz range, sweeps down
            let hz1   = Float(240) * pow(0.40, t * 3)
            let hz2   = hz1 * 1.5   // hollow box mode
            let body  = bodyEnv * (0.55 * sin(2 * .pi * hz1 * t) + 0.25 * sin(2 * .pi * hz2 * t))
            let snap  = snapEnv * self.whitenoise() * 0.60
            // Short woody noise burst at start
            let woodNoise = self.envelope(t, a: 0.002, d: 0.03, s: 0.0, sLen: 0.0, r: 0.04, total: 0.07)
                            * self.whitenoise() * 0.35
            return (snap + body + woodNoise) * 0.85
        }
    }

    // MARK: Dirt/grass (class 3) — soft muffled crumble/thud
    private func makeBreakDirt() -> AVAudioPCMBuffer? {
        let dur: Float = 0.20
        var prevLP: Float = 0
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.005, d: 0.04, s: 0.35, sLen: 0.05, r: 0.10, total: dur)
            // Heavy low-pass filter — muffled, earthy
            let alpha: Float = 0.025
            let raw = self.whitenoise()
            prevLP = alpha * raw + (1 - alpha) * prevLP
            // Very low fundamental thud (70-100 Hz)
            let hz   = Float(85) * pow(0.30, t * 3)
            let tone = 0.40 * sin(2 * .pi * hz * t)
            // Quiet mid noise for texture
            let midNoise = 0.20 * self.whitenoise()
            return env * (prevLP * 3.5 * 0.55 + tone + midNoise) * 0.80
        }
    }

    // MARK: Sand/gravel (class 4) — granular hiss + soft pour
    private func makeBreakSand() -> AVAudioPCMBuffer? {
        let dur: Float = 0.30
        var prevLPState: Float = 0   // one-pole LP filter state
        return synthesize(duration: dur) { i, sr in
            let t    = Float(i) / sr
            // Main body: rising then falling (pour shape)
            let env  = self.envelope(t, a: 0.02, d: 0.08, s: 0.40, sLen: 0.08, r: 0.10, total: dur)
            // High-pass emphasis for graininess (1-pole HP: hp = raw - LP(raw))
            let raw  = self.whitenoise()
            let lp   = 0.15 * raw + 0.85 * prevLPState
            prevLPState = lp
            let hp   = raw - lp   // approximate HP
            // Mix: mostly high-freq hiss (granular), small amount of low pour thump
            let thump = 0.15 * sin(2 * .pi * Float(60) * pow(0.5, t * 4) * t)
            return env * (hp * 0.65 + raw * 0.20 + thump) * 0.80
        }
    }

    // MARK: Glass (class 5) — bright shatter: high-freq noise burst + tinkle partials
    private func makeBreakGlass() -> AVAudioPCMBuffer? {
        let dur: Float = 0.35
        // Tinkle frequencies (high, slightly inharmonic — shard modes)
        let tinkleHz: [Float] = [3200, 4700, 5900, 7100, 8300]
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            // Initial shatter burst: very sharp, bright
            let shatterEnv = self.envelope(t, a: 0.001, d: 0.02, s: 0.0, sLen: 0.0, r: 0.03, total: 0.05)
            // Tinkle partials: multiple high-pitched decaying sines staggered in onset
            var tinkle: Float = 0
            for (idx, hz) in tinkleHz.enumerated() {
                let onset = Float(idx) * 0.015
                let nt    = t - onset
                guard nt >= 0 else { continue }
                let decay = exp(-nt * (8.0 + Float(idx) * 3.0))
                tinkle   += decay * 0.12 * sin(2 * .pi * hz * nt)
            }
            // Brief noise burst
            let burst = shatterEnv * self.whitenoise() * 0.85
            return (burst + tinkle) * 0.90
        }
    }

    // MARK: Leaves/plant (class 6) — light rustly crunch
    private func makeBreakLeaves() -> AVAudioPCMBuffer? {
        let dur: Float = 0.18
        var prevMid: Float = 0
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            let env = self.envelope(t, a: 0.004, d: 0.03, s: 0.30, sLen: 0.06, r: 0.08, total: dur)
            // Band-pass emphasis: mid-high crinkle (0.08 LP - heavy LP = band)
            let raw = self.whitenoise()
            let lp1  = 0.06 * raw + 0.94 * prevMid
            prevMid  = lp1
            let hp   = raw - lp1            // HP component
            // Very soft low thud for stem snap
            let thud = 0.15 * sin(2 * .pi * Float(130) * t) * max(0, 1 - t * 12)
            // Random amplitude flutter (leaf flutter texture)
            let flutter: Float = 0.75 + 0.25 * self.whitenoise()
            return env * (hp * 0.60 * flutter + thud) * 0.75
        }
    }

    // MARK: Metal/ore (class 7) — clink/clang over stone-like crunch
    private func makeBreakMetal() -> AVAudioPCMBuffer? {
        let dur: Float = 0.32
        // Two metallic ring partials (inharmonic, mid-high)
        let ringHz: [Float] = [1050, 1640, 2380]
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            // Stone-like crack layer (same as stone but shorter)
            let crackEnv = self.envelope(t, a: 0.001, d: 0.02, s: 0.0, sLen: 0.0, r: 0.025, total: 0.05)
            let thudEnv  = self.envelope(t, a: 0.003, d: 0.04, s: 0.20, sLen: 0.04, r: 0.08, total: dur)
            let hz    = Float(160) * pow(0.20, t * 4)
            let thud  = thudEnv * (0.45 * sin(2 * .pi * hz * t) + 0.30 * self.whitenoise())
            let crack = crackEnv * self.whitenoise() * 0.85
            // Metallic ring: fast-decaying sine partials
            var ring: Float = 0
            for (idx, rHz) in ringHz.enumerated() {
                let onset  = Float(idx) * 0.008
                let nt     = t - onset
                guard nt >= 0 else { continue }
                let decay  = exp(-nt * (5.0 + Float(idx) * 2.5))
                ring      += decay * 0.18 * sin(2 * .pi * rHz * nt)
            }
            return (crack + thud + ring) * 0.85
        }
    }

    // -----------------------------------------------------------------------
    // MARK: SFX synthesis — original 8 + 4 new
    // -----------------------------------------------------------------------

    private func buildAllSfxBuffers() {
        sfxBuffers[.mine]          = makeMineBuffer()
        sfxBuffers[.place]         = makePlaceBuffer()
        // play(.breakBlock) is intercepted before this buffer is used; it routes
        // to playBreak(materialClass:0). Buffer retained so sfxBuffers dict lookup
        // doesn't silently drop any future path that checks for it.
        sfxBuffers[.breakBlock]    = makeBreakGeneric()
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
        // Build per-material break buffers
        buildBreakMaterialBuffers()
    }

    // MARK: Pitch-variant pre-render
    //
    // For frequently-repeated SFX (mine, place, breakBlock, step) we pre-render
    // 4 pitch variants (+/-3 semitones) and rotate through them so repeated
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

    /// jump — tiny upward chirp: sine swept 300-600 Hz, ~140 ms
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

    /// pickup — item collected: bright sparkle ding, E6-G6-B6 upward arpeggio, ~360 ms
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
            // Cutoff sweeps from low to mid as drawer opens
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
