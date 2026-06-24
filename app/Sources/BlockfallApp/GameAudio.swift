// ============================================================================
// Blockfall — GameAudio
// Fully synthesized audio: no asset files. Uses AVAudioEngine + AVAudioPlayerNode
// with manually-filled AVAudioPCMBuffer(s). All synthesis is PCM Float32 at
// 44 100 Hz stereo. Safe to call from main thread; all methods become no-ops if
// the engine failed to initialize (headless / no-audio environment).
//
// PUBLIC API ADDITIONS vs original:
//   Sfx: + splash, pickup, hurt
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
        case hurt           // sharp descending impact — player took damage
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
            guard engine?.isRunning == true && musicEnabled else { return }
            // Crossfade to the first track of the new group rather than hard-cutting.
            // Cancel the current rotation timer so it restarts from the new track.
            trackTimer?.invalidate()
            trackTimer = nil
            let newIdx = firstTrackIndex(for: currentTrackGroup)
            currentTrackIndex = newIdx
            crossFadeToTrack(newIdx)
            scheduleTrackRotation()
        }
    }

    // -----------------------------------------------------------------------
    // MARK: SFX playback (with +/-pitch variation to avoid monotony)
    // -----------------------------------------------------------------------

    func play(_ sfx: Sfx) {
        guard sfxEnabled, isReady, let engine, engine.isRunning else { return }

        // Route breakBlock through the per-material path so legacy callers
        // automatically get the punchier generic sound + variant cycling.
        if sfx == .breakBlock {
            playBreak(materialClass: 0)
            return
        }

        guard let buffer = sfxBuffers[sfx] else { return }

        let node = idleSfxNode()

        // Pitch variety without an extra node: pick a pre-rendered +/- pitch
        // variant (built at startup) for the frequently-repeated sounds.
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

    private var isReady = false

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
    // outgoing bank fades from 1→0, then silence, then incoming bank fades from 0→1.
    private var musicBankNodes:  [AVAudioPlayerNode] = []   // 8 nodes (4 per bank)
    private var musicBankMixers: [AVAudioMixerNode]  = []   // 2 per-bank sub-mixers
    private var musicMixer:      AVAudioMixerNode?
    private var activeBank:      Int = 0                    // 0 or 1

    // Silence-gap transition timing (seconds):
    //   kFadeOutDur  — outgoing track ramps 1→0
    //   kSilenceDur  — gap of actual silence between tracks
    //   kFadeInDur   — incoming track ramps 0→1
    // Total ≈ 6.75 s.  No two tracks ever play simultaneously.
    private let kFadeOutDur:  Double = 2.5
    private let kSilenceDur:  Double = 1.75
    private let kFadeInDur:   Double = 2.5

    // How long before the next rotation fires.
    // Tracks are now 72–90 s; we rotate every 90 s so the listener hears the full
    // arrangement once before the next track begins.
    private let kTrackRotationInterval: Double = 90.0

    private enum TrackGroup { case day, evening }
    private var currentTrackGroup: TrackGroup = .day
    private var currentTrackIndex: Int        = 0
    private var trackTimer:     Timer?
    private var crossfadeTimer: Timer?   // running crossfade step timer

    // Pre-rendered track buffers: [trackID][voiceIndex]
    // Tracks 0,1,4,5,8,9  = day;  Tracks 2,3,6,7,10,11 = evening
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
        windNode.volume = 0.30   // #2: was 0.55 — the filtered-noise wind read as a weird warbling whitenoise
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

        // Store engine reference now so the graph exists; not yet started.
        self.engine = eng

        // Synthesize on a background thread. #1: build the FIRST track first and start
        // music right away, so the player hears music within a second or two instead of
        // waiting for ALL TWELVE long tracks to synthesize (which took minutes). The
        // remaining tracks build in the background while track 0 loops; the rotation
        // timer waits for a track to be ready before switching to it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // SFX are small and needed for early interactions; build them + the first
            // music track, then go ready so music + sound start fast.
            self.buildAllSfxBuffers()
            self.buildSfxVariants()
            let firstTrack = self.buildTrack0_SunshineSprint()   // day track 0 = first to play
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.allTrackBuffers = [firstTrack]
                eng.prepare()
                self.isReady = true
                if eng.isRunning && self.musicEnabled { self.startMusic() }
            }
            // Build the remaining eleven tracks in the background, then publish the full
            // set on the main thread (allTrackBuffers is read by the music timers there).
            var all: [[AVAudioPCMBuffer]] = [firstTrack]
            all.append(self.buildTrack1_PixelBounce())
            all.append(self.buildTrack2_CozyCampfire())
            all.append(self.buildTrack3_StarlightWaltz())
            all.append(self.buildTrack4_AdventureMarch())
            all.append(self.buildTrack5_RainbowRoad())
            all.append(self.buildTrack6_FireflyLullaby())
            all.append(self.buildTrack7_MoonGarden())
            all.append(self.buildTrack8_CopperRun())
            all.append(self.buildTrack9_Voltage())
            all.append(self.buildTrack10_LostRuins())
            all.append(self.buildTrack11_DuskDrift())
            DispatchQueue.main.async { [weak self] in self?.allTrackBuffers = all }
            // Ambience last (lowest priority for startup).
            self.buildAmbienceBuffers()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if eng.isRunning && self.ambienceEnabled { self.startAmbience() }
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Music — twelve tracks: cheerful kid-friendly + cooler grown-up
    // -----------------------------------------------------------------------
    //
    // Track 0: "Sunshine Sprint"  — C major, 120 BPM  [DAY]
    //   Bouncy melody over walking bass + sparkling arpeggios.
    //
    // Track 1: "Pixel Bounce"     — G major, 132 BPM  [DAY]
    //   Skippy pentatonic melody, bright triangle arpeggios, punchy bass.
    //
    // Track 2: "Cozy Campfire"    — F major, 108 BPM  [EVENING]
    //   Warm and cheerful — all-major, a touch softer and dreamier.
    //
    // Track 3: "Starlight Waltz"  — D major, 120 BPM, 3/4 feel  [EVENING]
    //   Lilting waltz, gentle melody, happy but calm.
    //
    // Track 4: "Adventure March"  — A major, 126 BPM  [DAY]
    //   Bold dotted-rhythm march feel, bright and energetic.
    //
    // Track 5: "Rainbow Road"     — Bb major, 116 BPM  [DAY]
    //   Joyful chromatic-flavored melody with a skip-hop groove.
    //
    // Track 6: "Firefly Lullaby"  — G major, 96 BPM  [EVENING]
    //   Gentle pentatonic melody, soft and dreamy but still happy.
    //
    // Track 7: "Moon Garden"      — E major, 104 BPM, 6/8 feel  [EVENING]
    //   Flowing lush 6/8 feel, warm and lush.
    //
    // -- Cooler, more grown-up tracks (still upbeat / fun) --
    //
    // Track 8:  "Copper Run"      — D minor→F major, 118 BPM  [DAY]
    //   Driving minor-to-major chiptune platformer progression.
    //   Verse in Dm (D F A), chorus lifts to F major (F A C).
    //
    // Track 9:  "Voltage"         — E minor, 128 BPM  [DAY]
    //   Punchy laid-back groove with a walking minor-pentatonic bassline.
    //   Feels like a cooler side-scroller; bridge opens to G major.
    //
    // Track 10: "Lost Ruins"      — A minor, 100 BPM  [EVENING]
    //   Epic-but-gentle exploration theme in Am. Melodic arch spans Am→C→G.
    //   Bridge modulates to F major for contrast before return.
    //
    // Track 11: "Dusk Drift"      — C minor→Eb major, 92 BPM  [EVENING]
    //   Cool laid-back groove, half-time feel. Verse in Cm; chorus brightens
    //   to Eb major. Synth-pad texture, sparse bass hits.
    //
    // Each track is synthesized as 4 independent looping voice buffers:
    //   Voice 0 = melody   (sine + slight harmonic blend, medium vol)
    //   Voice 1 = bass     (triangle, lower octave, punchy envelope)
    //   Voice 2 = arpeggio (sine, fast ascending broken chord, light vol)
    //   Voice 3 = pad      (sine, sustained chord, very soft backing)
    //
    // Day group:     Tracks 0,1,4,5,8,9
    // Evening group: Tracks 2,3,6,7,10,11
    // Rotation: tracks cycle within their group every 90 s via crossFadeToTrack.

    private func startMusic() {
        guard isReady else { return }
        // Buffers are always built (off the main thread) before isReady flips; never
        // synthesize here — that would freeze the main thread for seconds.
        guard !allTrackBuffers.isEmpty else { return }

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

    // Indices for each group: day → 0,1,4,5,8,9   evening → 2,3,6,7,10,11
    private func trackIndices(for group: TrackGroup) -> [Int] {
        switch group {
        case .day:     return [0, 1, 4, 5, 8, 9]
        case .evening: return [2, 3, 6, 7, 10, 11]
        }
    }

    private func firstTrackIndex(for group: TrackGroup) -> Int {
        return trackIndices(for: group)[0]
    }

    private func nextTrackIndex(after idx: Int) -> Int {
        // Cycle within the four tracks of the current group.
        let indices = trackIndices(for: currentTrackGroup)
        let pos     = indices.firstIndex(of: idx) ?? 0
        return indices[(pos + 1) % indices.count]
    }

    /// Start looping a track's voice buffers on the four nodes of `bank` (0 or 1).
    /// The caller is responsible for setting `musicBankMixers[bank].outputVolume` beforehand.
    private func playTrackOnBank(_ idx: Int, bank: Int) {
        guard idx < allTrackBuffers.count else { return }
        let voiceBuffers  = allTrackBuffers[idx]
        let nodeOffset    = bank * 4
        // Schedule every voice first, THEN start them all at one shared host time
        // so the 4 layers begin sample-aligned. (alignVoiceLengths keeps them equal
        // length; separate node.play() calls let them start in different render
        // cycles and drift ~11ms, which never self-corrects across loops.)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let delayNs = UInt64(0.08 * 1_000_000_000)   // 80 ms ahead — enough to schedule
        let delayHost = (tb.numer != 0) ? delayNs * UInt64(tb.denom) / UInt64(tb.numer) : delayNs
        let when = AVAudioTime(hostTime: mach_absolute_time() + delayHost)
        for i in 0 ..< 4 {
            let node = musicBankNodes[nodeOffset + i]
            node.stop()
            guard i < voiceBuffers.count else { continue }
            node.scheduleBuffer(voiceBuffers[i], at: nil, options: .loops, completionHandler: nil)
        }
        for i in 0 ..< 4 where i < voiceBuffers.count {
            musicBankNodes[nodeOffset + i].play(at: when)
        }
    }

    private func scheduleTrackRotation() {
        // Rotate every 60 seconds — long enough to enjoy a melody before it transitions.
        trackTimer = Timer.scheduledTimer(withTimeInterval: kTrackRotationInterval, repeats: false) { [weak self] _ in
            guard let self, self.musicEnabled, self.engine?.isRunning == true else { return }
            let next = self.nextTrackIndex(after: self.currentTrackIndex)
            // #1: the background track build may not have reached this index yet. If so,
            // keep looping the current track and try again next interval instead of
            // crossfading to a missing buffer (which would go silent).
            if next >= self.allTrackBuffers.count {
                self.scheduleTrackRotation()
                return
            }
            self.currentTrackIndex = next
            self.crossFadeToTrack(self.currentTrackIndex)
            self.scheduleTrackRotation()
        }
    }

    /// Silence-gap transition: out → silence → in.
    ///
    /// Phase 1 (kFadeOutDur  ≈ 2.5 s): outgoing bank ramps 1 → 0.
    /// Phase 2 (kSilenceDur  ≈ 1.75 s): both banks held at 0 (actual silence).
    /// Phase 3 (kFadeInDur   ≈ 2.5 s): incoming bank ramps 0 → 1.
    /// Total ≈ 6.75 s.
    ///
    /// Safety guarantees:
    ///   • Cancels any in-flight crossfadeTimer before starting a new one —
    ///     bank volumes can never fight between two concurrent faders.
    ///   • No two tracks ever play simultaneously (incoming bank nodes start only
    ///     at the end of Phase 2, just before Phase 3 begins).
    ///   • Volume is clamped to exact 0.0 / 1.0 at phase boundaries — no float drift.
    ///   • Outgoing bank nodes are stopped immediately when their volume reaches 0,
    ///     freeing scheduling resources during the silence gap.
    ///   • Power-curve fade (exponent 2.0) prevents audible clicks at ramp edges.

    private func crossFadeToTrack(_ idx: Int) {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil

        let outBank = activeBank
        let inBank  = 1 - activeBank
        activeBank  = inBank

        // Snap both banks to a known state before we start timing.
        musicBankMixers[outBank].outputVolume = 1.0
        musicBankMixers[inBank].outputVolume  = 0.0
        // Silence the incoming bank's nodes until Phase 3.
        let inOffset = inBank * 4
        for i in 0 ..< 4 { musicBankNodes[inOffset + i].stop() }

        // ---- Phase constants ------------------------------------------------
        // 50 ms per step → smooth ~20 Hz volume updates across all phases.
        let stepDur  = 0.050                                                    // 50 ms
        let stepsOut  = Int((kFadeOutDur / stepDur).rounded())                  // ≈ 50
        let stepsDead = Int((kSilenceDur  / stepDur).rounded())                 // ≈ 35
        let stepsIn   = Int((kFadeInDur   / stepDur).rounded())                 // ≈ 50

        // Total step budget: fade-out + silence + fade-in.
        let totalSteps = stepsOut + stepsDead + stepsIn
        var step = 0

        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: stepDur, repeats: true) {
            [weak self] timer in
            guard let self else { timer.invalidate(); return }
            step += 1

            if step <= stepsOut {
                // --- Phase 1: fade out ---
                let progress = Float(step) / Float(stepsOut)
                // Power-2 ease-in: starts fast then slows to zero — smooth tail.
                let gain = pow(1.0 - progress, 2.0)
                self.musicBankMixers[outBank].outputVolume = max(0, gain)

                if step == stepsOut {
                    // Outgoing bank is now silent — stop its nodes to free resources.
                    self.musicBankMixers[outBank].outputVolume = 0.0
                    let offset = outBank * 4
                    for i in 0 ..< 4 { self.musicBankNodes[offset + i].stop() }
                    // Prime the incoming bank at zero volume so it is ready for Phase 3.
                    self.musicBankMixers[inBank].outputVolume = 0.0
                    self.playTrackOnBank(idx, bank: inBank)
                }

            } else if step <= stepsOut + stepsDead {
                // --- Phase 2: silence — both banks already at 0, nothing to do.
                //     Return early from this timer tick; wait for Phase 3.
                return

            } else if step <= totalSteps {
                // --- Phase 3: fade in ---
                let progress = Float(step - stepsOut - stepsDead) / Float(stepsIn)
                // Power-2 ease-out: starts slow, accelerates — avoids abrupt jump.
                let gain = pow(progress, 2.0)
                self.musicBankMixers[inBank].outputVolume = min(1, gain)

                if step >= totalSteps {
                    timer.invalidate()
                    self.crossfadeTimer = nil
                    self.musicBankMixers[inBank].outputVolume  = 1.0
                    self.musicBankMixers[outBank].outputVolume = 0.0
                }
            } else {
                // Guard: should not reach here, but clamp and stop if we do.
                timer.invalidate()
                self.crossfadeTimer = nil
                self.musicBankMixers[inBank].outputVolume  = 1.0
                self.musicBankMixers[outBank].outputVolume = 0.0
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Track buffer synthesis
    // -----------------------------------------------------------------------
    //
    // Each track is a full ~72–90 s arrangement built from sections.
    // Sections are concatenated into one large buffer per voice; AVAudioPlayerNode
    // schedules that buffer on .loops so the whole arrangement plays through before
    // repeating cleanly at the start.
    //
    // Section forms used:
    //   Intro (sparse) → Verse A → Chorus (fuller/higher) → Verse B (varied) →
    //   Chorus → Bridge (chord/register shift) → Chorus (out, higher octave)
    //
    // Voices: melody | bass | arpeggio | pad  (same architecture as before).
    // All 4 voices in a track receive the same section list so they stay in sync.

    private func buildAllTrackBuffers() {
        allTrackBuffers = []
        allTrackBuffers.append(buildTrack0_SunshineSprint())   // Day 0
        allTrackBuffers.append(buildTrack1_PixelBounce())      // Day 1
        allTrackBuffers.append(buildTrack2_CozyCampfire())     // Evening 2
        allTrackBuffers.append(buildTrack3_StarlightWaltz())   // Evening 3
        allTrackBuffers.append(buildTrack4_AdventureMarch())   // Day 4
        allTrackBuffers.append(buildTrack5_RainbowRoad())      // Day 5
        allTrackBuffers.append(buildTrack6_FireflyLullaby())   // Evening 6
        allTrackBuffers.append(buildTrack7_MoonGarden())       // Evening 7
        allTrackBuffers.append(buildTrack8_CopperRun())        // Day 8
        allTrackBuffers.append(buildTrack9_Voltage())          // Day 9
        allTrackBuffers.append(buildTrack10_LostRuins())       // Evening 10
        allTrackBuffers.append(buildTrack11_DuskDrift())       // Evening 11
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
    // buildNoteVoice renders one pass of the sequence into exactly `totalSamples`
    // frames (the sequence does NOT loop within — for sections we pass exactly
    // the sample count that matches the sequence duration).
    //
    // buildSectionedVoice concatenates multiple passes (each with independent
    // note list + volume scale) into one big contiguous buffer.
    //
    // Per-note envelope:
    //   attack  = min(0.010, dur * 0.08)
    //   sustain ramps 1.0 → 0.78 over held portion
    //   release = starts dur - max(0.005, gap*0.4 + dur*0.12) in
    //
    // Oscillator: main shape + 18% second harmonic.

    private struct MusicalNote {
        let hz:  Float   // 0 = rest
        let dur: Float   // gate duration in seconds
        let gap: Float   // silence after gate before next note
    }

    /// One section of a structured track: a note list plus a volume scale factor.
    /// vol 0.5 = intro/sparse, 0.8 = verse, 1.0 = chorus, 0.9 = bridge.
    private struct SectionSpec {
        let notes:    [MusicalNote]
        let volScale: Float          // multiplied onto the base voice volume
    }

    /// Concatenate multiple sections into one big buffer.  Each section renders
    /// exactly one sequential pass of its note list (no internal looping).
    /// A 4 ms cross-section fade prevents clicks at section joins.
    private func buildSectionedVoice(sections: [SectionSpec],
                                     shape:    OscShape,
                                     baseVol:  Float) -> AVAudioPCMBuffer? {
        guard !sections.isEmpty else { return nil }
        let sr = Float(format.sampleRate)

        // Compute per-section sample counts from their note durations.
        let sectionSamples: [Int] = sections.map { sec in
            let seqLen = sec.notes.reduce(0) { $0 + $1.dur + $1.gap }
            return max(1, Int(sr * seqLen))
        }
        let totalSamples = sectionSamples.reduce(0, +)
        guard totalSamples > 0 else { return nil }

        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(totalSamples)) else { return nil }
        outBuf.frameLength = AVAudioFrameCount(totalSamples)
        guard let outL = outBuf.floatChannelData?[0],
              let outR = outBuf.floatChannelData?[1] else { return nil }

        var writeOffset = 0
        for (secIdx, sec) in sections.enumerated() {
            let n = sectionSamples[secIdx]
            // Render this section.
            guard let secBuf = buildNoteVoice(notes: sec.notes,
                                              shape: shape,
                                              vol:   baseVol * sec.volScale,
                                              totalSamples: n) else {
                // Fill silence if render failed.
                for i in 0 ..< n { outL[writeOffset + i] = 0; outR[writeOffset + i] = 0 }
                writeOffset += n
                continue
            }
            guard let secL = secBuf.floatChannelData?[0],
                  let secR = secBuf.floatChannelData?[1] else {
                writeOffset += n; continue
            }
            // Copy section samples to output.
            for i in 0 ..< n {
                outL[writeOffset + i] = secL[i]
                outR[writeOffset + i] = secR[i]
            }
            // 4 ms crossfade at section join (fade out end of this, fade in start of next already built by buildNoteVoice's own fadeIO at buffer level — but those fade the section buffer edges, which is exactly what we want).
            // The inner buildNoteVoice already applied a 512-sample fade to secBuf,
            // so section edges are zero at their endpoints — safe to concatenate.
            writeOffset += n
        }

        // Final loop-point fade (whole-buffer edge).
        applyFadeIO(outL, outR, samples: totalSamples, fadeLen: min(2048, totalSamples / 16))
        normalizePeak(outL, outR, samples: totalSamples)
        return outBuf
    }

    /// Render a note sequence into a stereo buffer of exactly `totalSamples` frames.
    /// The sequence plays ONCE (not looped) — pass totalSamples = seqLen*sr for one pass.
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
    // MARK: Track 0 — "Sunshine Sprint" (C major, 120 BPM) [DAY]
    // -----------------------------------------------------------------------
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, Am feel) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q = 54 s at 120 BPM, loops cleanly.
    //
    // Intro/Outro: sparse — melody only at half volume, no arpeggio.
    // Verse: melody mid-register, light arpeggio.
    // Chorus: melody ascends an octave, denser arpeggio, fuller bass.
    // Bridge: shift to Am/relative — C4 E4 A4 sequence, darker colour.

    private func buildTrack0_SunshineSprint() -> [AVAudioPCMBuffer] {
        let q: Float = 0.500; let e: Float = q / 2; let h: Float = q * 2

        let C3: Float = 130.813; let G3: Float = 195.998; let F3: Float = 174.614; let E3: Float = 164.814; let A3: Float = 220.000
        let C4: Float = 261.626; let E4: Float = 329.628; let G4: Float = 391.995; let F4: Float = 349.228; let A4: Float = 440.000
        let C5: Float = 523.251; let E5: Float = 659.255; let G5: Float = 783.991; let A5: Float = 880.000; let F5: Float = 698.456
        let C6: Float = 1046.502; let E6: Float = 1318.510

        // ---- Melody sections ------------------------------------------------
        // Intro: gentle 8-q ascending phrase
        let melIntro: [MusicalNote] = [
            .init(hz: C5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: h*0.85, gap: h*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: h*0.80, gap: h*0.20),
        ]
        // Verse A: 16-q bouncy run C5→A5→C5
        let melVerseA: [MusicalNote] = [
            .init(hz: C5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: A5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: q*0.85, gap: q*0.15), .init(hz: G4, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: A5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: h*0.80, gap: h*0.20),
        ]
        // Chorus: ascend to upper octave, adds C6 peak
        let melChorus: [MusicalNote] = [
            .init(hz: C6, dur: q*0.85, gap: q*0.15), .init(hz: A5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: F5, dur: q*0.85, gap: q*0.15), .init(hz: G5, dur: q*0.85, gap: q*0.15),
            .init(hz: E5, dur: h*0.82, gap: h*0.18),
            .init(hz: C6, dur: q*0.85, gap: q*0.15), .init(hz: A5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: F5, dur: q*0.85, gap: q*0.15),
            .init(hz: E6, dur: q*0.75, gap: q*0.25), .init(hz: C6, dur: q*0.80, gap: q*0.20),
            .init(hz: G5, dur: h*0.80, gap: h*0.20),
        ]
        // Verse B: same shape as A but starts on E5 for variation
        let melVerseB: [MusicalNote] = [
            .init(hz: E5, dur: q*0.85, gap: q*0.15), .init(hz: G5, dur: q*0.85, gap: q*0.15),
            .init(hz: A5, dur: q*0.85, gap: q*0.15), .init(hz: G5, dur: q*0.85, gap: q*0.15),
            .init(hz: E5, dur: q*0.85, gap: q*0.15), .init(hz: C5, dur: q*0.85, gap: q*0.15),
            .init(hz: G4, dur: q*0.85, gap: q*0.15), .init(hz: C5, dur: q*0.85, gap: q*0.15),
            .init(hz: E5, dur: q*0.85, gap: q*0.15), .init(hz: F5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: h*0.80, gap: h*0.20),
        ]
        // Bridge: Am colour — A4 C5 E5 descending, 12 q
        let melBridge: [MusicalNote] = [
            .init(hz: A5, dur: q*0.88, gap: q*0.12), .init(hz: G5, dur: q*0.88, gap: q*0.12),
            .init(hz: F5, dur: h*0.85, gap: h*0.15),
            .init(hz: E5, dur: q*0.88, gap: q*0.12), .init(hz: C5, dur: q*0.88, gap: q*0.12),
            .init(hz: A4, dur: h*0.85, gap: h*0.15),
            .init(hz: C5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5, dur: h*0.80, gap: h*0.20),
        ]
        // Outro: sparse echo of intro
        let melOutro: [MusicalNote] = [
            .init(hz: G5, dur: q*0.85, gap: q*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: h*0.85, gap: h*0.15), .init(hz: E5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5, dur: h*0.80, gap: h*0.20),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.55),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.90),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.50),
        ]

        // ---- Bass sections --------------------------------------------------
        let bassI: [MusicalNote] = [
            .init(hz: C3, dur: h*0.75, gap: h*0.25), .init(hz: G3, dur: h*0.75, gap: h*0.25),
        ]
        let bassV: [MusicalNote] = [
            .init(hz: C3, dur: h*0.80, gap: h*0.20), .init(hz: G3, dur: h*0.80, gap: h*0.20),
            .init(hz: F3, dur: h*0.80, gap: h*0.20), .init(hz: G3, dur: h*0.80, gap: h*0.20),
            .init(hz: C3, dur: h*0.80, gap: h*0.20), .init(hz: G3, dur: h*0.80, gap: h*0.20),
            .init(hz: F3, dur: h*0.80, gap: h*0.20), .init(hz: G3, dur: h*0.80, gap: h*0.20),
        ]
        let bassC: [MusicalNote] = [
            .init(hz: C3, dur: q*0.70, gap: q*0.30), .init(hz: G3, dur: q*0.70, gap: q*0.30),
            .init(hz: F3, dur: q*0.70, gap: q*0.30), .init(hz: G3, dur: q*0.70, gap: q*0.30),
            .init(hz: C3, dur: q*0.70, gap: q*0.30), .init(hz: E3, dur: q*0.70, gap: q*0.30),
            .init(hz: F3, dur: q*0.70, gap: q*0.30), .init(hz: G3, dur: q*0.70, gap: q*0.30),
            .init(hz: C3, dur: q*0.70, gap: q*0.30), .init(hz: G3, dur: q*0.70, gap: q*0.30),
            .init(hz: F3, dur: q*0.70, gap: q*0.30), .init(hz: G3, dur: q*0.70, gap: q*0.30),
            .init(hz: C3, dur: q*0.70, gap: q*0.30), .init(hz: E3, dur: q*0.70, gap: q*0.30),
            .init(hz: G3, dur: h*0.70, gap: h*0.30),
        ]
        let bassB: [MusicalNote] = [
            .init(hz: A3, dur: h*0.75, gap: h*0.25), .init(hz: F3, dur: h*0.75, gap: h*0.25),
            .init(hz: C3, dur: h*0.75, gap: h*0.25), .init(hz: G3, dur: h*0.75, gap: h*0.25),
            .init(hz: F3, dur: h*0.75, gap: h*0.25), .init(hz: G3, dur: h*0.75, gap: h*0.25),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassI, volScale: 0.50),
            .init(notes: bassV, volScale: 0.80),
            .init(notes: bassC, volScale: 1.00),
            .init(notes: bassV, volScale: 0.80),
            .init(notes: bassC, volScale: 1.00),
            .init(notes: bassB, volScale: 0.90),
            .init(notes: bassC, volScale: 1.00),
            .init(notes: bassI, volScale: 0.45),
        ]

        // ---- Arpeggio sections ----------------------------------------------
        let arpLo: [MusicalNote] = [
            .init(hz: C4, dur: e*0.75, gap: e*0.25), .init(hz: E4, dur: e*0.75, gap: e*0.25),
            .init(hz: G4, dur: e*0.75, gap: e*0.25), .init(hz: C5, dur: e*0.75, gap: e*0.25),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: E4, dur: e*0.72, gap: e*0.28), .init(hz: G4, dur: e*0.72, gap: e*0.28),
            .init(hz: C5, dur: e*0.72, gap: e*0.28), .init(hz: E5, dur: e*0.72, gap: e*0.28),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: A4, dur: e*0.70, gap: e*0.30), .init(hz: C5, dur: e*0.70, gap: e*0.30),
            .init(hz: E5, dur: e*0.70, gap: e*0.30), .init(hz: A5, dur: e*0.70, gap: e*0.30),
        ]

        // Intro uses short silence filler — give it a note seq matching ~8q duration
        let arpIntroFill: [MusicalNote] = (0..<8).map { _ in
            .init(hz: 0, dur: q*0.5, gap: q*0.5)
        }

        let arpSections: [SectionSpec] = [
            .init(notes: arpIntroFill, volScale: 0.0),
            .init(notes: arpLo,       volScale: 0.60),
            .init(notes: arpHi,       volScale: 1.00),
            .init(notes: arpLo,       volScale: 0.65),
            .init(notes: arpHi,       volScale: 1.00),
            .init(notes: arpBridge,   volScale: 0.80),
            .init(notes: arpHi,       volScale: 1.00),
            .init(notes: arpIntroFill, volScale: 0.0),
        ]

        // ---- Pad sections ---------------------------------------------------
        let padBase: [MusicalNote] = [
            .init(hz: C4, dur: h*0.92, gap: h*0.08), .init(hz: G4, dur: h*0.92, gap: h*0.08),
            .init(hz: F4, dur: h*0.92, gap: h*0.08), .init(hz: G4, dur: h*0.92, gap: h*0.08),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: A4, dur: h*0.92, gap: h*0.08), .init(hz: F4, dur: h*0.92, gap: h*0.08),
            .init(hz: C4, dur: h*0.92, gap: h*0.08), .init(hz: G4, dur: h*0.92, gap: h*0.08),
            .init(hz: F4, dur: h*0.92, gap: h*0.08), .init(hz: G4, dur: h*0.92, gap: h*0.08),
        ]
        let padIntro: [MusicalNote] = [
            .init(hz: C4, dur: h*0.92, gap: h*0.08), .init(hz: G4, dur: h*0.92, gap: h*0.08),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.40),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.90),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.35),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.28) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.22) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.13) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.10) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 1 — "Pixel Bounce" (G major, 132 BPM) [DAY]
    // -----------------------------------------------------------------------
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, Em feel) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 49 s at 132 BPM, loops cleanly.
    //
    // Chorus adds counter-melody in higher register + faster staccato bass.
    // Bridge: Em feel — E5 B4 G4 descending line.

    private func buildTrack1_PixelBounce() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 132.0; let e: Float = q / 2; let h: Float = q * 2

        let G2: Float = 97.999;  let D3: Float = 146.832; let B2: Float = 123.471
        let G3: Float = 195.998; let D4: Float = 293.665; let B3: Float = 246.942; let E3: Float = 164.814
        let G4: Float = 391.995; let B4: Float = 493.883; let D5: Float = 587.330; let E4: Float = 329.628; let A4: Float = 440.000
        let G5: Float = 783.991; let A5: Float = 880.000; let E5: Float = 659.255; let Fs5: Float = 739.989
        let B5: Float = 987.767

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: G4, dur: q*0.80, gap: q*0.20), .init(hz: B4, dur: q*0.80, gap: q*0.20),
            .init(hz: D5, dur: h*0.80, gap: h*0.20), .init(hz: B4, dur: q*0.80, gap: q*0.20),
            .init(hz: G4, dur: h*0.78, gap: h*0.22),
        ]
        let melVerseA: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.75, gap: q*0.25), .init(hz: E5,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5,  dur: q*0.75, gap: q*0.25), .init(hz: B4,  dur: q*0.75, gap: q*0.25),
            .init(hz: G4,  dur: q*0.75, gap: q*0.25), .init(hz: B4,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5,  dur: q*0.75, gap: q*0.25), .init(hz: G5,  dur: q*0.75, gap: q*0.25),
            .init(hz: A5,  dur: q*0.75, gap: q*0.25), .init(hz: G5,  dur: q*0.75, gap: q*0.25),
            .init(hz: E5,  dur: q*0.75, gap: q*0.25), .init(hz: D5,  dur: q*0.75, gap: q*0.25),
            .init(hz: B4,  dur: q*0.75, gap: q*0.25), .init(hz: D5,  dur: q*0.75, gap: q*0.25),
            .init(hz: G5,  dur: q*0.60, gap: q*0.40), .init(hz: 0,   dur: q*0.90, gap: q*0.10),
        ]
        let melChorus: [MusicalNote] = [
            .init(hz: B5,  dur: q*0.72, gap: q*0.28), .init(hz: A5,  dur: q*0.72, gap: q*0.28),
            .init(hz: G5,  dur: q*0.72, gap: q*0.28), .init(hz: Fs5, dur: q*0.72, gap: q*0.28),
            .init(hz: G5,  dur: h*0.78, gap: h*0.22),
            .init(hz: A5,  dur: q*0.72, gap: q*0.28), .init(hz: B5,  dur: q*0.72, gap: q*0.28),
            .init(hz: A5,  dur: q*0.72, gap: q*0.28), .init(hz: G5,  dur: q*0.72, gap: q*0.28),
            .init(hz: E5,  dur: q*0.72, gap: q*0.28), .init(hz: D5,  dur: q*0.72, gap: q*0.28),
            .init(hz: B4,  dur: q*0.72, gap: q*0.28), .init(hz: G5,  dur: h*0.78, gap: h*0.22),
        ]
        let melVerseB: [MusicalNote] = [
            .init(hz: D5,  dur: q*0.75, gap: q*0.25), .init(hz: E5,  dur: q*0.75, gap: q*0.25),
            .init(hz: G5,  dur: q*0.75, gap: q*0.25), .init(hz: A5,  dur: q*0.75, gap: q*0.25),
            .init(hz: G5,  dur: q*0.75, gap: q*0.25), .init(hz: E5,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5,  dur: q*0.75, gap: q*0.25), .init(hz: B4,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5,  dur: q*0.75, gap: q*0.25), .init(hz: G5,  dur: q*0.75, gap: q*0.25),
            .init(hz: A5,  dur: q*0.75, gap: q*0.25), .init(hz: G5,  dur: q*0.75, gap: q*0.25),
            .init(hz: E5,  dur: q*0.75, gap: q*0.25), .init(hz: B4,  dur: q*0.75, gap: q*0.25),
            .init(hz: G4,  dur: h*0.78, gap: h*0.22),
        ]
        let melBridge: [MusicalNote] = [
            .init(hz: E5,  dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: B4,  dur: h*0.82, gap: h*0.18),
            .init(hz: G4,  dur: q*0.85, gap: q*0.15), .init(hz: A4,  dur: q*0.85, gap: q*0.15),
            .init(hz: B4,  dur: h*0.82, gap: h*0.18),
            .init(hz: D5,  dur: q*0.80, gap: q*0.20), .init(hz: E5,  dur: q*0.80, gap: q*0.20),
            .init(hz: G5,  dur: h*0.80, gap: h*0.20),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: D5, dur: q*0.80, gap: q*0.20), .init(hz: B4, dur: q*0.80, gap: q*0.20),
            .init(hz: G4, dur: h*0.80, gap: h*0.20), .init(hz: B4, dur: q*0.80, gap: q*0.20),
            .init(hz: G4, dur: h*0.75, gap: h*0.25),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.55),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.88),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.50),
        ]

        // ---- Bass -----------------------------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: G2, dur: h*0.60, gap: h*0.40), .init(hz: D3, dur: h*0.60, gap: h*0.40),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: G3, dur: h*0.65, gap: h*0.35), .init(hz: D4, dur: h*0.65, gap: h*0.35),
            .init(hz: G3, dur: h*0.65, gap: h*0.35), .init(hz: B3, dur: h*0.65, gap: h*0.35),
            .init(hz: G3, dur: h*0.65, gap: h*0.35), .init(hz: D4, dur: h*0.65, gap: h*0.35),
            .init(hz: G3, dur: h*0.65, gap: h*0.35), .init(hz: B3, dur: h*0.65, gap: h*0.35),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: D4, dur: q*0.55, gap: q*0.45),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: B3, dur: q*0.55, gap: q*0.45),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: D4, dur: q*0.55, gap: q*0.45),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: D4, dur: q*0.55, gap: q*0.45),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: B3, dur: q*0.55, gap: q*0.45),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: D4, dur: q*0.55, gap: q*0.45),
            .init(hz: B3, dur: h*0.60, gap: h*0.40),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: E3, dur: h*0.65, gap: h*0.35), .init(hz: B2, dur: h*0.65, gap: h*0.35),
            .init(hz: G3, dur: h*0.65, gap: h*0.35), .init(hz: D4, dur: h*0.65, gap: h*0.35),
            .init(hz: B3, dur: h*0.65, gap: h*0.35), .init(hz: G3, dur: h*0.65, gap: h*0.35),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.50),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.88),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.45),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: G4, dur: e*0.70, gap: e*0.30), .init(hz: B4, dur: e*0.70, gap: e*0.30),
            .init(hz: D5, dur: e*0.70, gap: e*0.30), .init(hz: G5, dur: e*0.70, gap: e*0.30),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: B4, dur: e*0.68, gap: e*0.32), .init(hz: D5, dur: e*0.68, gap: e*0.32),
            .init(hz: G5, dur: e*0.68, gap: e*0.32), .init(hz: B5, dur: e*0.68, gap: e*0.32),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: E4, dur: e*0.68, gap: e*0.32), .init(hz: G4, dur: e*0.68, gap: e*0.32),
            .init(hz: B4, dur: e*0.68, gap: e*0.32), .init(hz: E5, dur: e*0.68, gap: e*0.32),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.65),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: G4, dur: h*0.90, gap: h*0.10), .init(hz: D4, dur: h*0.90, gap: h*0.10),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: G4, dur: h*0.90, gap: h*0.10), .init(hz: D4, dur: h*0.90, gap: h*0.10),
            .init(hz: G4, dur: h*0.90, gap: h*0.10), .init(hz: B4, dur: h*0.90, gap: h*0.10),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: E4, dur: h*0.90, gap: h*0.10), .init(hz: B3, dur: h*0.90, gap: h*0.10),
            .init(hz: G4, dur: h*0.90, gap: h*0.10), .init(hz: D4, dur: h*0.90, gap: h*0.10),
            .init(hz: B3, dur: h*0.90, gap: h*0.10), .init(hz: G4, dur: h*0.90, gap: h*0.10),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.40),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.88),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.35),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.27) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.21) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .triangle, baseVol: 0.12) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 2 — "Cozy Campfire" (F major, 108 BPM) [EVENING]
    // -----------------------------------------------------------------------
    // Form: Intro(8q) → Verse A(17q) → Chorus(16q) → Verse B(17q) →
    //       Chorus(16q) → Bridge(12q, Dm feel) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 110 q ≈ 61 s at 108 BPM.
    //
    // Chorus: melody moves to F5-G5-A5 range, counter-melody on C5-D5.
    // Bridge: Dm colour — D5 C5 A4 descending, softer and more introspective.

    private func buildTrack2_CozyCampfire() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 108.0; let e: Float = q / 2; let h: Float = q * 2

        let F2: Float = 87.307;  let C3: Float = 130.813; let A2: Float = 110.000
        let F3: Float = 174.614; let C4: Float = 261.626; let A3: Float = 220.000; let D3: Float = 146.832
        let F4: Float = 349.228; let A4: Float = 440.000; let C5: Float = 523.251; let D4: Float = 293.665
        let F5: Float = 698.456; let G5: Float = 783.991; let E5: Float = 659.255; let D5: Float = 587.330
        let Bb4: Float = 466.164; let G4: Float = 391.995; let A5: Float = 880.000

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: F4, dur: q*0.88, gap: q*0.12), .init(hz: A4, dur: q*0.88, gap: q*0.12),
            .init(hz: C5, dur: h*0.85, gap: h*0.15), .init(hz: A4, dur: q*0.88, gap: q*0.12),
            .init(hz: F4, dur: h*0.82, gap: h*0.18),
        ]
        // Verse A: classic sing-along F arc (17q total — includes rest)
        let melVerseA: [MusicalNote] = [
            .init(hz: F5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F5,  dur: q*0.88, gap: q*0.12), .init(hz: G5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F5,  dur: h*0.88, gap: h*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: D5,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: A4,  dur: q*0.88, gap: q*0.12),
            .init(hz: Bb4, dur: h*0.88, gap: h*0.12),
            .init(hz: A4,  dur: q*0.88, gap: q*0.12), .init(hz: G4,  dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: q*0.88, gap: q*0.12), .init(hz: C5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F4,  dur: h*0.80, gap: h*0.20), .init(hz: 0,   dur: q*0.95, gap: q*0.05),
        ]
        // Chorus: higher register with A5 peak
        let melChorus: [MusicalNote] = [
            .init(hz: A5,  dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: h*0.85, gap: h*0.15),
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: A5,  dur: q*0.85, gap: q*0.15),
            .init(hz: G5,  dur: q*0.82, gap: q*0.18), .init(hz: F5,  dur: q*0.82, gap: q*0.18),
            .init(hz: E5,  dur: h*0.82, gap: h*0.18),
            .init(hz: F5,  dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: A5,  dur: q*0.82, gap: q*0.18), .init(hz: C5,  dur: q*0.82, gap: q*0.18),
            .init(hz: F5,  dur: h*0.80, gap: h*0.20),
        ]
        // Verse B: starts differently — opens on C5
        let melVerseB: [MusicalNote] = [
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: D5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F5,  dur: q*0.88, gap: q*0.12), .init(hz: G5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F5,  dur: h*0.88, gap: h*0.12),
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: F5,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: Bb4, dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: h*0.85, gap: h*0.15),
            .init(hz: G4,  dur: q*0.88, gap: q*0.12), .init(hz: A4,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: F5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F4,  dur: h*0.80, gap: h*0.20), .init(hz: 0,   dur: q*0.95, gap: q*0.05),
        ]
        // Bridge: Dm feel — D5 C5 A4 Bb4 quiet descent
        let melBridge: [MusicalNote] = [
            .init(hz: D5,  dur: q*0.90, gap: q*0.10), .init(hz: C5,  dur: q*0.90, gap: q*0.10),
            .init(hz: A4,  dur: h*0.88, gap: h*0.12),
            .init(hz: Bb4, dur: q*0.90, gap: q*0.10), .init(hz: A4,  dur: q*0.90, gap: q*0.10),
            .init(hz: G4,  dur: h*0.88, gap: h*0.12),
            .init(hz: A4,  dur: q*0.85, gap: q*0.15), .init(hz: C5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F4,  dur: h*0.82, gap: h*0.18),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: C5, dur: q*0.88, gap: q*0.12), .init(hz: A4, dur: q*0.88, gap: q*0.12),
            .init(hz: F4, dur: h*0.85, gap: h*0.15), .init(hz: A4, dur: q*0.88, gap: q*0.12),
            .init(hz: F4, dur: h*0.80, gap: h*0.20),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.55),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.85),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.50),
        ]

        // ---- Bass -----------------------------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: F2, dur: h*0.70, gap: h*0.30), .init(hz: C3, dur: h*0.70, gap: h*0.30),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: F3, dur: h*0.75, gap: h*0.25), .init(hz: C4, dur: h*0.75, gap: h*0.25),
            .init(hz: F3, dur: h*0.75, gap: h*0.25), .init(hz: A3, dur: h*0.75, gap: h*0.25),
            .init(hz: F3, dur: h*0.75, gap: h*0.25), .init(hz: C4, dur: h*0.75, gap: h*0.25),
            .init(hz: F3, dur: h*0.75, gap: h*0.25), .init(hz: A3, dur: h*0.75, gap: h*0.25),
            .init(hz: F3, dur: q*0.75, gap: q*0.25),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: F3, dur: q*0.65, gap: q*0.35), .init(hz: A3, dur: q*0.65, gap: q*0.35),
            .init(hz: C4, dur: q*0.65, gap: q*0.35), .init(hz: F3, dur: q*0.65, gap: q*0.35),
            .init(hz: A3, dur: q*0.65, gap: q*0.35), .init(hz: C4, dur: q*0.65, gap: q*0.35),
            .init(hz: F3, dur: q*0.65, gap: q*0.35), .init(hz: A3, dur: q*0.65, gap: q*0.35),
            .init(hz: F3, dur: q*0.65, gap: q*0.35), .init(hz: C4, dur: q*0.65, gap: q*0.35),
            .init(hz: F3, dur: q*0.65, gap: q*0.35), .init(hz: A3, dur: q*0.65, gap: q*0.35),
            .init(hz: F3, dur: h*0.70, gap: h*0.30),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: D3, dur: h*0.75, gap: h*0.25), .init(hz: A2, dur: h*0.75, gap: h*0.25),
            .init(hz: F3, dur: h*0.75, gap: h*0.25), .init(hz: C3, dur: h*0.75, gap: h*0.25),
            .init(hz: A2, dur: h*0.75, gap: h*0.25), .init(hz: F3, dur: h*0.75, gap: h*0.25),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.50),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.85),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.45),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: F4, dur: e*0.78, gap: e*0.22), .init(hz: A4, dur: e*0.78, gap: e*0.22),
            .init(hz: C5, dur: e*0.78, gap: e*0.22), .init(hz: F5, dur: e*0.78, gap: e*0.22),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: A4, dur: e*0.75, gap: e*0.25), .init(hz: C5, dur: e*0.75, gap: e*0.25),
            .init(hz: F5, dur: e*0.75, gap: e*0.25), .init(hz: A5, dur: e*0.75, gap: e*0.25),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: D4, dur: e*0.78, gap: e*0.22), .init(hz: F4, dur: e*0.78, gap: e*0.22),
            .init(hz: A4, dur: e*0.78, gap: e*0.22), .init(hz: D5, dur: e*0.78, gap: e*0.22),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.65),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: F4, dur: h*0.93, gap: h*0.07), .init(hz: C4, dur: h*0.93, gap: h*0.07),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: F4, dur: h*0.93, gap: h*0.07), .init(hz: C4, dur: h*0.93, gap: h*0.07),
            .init(hz: F4, dur: h*0.93, gap: h*0.07), .init(hz: A4, dur: h*0.93, gap: h*0.07),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: D4, dur: h*0.93, gap: h*0.07), .init(hz: A3, dur: h*0.93, gap: h*0.07),
            .init(hz: F4, dur: h*0.93, gap: h*0.07), .init(hz: C4, dur: h*0.93, gap: h*0.07),
            .init(hz: A3, dur: h*0.93, gap: h*0.07), .init(hz: F4, dur: h*0.93, gap: h*0.07),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.40),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.35),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.26) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.19) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.11) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 3 — "Starlight Waltz" (D major, 120 BPM, 3/4 feel) [EVENING]
    // -----------------------------------------------------------------------
    // Form: Intro(9q) → Verse A(24q) → Chorus(24q) → Verse B(24q) →
    //       Chorus(24q) → Bridge(18q, Bm feel) → Chorus-out(24q) → Outro(9q)
    // Total ≈ 156 q = 78 s at 120 BPM.
    //
    // All sections use waltz groups of 3q. Chorus: melody to high D6 range.
    // Bridge: Bm colour (B D F# notes), darker but still gentle.

    private func buildTrack3_StarlightWaltz() -> [AVAudioPCMBuffer] {
        let q: Float = 0.500; let e: Float = q / 2; let h: Float = q * 2

        let A2: Float  = 110.000
        let D3: Float  = 146.832; let A3: Float  = 220.000; let Fs3: Float = 184.997; let B2: Float = 61.735
        let D4: Float  = 293.665; let Fs4: Float = 369.994; let A4: Float  = 440.000; let B3: Float = 246.942
        let D5: Float  = 587.330; let Fs5: Float = 739.989; let A5: Float  = 880.000; let B4: Float = 493.883
        let E5: Float  = 659.255; let G5: Float  = 783.991; let B5: Float  = 987.767; let Cs5: Float = 554.365

        // ---- Melody ---------------------------------------------------------
        // Intro: sparse first phrase (9q = 3 bars of 3/4)
        let melIntro: [MusicalNote] = [
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12),
            .init(hz: D5,  dur: q*2.80, gap: q*0.20),
        ]
        // Verse A: 8 bars of 3/4 = 24q
        let melVerseA: [MusicalNote] = [
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12), .init(hz: A5, dur: q*0.88, gap: q*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: E5, dur: q*0.88, gap: q*0.12),
            .init(hz: Fs5, dur: q*0.88, gap: q*0.12), .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: D5, dur: q*0.88, gap: q*0.12),
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: h*0.85, gap: h*0.15),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12), .init(hz: A5, dur: q*0.88, gap: q*0.12),
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: D5, dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12), .init(hz: A5, dur: q*0.88, gap: q*0.12),
            .init(hz: D5,  dur: q*2.80, gap: q*0.20),
        ]
        // Chorus: ascend to B5 range
        let melChorus: [MusicalNote] = [
            .init(hz: Fs5, dur: q*0.85, gap: q*0.15), .init(hz: A5,  dur: q*0.85, gap: q*0.15), .init(hz: B5,  dur: q*0.85, gap: q*0.15),
            .init(hz: B5,  dur: q*0.85, gap: q*0.15), .init(hz: A5,  dur: q*0.85, gap: q*0.15), .init(hz: Fs5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: A5,  dur: q*0.85, gap: q*0.15), .init(hz: B5,  dur: q*0.85, gap: q*0.15),
            .init(hz: A5,  dur: q*2.75, gap: q*0.25),
            .init(hz: B5,  dur: q*0.85, gap: q*0.15), .init(hz: A5,  dur: q*0.85, gap: q*0.15), .init(hz: Fs5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: E5,  dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Cs5, dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15), .init(hz: E5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Fs5, dur: q*2.75, gap: q*0.25),
        ]
        // Verse B: starts on Fs5 for variation
        let melVerseB: [MusicalNote] = [
            .init(hz: Fs5, dur: q*0.88, gap: q*0.12), .init(hz: A5, dur: q*0.88, gap: q*0.12), .init(hz: D5, dur: q*0.88, gap: q*0.12),
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: h*0.85, gap: h*0.15),
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: A5, dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12),
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: D5, dur: q*0.88, gap: q*0.12), .init(hz: Cs5, dur: q*0.88, gap: q*0.12),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: E5, dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: G5, dur: q*0.88, gap: q*0.12), .init(hz: E5, dur: q*0.88, gap: q*0.12),
            .init(hz: D5,  dur: q*2.80, gap: q*0.20),
        ]
        // Bridge: Bm colour (B D F# E notes), 6 bars = 18q
        let melBridge: [MusicalNote] = [
            .init(hz: B5,  dur: q*0.90, gap: q*0.10), .init(hz: A5,  dur: q*0.90, gap: q*0.10), .init(hz: Fs5, dur: q*0.90, gap: q*0.10),
            .init(hz: G5,  dur: q*0.90, gap: q*0.10), .init(hz: E5,  dur: h*0.88, gap: h*0.12),
            .init(hz: Fs5, dur: q*0.88, gap: q*0.12), .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: B4,  dur: q*0.88, gap: q*0.12),
            .init(hz: Cs5, dur: q*0.88, gap: q*0.12), .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: Fs5, dur: q*2.80, gap: q*0.20),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: A5, dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12),
            .init(hz: D5, dur: q*0.88, gap: q*0.12), .init(hz: Fs5, dur: q*0.88, gap: q*0.12),
            .init(hz: A5, dur: q*0.88, gap: q*0.12), .init(hz: D5,  dur: q*0.88, gap: q*0.12),
            .init(hz: D5, dur: q*2.80, gap: q*0.20),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.52),
            .init(notes: melVerseA, volScale: 0.78),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.85),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.48),
        ]

        // ---- Bass -----------------------------------------------------------
        // Waltz bass: 1 note per bar (3q slots)
        let bassIntro: [MusicalNote] = [
            .init(hz: D3, dur: q*2.70, gap: q*0.30), .init(hz: A3, dur: q*2.70, gap: q*0.30), .init(hz: D3, dur: q*2.70, gap: q*0.30),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: D3,  dur: q*2.70, gap: q*0.30), .init(hz: A3,  dur: q*2.70, gap: q*0.30),
            .init(hz: D3,  dur: q*2.70, gap: q*0.30), .init(hz: Fs3, dur: q*2.70, gap: q*0.30),
            .init(hz: D3,  dur: q*2.70, gap: q*0.30), .init(hz: A3,  dur: q*2.70, gap: q*0.30),
            .init(hz: D3,  dur: q*2.70, gap: q*0.30), .init(hz: A3,  dur: q*2.70, gap: q*0.30),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: D3,  dur: h*0.72, gap: h*0.28), .init(hz: Fs3, dur: q*0.72, gap: q*0.28),
            .init(hz: A3,  dur: h*0.72, gap: h*0.28), .init(hz: D3,  dur: q*0.72, gap: q*0.28),
            .init(hz: A2,  dur: h*0.72, gap: h*0.28), .init(hz: A3,  dur: q*0.72, gap: q*0.28),
            .init(hz: D3,  dur: h*0.72, gap: h*0.28), .init(hz: A3,  dur: q*0.72, gap: q*0.28),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: B2,  dur: q*2.70, gap: q*0.30), .init(hz: Fs3, dur: q*2.70, gap: q*0.30),
            .init(hz: D3,  dur: q*2.70, gap: q*0.30), .init(hz: A3,  dur: q*2.70, gap: q*0.30),
            .init(hz: Fs3, dur: q*2.70, gap: q*0.30), .init(hz: D3,  dur: q*2.70, gap: q*0.30),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.48),
            .init(notes: bassVerse,  volScale: 0.78),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.78),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.85),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.42),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<9).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: D4,  dur: e*0.72, gap: e*0.28), .init(hz: Fs4, dur: e*0.72, gap: e*0.28),
            .init(hz: A4,  dur: e*0.72, gap: e*0.28), .init(hz: D5,  dur: e*0.72, gap: e*0.28),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: Fs4, dur: e*0.70, gap: e*0.30), .init(hz: A4,  dur: e*0.70, gap: e*0.30),
            .init(hz: D5,  dur: e*0.70, gap: e*0.30), .init(hz: Fs5, dur: e*0.70, gap: e*0.30),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: B3,  dur: e*0.72, gap: e*0.28), .init(hz: D4,  dur: e*0.72, gap: e*0.28),
            .init(hz: Fs4, dur: e*0.72, gap: e*0.28), .init(hz: B4,  dur: e*0.72, gap: e*0.28),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.65),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: D4, dur: q*2.90, gap: q*0.10), .init(hz: A4, dur: q*2.90, gap: q*0.10), .init(hz: D4, dur: q*2.90, gap: q*0.10),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: D4,  dur: q*2.90, gap: q*0.10), .init(hz: A4, dur: q*2.90, gap: q*0.10),
            .init(hz: D4,  dur: q*2.90, gap: q*0.10), .init(hz: A4, dur: q*2.90, gap: q*0.10),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: B3,  dur: q*2.90, gap: q*0.10), .init(hz: Fs4, dur: q*2.90, gap: q*0.10),
            .init(hz: D4,  dur: q*2.90, gap: q*0.10), .init(hz: A4, dur: q*2.90, gap: q*0.10),
            .init(hz: Fs4, dur: q*2.90, gap: q*0.10), .init(hz: D4, dur: q*2.90, gap: q*0.10),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.38),
            .init(notes: padBase,   volScale: 0.72),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.72),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.32),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.25) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.18) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.11) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.08) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 4 — "Adventure March" (A major, 126 BPM) [DAY]
    // -----------------------------------------------------------------------
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, F#m feel) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 51 s at 126 BPM.
    //
    // Dotted-rhythm march feel throughout. Chorus lifts to A6 and adds bugle arp.
    // Bridge: F#m — Fs5 E5 Cs5 descending march phrase, still energetic.

    private func buildTrack4_AdventureMarch() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 126.0; let e: Float = q / 2; let h: Float = q * 2
        let dq: Float = q * 1.5   // dotted quarter

        let A2: Float = 110.000; let E3: Float = 164.814; let Cs3: Float = 138.591
        let A3: Float = 220.000; let E4: Float = 329.628; let Cs4: Float = 277.183; let Fs3: Float = 184.997
        let A4: Float = 440.000; let Cs5: Float = 554.365; let E5: Float = 659.255; let B4: Float = 493.883
        let Fs5: Float = 739.989; let A5: Float = 880.000; let Fs4: Float = 369.994; let Gs5: Float = 830.609

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: A4,  dur: dq*0.85, gap: dq*0.15), .init(hz: Cs5, dur: e*0.80, gap: e*0.20),
            .init(hz: E5,  dur: h*0.80, gap: h*0.20),
            .init(hz: A4,  dur: q*0.82, gap: q*0.18), .init(hz: E5, dur: h*0.80, gap: h*0.20),
        ]
        let melVerseA: [MusicalNote] = [
            .init(hz: A5,  dur: dq*0.88, gap: dq*0.12), .init(hz: Fs5, dur: e*0.80, gap: e*0.20),
            .init(hz: E5,  dur: dq*0.88, gap: dq*0.12), .init(hz: Cs5, dur: e*0.80, gap: e*0.20),
            .init(hz: A4,  dur: h*0.80, gap: h*0.20),
            .init(hz: Cs5, dur: q*0.85, gap: q*0.15), .init(hz: E5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Fs5, dur: dq*0.88, gap: dq*0.12), .init(hz: E5,  dur: e*0.80, gap: e*0.20),
            .init(hz: Cs5, dur: dq*0.88, gap: dq*0.12), .init(hz: A4,  dur: e*0.80, gap: e*0.20),
            .init(hz: B4,  dur: q*0.85, gap: q*0.15), .init(hz: Cs5, dur: q*0.85, gap: q*0.15),
            .init(hz: A5,  dur: h*0.80, gap: h*0.20),
        ]
        // Chorus: peak at Gs5/A5, brighter and fuller
        let melChorus: [MusicalNote] = [
            .init(hz: A5,  dur: q*0.82, gap: q*0.18), .init(hz: A5,  dur: q*0.82, gap: q*0.18),
            .init(hz: Gs5, dur: dq*0.88, gap: dq*0.12), .init(hz: Fs5, dur: e*0.80, gap: e*0.20),
            .init(hz: E5,  dur: h*0.80, gap: h*0.20),
            .init(hz: Fs5, dur: dq*0.88, gap: dq*0.12), .init(hz: E5,  dur: e*0.80, gap: e*0.20),
            .init(hz: Cs5, dur: q*0.85, gap: q*0.15), .init(hz: B4,  dur: q*0.85, gap: q*0.15),
            .init(hz: Cs5, dur: dq*0.88, gap: dq*0.12), .init(hz: E5, dur: e*0.80, gap: e*0.20),
            .init(hz: A5,  dur: h*0.80, gap: h*0.20),
        ]
        // Verse B: opens on E5 for variety
        let melVerseB: [MusicalNote] = [
            .init(hz: E5,  dur: dq*0.88, gap: dq*0.12), .init(hz: Cs5, dur: e*0.80, gap: e*0.20),
            .init(hz: A4,  dur: h*0.80, gap: h*0.20),
            .init(hz: B4,  dur: q*0.85, gap: q*0.15), .init(hz: Cs5, dur: q*0.85, gap: q*0.15),
            .init(hz: E5,  dur: dq*0.88, gap: dq*0.12), .init(hz: Fs5, dur: e*0.80, gap: e*0.20),
            .init(hz: A5,  dur: dq*0.85, gap: dq*0.15), .init(hz: Fs5, dur: e*0.80, gap: e*0.20),
            .init(hz: E5,  dur: q*0.85, gap: q*0.15), .init(hz: Cs5, dur: q*0.85, gap: q*0.15),
            .init(hz: A4,  dur: h*0.78, gap: h*0.22),
        ]
        // Bridge: F#m feel — Fs5 E5 Cs5 B4
        let melBridge: [MusicalNote] = [
            .init(hz: Fs5, dur: dq*0.88, gap: dq*0.12), .init(hz: E5,  dur: e*0.80, gap: e*0.20),
            .init(hz: Cs5, dur: h*0.82, gap: h*0.18),
            .init(hz: B4,  dur: q*0.85, gap: q*0.15), .init(hz: Cs5, dur: q*0.85, gap: q*0.15),
            .init(hz: E5,  dur: dq*0.85, gap: dq*0.15), .init(hz: Fs5, dur: e*0.80, gap: e*0.20),
            .init(hz: A5,  dur: h*0.80, gap: h*0.20),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: E5, dur: dq*0.85, gap: dq*0.15), .init(hz: Cs5, dur: e*0.80, gap: e*0.20),
            .init(hz: A4, dur: h*0.82, gap: h*0.18),
            .init(hz: E4, dur: q*0.82, gap: q*0.18), .init(hz: A4,  dur: h*0.78, gap: h*0.22),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.55),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.82),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.88),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.50),
        ]

        // ---- Bass -----------------------------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: A2, dur: h*0.55, gap: h*0.45), .init(hz: E3, dur: h*0.55, gap: h*0.45),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: A3,  dur: h*0.60, gap: h*0.40), .init(hz: E4,  dur: h*0.60, gap: h*0.40),
            .init(hz: A3,  dur: h*0.60, gap: h*0.40), .init(hz: Cs4, dur: h*0.60, gap: h*0.40),
            .init(hz: A3,  dur: h*0.60, gap: h*0.40), .init(hz: E4,  dur: h*0.60, gap: h*0.40),
            .init(hz: A3,  dur: h*0.60, gap: h*0.40), .init(hz: E4,  dur: h*0.60, gap: h*0.40),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: A3,  dur: q*0.55, gap: q*0.45), .init(hz: E4,  dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: q*0.55, gap: q*0.45), .init(hz: Cs4, dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: q*0.55, gap: q*0.45), .init(hz: E4,  dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: q*0.55, gap: q*0.45), .init(hz: E4,  dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: q*0.55, gap: q*0.45), .init(hz: Cs4, dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: h*0.55, gap: h*0.45),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: Fs3, dur: h*0.60, gap: h*0.40), .init(hz: Cs3, dur: h*0.60, gap: h*0.40),
            .init(hz: A3,  dur: h*0.60, gap: h*0.40), .init(hz: E3,  dur: h*0.60, gap: h*0.40),
            .init(hz: Cs3, dur: h*0.60, gap: h*0.40), .init(hz: A3,  dur: h*0.60, gap: h*0.40),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.50),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.82),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.88),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.45),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: A4,  dur: e*0.72, gap: e*0.28), .init(hz: Cs5, dur: e*0.72, gap: e*0.28),
            .init(hz: E5,  dur: e*0.72, gap: e*0.28), .init(hz: A5,  dur: e*0.72, gap: e*0.28),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: Cs5, dur: e*0.70, gap: e*0.30), .init(hz: E5,  dur: e*0.70, gap: e*0.30),
            .init(hz: A5,  dur: e*0.70, gap: e*0.30), .init(hz: Cs5, dur: e*0.70, gap: e*0.30),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: Fs4, dur: e*0.72, gap: e*0.28), .init(hz: A4,  dur: e*0.72, gap: e*0.28),
            .init(hz: Cs5, dur: e*0.72, gap: e*0.28), .init(hz: Fs5, dur: e*0.72, gap: e*0.28),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.65),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: A4, dur: h*0.92, gap: h*0.08), .init(hz: E4, dur: h*0.92, gap: h*0.08),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: A4,  dur: h*0.92, gap: h*0.08), .init(hz: E4,  dur: h*0.92, gap: h*0.08),
            .init(hz: A4,  dur: h*0.92, gap: h*0.08), .init(hz: Cs5, dur: h*0.92, gap: h*0.08),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: Fs4, dur: h*0.92, gap: h*0.08), .init(hz: Cs4, dur: h*0.92, gap: h*0.08),
            .init(hz: A4,  dur: h*0.92, gap: h*0.08), .init(hz: E4,  dur: h*0.92, gap: h*0.08),
            .init(hz: Cs4, dur: h*0.92, gap: h*0.08), .init(hz: A4,  dur: h*0.92, gap: h*0.08),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.40),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.88),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.35),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.27) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.22) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.13) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 5 — "Rainbow Road" (Bb major, 116 BPM) [DAY]
    // -----------------------------------------------------------------------
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, Gm feel) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 56 s at 116 BPM.
    //
    // Joyful skip-hop. Chromatic Eb5 colour note used in verse; chorus goes
    // full Bb5. Bridge: Gm feel — G5 F5 D5 Eb5 descending phrase.

    private func buildTrack5_RainbowRoad() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 116.0; let e: Float = q / 2; let h: Float = q * 2

        let Bb2: Float = 116.541; let F3: Float  = 174.614; let D3: Float  = 146.832
        let Bb3: Float = 233.082; let F4: Float  = 349.228; let D4: Float  = 293.665; let G3: Float = 195.998
        let Bb4: Float = 466.164; let D5: Float  = 587.330; let F5: Float  = 698.456; let G4: Float = 391.995
        let G5: Float  = 783.991; let Bb5: Float = 932.328; let C5: Float  = 523.251; let Eb5: Float = 622.254
        let A5: Float  = 880.000

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: Bb4, dur: q*0.85, gap: q*0.15), .init(hz: D5, dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: h*0.82, gap: h*0.18), .init(hz: D5, dur: q*0.85, gap: q*0.15),
            .init(hz: Bb4, dur: h*0.80, gap: h*0.20),
        ]
        let melVerseA: [MusicalNote] = [
            .init(hz: Bb4, dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: q*0.85, gap: q*0.15), .init(hz: Bb5, dur: q*0.70, gap: q*0.30),
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: Eb5, dur: q*0.80, gap: q*0.20),
            .init(hz: F5,  dur: h*0.82, gap: h*0.18),
            .init(hz: D5,  dur: q*0.85, gap: q*0.15), .init(hz: C5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Bb4, dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Eb5, dur: q*0.80, gap: q*0.20), .init(hz: D5,  dur: h*0.78, gap: h*0.22),
        ]
        // Chorus: Bb5 peak, brighter and fuller
        let melChorus: [MusicalNote] = [
            .init(hz: Bb5, dur: q*0.82, gap: q*0.18), .init(hz: A5,  dur: q*0.82, gap: q*0.18),
            .init(hz: G5,  dur: q*0.82, gap: q*0.18), .init(hz: F5,  dur: q*0.82, gap: q*0.18),
            .init(hz: G5,  dur: h*0.80, gap: h*0.20),
            .init(hz: Bb5, dur: q*0.82, gap: q*0.18), .init(hz: G5,  dur: q*0.82, gap: q*0.18),
            .init(hz: F5,  dur: q*0.82, gap: q*0.18), .init(hz: D5,  dur: q*0.82, gap: q*0.18),
            .init(hz: Eb5, dur: q*0.80, gap: q*0.20), .init(hz: F5,  dur: q*0.82, gap: q*0.18),
            .init(hz: Bb5, dur: h*0.80, gap: h*0.20),
        ]
        // Verse B: different opening rhythm
        let melVerseB: [MusicalNote] = [
            .init(hz: F5,  dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Bb5, dur: q*0.75, gap: q*0.25), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: h*0.82, gap: h*0.18),
            .init(hz: Eb5, dur: q*0.80, gap: q*0.20), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: C5,  dur: q*0.85, gap: q*0.15), .init(hz: Bb4, dur: q*0.85, gap: q*0.15),
            .init(hz: C5,  dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: h*0.78, gap: h*0.22),
        ]
        // Bridge: Gm feel
        let melBridge: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: F5,  dur: q*0.88, gap: q*0.12),
            .init(hz: Eb5, dur: h*0.85, gap: h*0.15),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: C5,  dur: q*0.88, gap: q*0.12),
            .init(hz: Bb4, dur: h*0.85, gap: h*0.15),
            .init(hz: C5,  dur: q*0.85, gap: q*0.15), .init(hz: D5,  dur: q*0.85, gap: q*0.15),
            .init(hz: F5,  dur: h*0.82, gap: h*0.18),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: F5,  dur: q*0.85, gap: q*0.15), .init(hz: D5, dur: q*0.85, gap: q*0.15),
            .init(hz: Bb4, dur: h*0.82, gap: h*0.18), .init(hz: D5, dur: q*0.85, gap: q*0.15),
            .init(hz: Bb4, dur: h*0.78, gap: h*0.22),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.55),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.88),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.50),
        ]

        // ---- Bass -----------------------------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: Bb2, dur: h*0.62, gap: h*0.38), .init(hz: F3, dur: h*0.62, gap: h*0.38),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: Bb3, dur: h*0.68, gap: h*0.32), .init(hz: F4,  dur: h*0.68, gap: h*0.32),
            .init(hz: Bb3, dur: h*0.68, gap: h*0.32), .init(hz: D4,  dur: h*0.68, gap: h*0.32),
            .init(hz: Bb3, dur: h*0.68, gap: h*0.32), .init(hz: F4,  dur: h*0.68, gap: h*0.32),
            .init(hz: Bb3, dur: h*0.68, gap: h*0.32), .init(hz: F4,  dur: h*0.68, gap: h*0.32),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: Bb3, dur: q*0.62, gap: q*0.38), .init(hz: D4,  dur: q*0.62, gap: q*0.38),
            .init(hz: F4,  dur: q*0.62, gap: q*0.38), .init(hz: Bb3, dur: q*0.62, gap: q*0.38),
            .init(hz: D4,  dur: q*0.62, gap: q*0.38), .init(hz: F4,  dur: q*0.62, gap: q*0.38),
            .init(hz: Bb3, dur: q*0.62, gap: q*0.38), .init(hz: D4,  dur: q*0.62, gap: q*0.38),
            .init(hz: F4,  dur: q*0.62, gap: q*0.38), .init(hz: Bb3, dur: q*0.62, gap: q*0.38),
            .init(hz: F4,  dur: h*0.62, gap: h*0.38),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: G3,  dur: h*0.68, gap: h*0.32), .init(hz: D3,  dur: h*0.68, gap: h*0.32),
            .init(hz: Bb2, dur: h*0.68, gap: h*0.32), .init(hz: F3,  dur: h*0.68, gap: h*0.32),
            .init(hz: D3,  dur: h*0.68, gap: h*0.32), .init(hz: Bb3, dur: h*0.68, gap: h*0.32),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.50),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.88),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.45),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: Bb4, dur: e*0.75, gap: e*0.25), .init(hz: D5,  dur: e*0.75, gap: e*0.25),
            .init(hz: F5,  dur: e*0.75, gap: e*0.25), .init(hz: Bb5, dur: e*0.75, gap: e*0.25),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: D5,  dur: e*0.72, gap: e*0.28), .init(hz: F5,  dur: e*0.72, gap: e*0.28),
            .init(hz: Bb5, dur: e*0.72, gap: e*0.28), .init(hz: D5,  dur: e*0.72, gap: e*0.28),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: G4,  dur: e*0.75, gap: e*0.25), .init(hz: Bb4, dur: e*0.75, gap: e*0.25),
            .init(hz: D5,  dur: e*0.75, gap: e*0.25), .init(hz: G5,  dur: e*0.75, gap: e*0.25),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.65),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: Bb4, dur: h*0.91, gap: h*0.09), .init(hz: F4, dur: h*0.91, gap: h*0.09),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: Bb4, dur: h*0.91, gap: h*0.09), .init(hz: F4, dur: h*0.91, gap: h*0.09),
            .init(hz: Bb4, dur: h*0.91, gap: h*0.09), .init(hz: D5, dur: h*0.91, gap: h*0.09),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: G4,  dur: h*0.91, gap: h*0.09), .init(hz: D4,  dur: h*0.91, gap: h*0.09),
            .init(hz: Bb3, dur: h*0.91, gap: h*0.09), .init(hz: F4,  dur: h*0.91, gap: h*0.09),
            .init(hz: D4,  dur: h*0.91, gap: h*0.09), .init(hz: Bb4, dur: h*0.91, gap: h*0.09),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.40),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.88),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.35),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.27) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.21) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.12) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 6 — "Firefly Lullaby" (G major, 96 BPM) [EVENING]
    // -----------------------------------------------------------------------
    // Form: Intro(12q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, Em feel) → Chorus-out(16q) → Outro(12q)
    // Total ≈ 116 q ≈ 72 s at 96 BPM.
    //
    // Pentatonic G (G A B D E) throughout. Intro and Outro are sparse/no arpeggio.
    // Chorus ascends to B5, denser arpeggio. Bridge uses Em colour (E4 B4 G4).

    private func buildTrack6_FireflyLullaby() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 96.0; let e: Float = q / 2; let h: Float = q * 2

        let G2: Float = 97.999;  let D3: Float = 146.832; let B2: Float = 123.471
        let G3: Float = 195.998; let D4: Float = 293.665; let B3: Float = 246.942; let E3: Float = 164.814
        let G4: Float = 391.995; let A4: Float = 440.000; let B4: Float = 493.883; let E4: Float = 329.628
        let D5: Float = 587.330; let E5: Float = 659.255; let G5: Float = 783.991
        let A5: Float = 880.000; let B5: Float = 987.767

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: G4, dur: q*0.92, gap: q*0.08), .init(hz: B4, dur: q*0.92, gap: q*0.08),
            .init(hz: D5, dur: h*0.90, gap: h*0.10), .init(hz: B4, dur: q*0.92, gap: q*0.08),
            .init(hz: A4, dur: q*0.92, gap: q*0.08), .init(hz: G4, dur: h*0.88, gap: h*0.12),
            .init(hz: G4, dur: q*2.85, gap: q*0.15),
        ]
        let melVerseA: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.92, gap: q*0.08), .init(hz: E5, dur: q*0.92, gap: q*0.08),
            .init(hz: D5,  dur: h*0.90, gap: h*0.10),
            .init(hz: B4,  dur: q*0.92, gap: q*0.08), .init(hz: A4, dur: q*0.92, gap: q*0.08),
            .init(hz: G4,  dur: h*0.88, gap: h*0.12),
            .init(hz: A4,  dur: q*0.90, gap: q*0.10), .init(hz: B4, dur: q*0.90, gap: q*0.10),
            .init(hz: D5,  dur: q*0.90, gap: q*0.10), .init(hz: E5, dur: q*0.90, gap: q*0.10),
            .init(hz: G5,  dur: h*0.88, gap: h*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: G5, dur: q*0.88, gap: q*0.12),
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: D5, dur: q*0.88, gap: q*0.12),
            .init(hz: G4,  dur: h*0.85, gap: h*0.15),
        ]
        // Chorus: ascend to B5, denser
        let melChorus: [MusicalNote] = [
            .init(hz: B5,  dur: q*0.88, gap: q*0.12), .init(hz: A5, dur: q*0.88, gap: q*0.12),
            .init(hz: G5,  dur: h*0.85, gap: h*0.15),
            .init(hz: E5,  dur: q*0.90, gap: q*0.10), .init(hz: D5, dur: q*0.90, gap: q*0.10),
            .init(hz: B4,  dur: h*0.88, gap: h*0.12),
            .init(hz: A4,  dur: q*0.90, gap: q*0.10), .init(hz: B4, dur: q*0.90, gap: q*0.10),
            .init(hz: D5,  dur: q*0.90, gap: q*0.10), .init(hz: G5, dur: q*0.88, gap: q*0.12),
            .init(hz: B5,  dur: q*0.85, gap: q*0.15), .init(hz: A5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5,  dur: h*0.82, gap: h*0.18),
        ]
        // Verse B: begins on A4, different shape
        let melVerseB: [MusicalNote] = [
            .init(hz: A4,  dur: q*0.92, gap: q*0.08), .init(hz: B4, dur: q*0.92, gap: q*0.08),
            .init(hz: D5,  dur: h*0.90, gap: h*0.10),
            .init(hz: E5,  dur: q*0.90, gap: q*0.10), .init(hz: G5, dur: q*0.90, gap: q*0.10),
            .init(hz: A5,  dur: h*0.88, gap: h*0.12),
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: E5, dur: q*0.88, gap: q*0.12),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: B4, dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: h*0.88, gap: h*0.12),
            .init(hz: B4,  dur: q*0.90, gap: q*0.10), .init(hz: D5, dur: q*0.90, gap: q*0.10),
            .init(hz: E5,  dur: q*0.90, gap: q*0.10), .init(hz: D5, dur: q*0.90, gap: q*0.10),
            .init(hz: G4,  dur: h*0.85, gap: h*0.15),
        ]
        // Bridge: Em feel — E5 D5 B4 A4
        let melBridge: [MusicalNote] = [
            .init(hz: E5,  dur: q*0.92, gap: q*0.08), .init(hz: D5, dur: q*0.92, gap: q*0.08),
            .init(hz: B4,  dur: h*0.90, gap: h*0.10),
            .init(hz: A4,  dur: q*0.90, gap: q*0.10), .init(hz: G4, dur: q*0.90, gap: q*0.10),
            .init(hz: B4,  dur: h*0.88, gap: h*0.12),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: E5, dur: q*0.88, gap: q*0.12),
            .init(hz: G5,  dur: h*0.85, gap: h*0.15),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: G5, dur: q*0.92, gap: q*0.08), .init(hz: E5, dur: q*0.92, gap: q*0.08),
            .init(hz: D5, dur: h*0.90, gap: h*0.10), .init(hz: B4, dur: q*0.92, gap: q*0.08),
            .init(hz: A4, dur: q*0.92, gap: q*0.08), .init(hz: G4, dur: h*0.88, gap: h*0.12),
            .init(hz: G4, dur: q*2.85, gap: q*0.15),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.50),
            .init(notes: melVerseA, volScale: 0.78),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.85),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.45),
        ]

        // ---- Bass -----------------------------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: G2, dur: q*2.75, gap: q*0.25), .init(hz: D3, dur: q*2.75, gap: q*0.25),
            .init(hz: G2, dur: q*2.75, gap: q*0.25), .init(hz: B2, dur: q*2.75, gap: q*0.25),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: D4, dur: h*0.80, gap: h*0.20),
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: B3, dur: h*0.80, gap: h*0.20),
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: D4, dur: h*0.80, gap: h*0.20),
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: B3, dur: h*0.80, gap: h*0.20),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: G3, dur: q*0.75, gap: q*0.25), .init(hz: B3, dur: q*0.75, gap: q*0.25),
            .init(hz: D4, dur: q*0.75, gap: q*0.25), .init(hz: G3, dur: q*0.75, gap: q*0.25),
            .init(hz: D4, dur: q*0.75, gap: q*0.25), .init(hz: G3, dur: q*0.75, gap: q*0.25),
            .init(hz: B3, dur: q*0.75, gap: q*0.25), .init(hz: D4, dur: q*0.75, gap: q*0.25),
            .init(hz: G3, dur: q*0.75, gap: q*0.25), .init(hz: B3, dur: q*0.75, gap: q*0.25),
            .init(hz: G3, dur: h*0.75, gap: h*0.25),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: E3, dur: h*0.80, gap: h*0.20), .init(hz: B2, dur: h*0.80, gap: h*0.20),
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: D4, dur: h*0.80, gap: h*0.20),
            .init(hz: B3, dur: h*0.80, gap: h*0.20), .init(hz: G3, dur: h*0.80, gap: h*0.20),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.45),
            .init(notes: bassVerse,  volScale: 0.78),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.85),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.40),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<12).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: G4, dur: e*0.68, gap: e*0.32), .init(hz: B4, dur: e*0.68, gap: e*0.32),
            .init(hz: D5, dur: e*0.68, gap: e*0.32), .init(hz: G5, dur: e*0.68, gap: e*0.32),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: B4, dur: e*0.65, gap: e*0.35), .init(hz: D5, dur: e*0.65, gap: e*0.35),
            .init(hz: G5, dur: e*0.65, gap: e*0.35), .init(hz: B5, dur: e*0.65, gap: e*0.35),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: E4, dur: e*0.68, gap: e*0.32), .init(hz: G4, dur: e*0.68, gap: e*0.32),
            .init(hz: B4, dur: e*0.68, gap: e*0.32), .init(hz: E5, dur: e*0.68, gap: e*0.32),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.55),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.75),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: G4, dur: q*2.90, gap: q*0.10), .init(hz: D4, dur: q*2.90, gap: q*0.10),
            .init(hz: G4, dur: q*2.90, gap: q*0.10), .init(hz: B3, dur: q*2.90, gap: q*0.10),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: G4, dur: h*0.94, gap: h*0.06), .init(hz: D4, dur: h*0.94, gap: h*0.06),
            .init(hz: B4, dur: h*0.94, gap: h*0.06), .init(hz: D5, dur: h*0.94, gap: h*0.06),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: E4, dur: h*0.94, gap: h*0.06), .init(hz: B3, dur: h*0.94, gap: h*0.06),
            .init(hz: G4, dur: h*0.94, gap: h*0.06), .init(hz: D4, dur: h*0.94, gap: h*0.06),
            .init(hz: B3, dur: h*0.94, gap: h*0.06), .init(hz: E4, dur: h*0.94, gap: h*0.06),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.38),
            .init(notes: padBase,   volScale: 0.72),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.32),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.24) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.17) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.10) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.10) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 7 — "Moon Garden" (E major, 104 BPM) [EVENING]
    // -----------------------------------------------------------------------
    // Form: Intro(12e) → Verse A(20e) → Chorus(18e) → Verse B(20e) →
    //       Chorus(18e) → Bridge(15e, C#m feel) → Chorus-out(18e) → Outro(12e)
    // All sections in 6/8 groupings of 3 eighth notes.
    // Total ≈ 133 eighth notes ≈ 38 s at 104 BPM (fast 6/8 feel).
    //
    // Chorus: ascends through B5, adds Cs6 peak. Bridge: C#m (Cs5 E5 B4 Gs4).

    private func buildTrack7_MoonGarden() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 104.0; let e: Float = q / 2; let h: Float = q * 2

        let E3: Float  = 164.814; let B3: Float  = 246.942; let Gs3: Float = 207.652; let Cs3: Float = 138.591
        let E4: Float  = 329.628; let Gs4: Float = 415.305; let B4: Float  = 493.883; let Cs4: Float = 277.183
        let E5: Float  = 659.255; let Gs5: Float = 830.609; let B5: Float  = 987.767; let Cs5: Float = 554.365
        let Fs5: Float = 739.989; let As5: Float = 932.328; let Cs6: Float = 1108.731

        // ---- Melody ---------------------------------------------------------
        // Intro: simple rising triad (12 eighth notes = 4 groups of 3)
        let melIntro: [MusicalNote] = [
            .init(hz: E4,  dur: e*0.88, gap: e*0.12), .init(hz: Gs4, dur: e*0.88, gap: e*0.12), .init(hz: B4,  dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: B4,  dur: e*0.88, gap: e*0.12), .init(hz: Gs4, dur: e*0.88, gap: e*0.12),
            .init(hz: E4,  dur: e*0.88, gap: e*0.12), .init(hz: Gs4, dur: e*0.88, gap: e*0.12), .init(hz: B4,  dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*2.80, gap: e*0.20),
        ]
        // Verse A: 6/8 groups — flowing 20-eighth phrases
        let melVerseA: [MusicalNote] = [
            .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: B5,  dur: e*0.88, gap: e*0.12),
            .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: Fs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12),
            .init(hz: Cs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12),
            .init(hz: B4,  dur: e*2.80, gap: e*0.20),
            .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Cs5, dur: e*0.88, gap: e*0.12), .init(hz: B4,  dur: e*0.88, gap: e*0.12),
            .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: Fs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*2.80, gap: e*0.20),
        ]
        // Chorus: ascend to Cs6
        let melChorus: [MusicalNote] = [
            .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: B5,  dur: e*0.88, gap: e*0.12), .init(hz: Cs6, dur: e*0.85, gap: e*0.15),
            .init(hz: B5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: Fs5, dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: B5,  dur: e*0.88, gap: e*0.12),
            .init(hz: Cs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12),
            .init(hz: B5,  dur: e*0.88, gap: e*0.12), .init(hz: As5, dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*2.80, gap: e*0.20),
        ]
        // Verse B: begins on Cs5
        let melVerseB: [MusicalNote] = [
            .init(hz: Cs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12),
            .init(hz: B5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12),
            .init(hz: Fs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Cs5, dur: e*0.88, gap: e*0.12),
            .init(hz: B4,  dur: e*2.80, gap: e*0.20),
            .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12), .init(hz: Cs5, dur: e*0.88, gap: e*0.12),
            .init(hz: B4,  dur: e*0.88, gap: e*0.12), .init(hz: Gs4, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*2.80, gap: e*0.20),
        ]
        // Bridge: C#m feel — Cs5 B4 Gs4 descending
        let melBridge: [MusicalNote] = [
            .init(hz: Cs5, dur: e*0.90, gap: e*0.10), .init(hz: B4,  dur: e*0.90, gap: e*0.10), .init(hz: Gs4, dur: e*0.90, gap: e*0.10),
            .init(hz: E5,  dur: e*0.90, gap: e*0.10), .init(hz: Cs5, dur: e*0.90, gap: e*0.10), .init(hz: B4,  dur: e*0.90, gap: e*0.10),
            .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: Fs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12),
            .init(hz: Gs4, dur: e*0.90, gap: e*0.10), .init(hz: B4,  dur: e*0.90, gap: e*0.10), .init(hz: Cs5, dur: e*0.90, gap: e*0.10),
            .init(hz: E5,  dur: e*2.80, gap: e*0.20),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: B5,  dur: e*0.88, gap: e*0.12), .init(hz: Gs5, dur: e*0.88, gap: e*0.12), .init(hz: E5,  dur: e*0.88, gap: e*0.12),
            .init(hz: Cs5, dur: e*0.88, gap: e*0.12), .init(hz: B4,  dur: e*0.88, gap: e*0.12), .init(hz: Gs4, dur: e*0.88, gap: e*0.12),
            .init(hz: E4,  dur: e*0.88, gap: e*0.12), .init(hz: Gs4, dur: e*0.88, gap: e*0.12), .init(hz: B4,  dur: e*0.88, gap: e*0.12),
            .init(hz: E5,  dur: e*2.80, gap: e*0.20),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.50),
            .init(notes: melVerseA, volScale: 0.78),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.85),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.45),
        ]

        // ---- Bass -----------------------------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: E3,  dur: q*2.80, gap: q*0.20), .init(hz: B3,  dur: q*2.80, gap: q*0.20),
            .init(hz: E3,  dur: q*2.80, gap: q*0.20), .init(hz: Gs3, dur: q*2.80, gap: q*0.20),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: E3,  dur: h*0.78, gap: h*0.22), .init(hz: B3,  dur: h*0.78, gap: h*0.22),
            .init(hz: E3,  dur: h*0.78, gap: h*0.22), .init(hz: Gs3, dur: h*0.78, gap: h*0.22),
            .init(hz: E3,  dur: h*0.78, gap: h*0.22), .init(hz: B3,  dur: h*0.78, gap: h*0.22),
            .init(hz: E3,  dur: h*0.78, gap: h*0.22), .init(hz: Gs3, dur: h*0.78, gap: h*0.22),
            .init(hz: E3,  dur: q*0.78, gap: q*0.22),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: E3,  dur: q*0.72, gap: q*0.28), .init(hz: Gs3, dur: q*0.72, gap: q*0.28),
            .init(hz: B3,  dur: q*0.72, gap: q*0.28), .init(hz: E3,  dur: q*0.72, gap: q*0.28),
            .init(hz: Gs3, dur: q*0.72, gap: q*0.28), .init(hz: B3,  dur: q*0.72, gap: q*0.28),
            .init(hz: E3,  dur: q*0.72, gap: q*0.28), .init(hz: Cs3, dur: q*0.72, gap: q*0.28),
            .init(hz: E3,  dur: h*0.72, gap: h*0.28),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: Cs3, dur: h*0.78, gap: h*0.22), .init(hz: Gs3, dur: h*0.78, gap: h*0.22),
            .init(hz: E3,  dur: h*0.78, gap: h*0.22), .init(hz: B3,  dur: h*0.78, gap: h*0.22),
            .init(hz: Gs3, dur: h*0.78, gap: h*0.22), .init(hz: Cs3, dur: q*0.78, gap: q*0.22),
            .init(hz: E3,  dur: q*0.78, gap: q*0.22),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.45),
            .init(notes: bassVerse,  volScale: 0.78),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.85),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.40),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<12).map { _ in .init(hz: 0, dur: e*0.5, gap: e*0.5) }
        let arpLo: [MusicalNote] = [
            .init(hz: E4,  dur: e*0.70, gap: e*0.30), .init(hz: Gs4, dur: e*0.70, gap: e*0.30),
            .init(hz: B4,  dur: e*0.70, gap: e*0.30), .init(hz: E5,  dur: e*0.70, gap: e*0.30),
        ]
        let arpHi: [MusicalNote] = [
            .init(hz: Gs4, dur: e*0.68, gap: e*0.32), .init(hz: B4,  dur: e*0.68, gap: e*0.32),
            .init(hz: E5,  dur: e*0.68, gap: e*0.32), .init(hz: Gs5, dur: e*0.68, gap: e*0.32),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: Cs4, dur: e*0.70, gap: e*0.30), .init(hz: E4,  dur: e*0.70, gap: e*0.30),
            .init(hz: Gs4, dur: e*0.70, gap: e*0.30), .init(hz: Cs5, dur: e*0.70, gap: e*0.30),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpLo,     volScale: 0.55),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpLo,     volScale: 0.60),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.75),
            .init(notes: arpHi,     volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: E4,  dur: q*2.90, gap: q*0.10), .init(hz: B4,  dur: q*2.90, gap: q*0.10),
            .init(hz: E4,  dur: q*2.90, gap: q*0.10), .init(hz: Gs4, dur: q*2.90, gap: q*0.10),
        ]
        let padBase: [MusicalNote] = [
            .init(hz: E4,  dur: h*0.95, gap: h*0.05), .init(hz: B4,  dur: h*0.95, gap: h*0.05),
            .init(hz: Gs4, dur: h*0.95, gap: h*0.05), .init(hz: B4,  dur: h*0.95, gap: h*0.05),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: Cs4, dur: h*0.95, gap: h*0.05), .init(hz: Gs4, dur: h*0.95, gap: h*0.05),
            .init(hz: E4,  dur: h*0.95, gap: h*0.05), .init(hz: B4,  dur: h*0.95, gap: h*0.05),
            .init(hz: Gs4, dur: h*0.95, gap: h*0.05), .init(hz: Cs4, dur: q*0.95, gap: q*0.05),
            .init(hz: E4,  dur: q*0.95, gap: q*0.05),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.38),
            .init(notes: padBase,   volScale: 0.72),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBase,   volScale: 0.75),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padBase,   volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.32),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.24) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.17) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.10) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 8 — "Copper Run" (D minor → F major, 118 BPM) [DAY]
    // -----------------------------------------------------------------------
    // Driving chiptune-platformer feel. Verse in D minor (D F A C),
    // chorus lifts to F major (F A C) for a satisfying minor→major payoff.
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, Bb major colour) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 55 s at 118 BPM.
    //
    // Sound: triangle bass gives a chiptune edge; melody uses osc(.sine)
    // with a tighter rhythmic staccato feel (shorter dur, more gap).

    private func buildTrack8_CopperRun() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 118.0; let e: Float = q / 2; let h: Float = q * 2

        // D minor scale notes
        let D3: Float = 146.832; let F3: Float = 174.614; let A3: Float = 220.000; let C3: Float = 130.813
        let D4: Float = 293.665; let F4: Float = 349.228; let A4: Float = 440.000; let C4: Float = 261.626
        let D5: Float = 587.330; let F5: Float = 698.456; let A5: Float = 880.000; let C5: Float = 523.251
        let G4: Float = 391.995; let G5: Float = 783.991; let Bb4: Float = 466.164; let Bb3: Float = 233.082
        let G3: Float = 195.998

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: D5, dur: q*0.75, gap: q*0.25), .init(hz: F5,  dur: q*0.75, gap: q*0.25),
            .init(hz: A5, dur: h*0.75, gap: h*0.25), .init(hz: F5,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5, dur: h*0.72, gap: h*0.28),
        ]
        // Verse: minor-flavoured driving run (staccato feel)
        let melVerseA: [MusicalNote] = [
            .init(hz: D5,  dur: q*0.70, gap: q*0.30), .init(hz: F5,  dur: q*0.70, gap: q*0.30),
            .init(hz: A5,  dur: q*0.70, gap: q*0.30), .init(hz: C5,  dur: q*0.70, gap: q*0.30),
            .init(hz: A5,  dur: q*0.70, gap: q*0.30), .init(hz: F5,  dur: q*0.70, gap: q*0.30),
            .init(hz: D5,  dur: h*0.68, gap: h*0.32),
            .init(hz: F5,  dur: q*0.70, gap: q*0.30), .init(hz: G5,  dur: q*0.70, gap: q*0.30),
            .init(hz: A5,  dur: q*0.70, gap: q*0.30), .init(hz: G5,  dur: q*0.70, gap: q*0.30),
            .init(hz: F5,  dur: q*0.70, gap: q*0.30), .init(hz: D5,  dur: q*0.70, gap: q*0.30),
            .init(hz: C5,  dur: h*0.68, gap: h*0.32),
        ]
        // Chorus: lifts to F major — F A C feel, brighter peak
        let melChorus: [MusicalNote] = [
            .init(hz: F5,  dur: q*0.72, gap: q*0.28), .init(hz: A5,  dur: q*0.72, gap: q*0.28),
            .init(hz: C5,  dur: q*0.72, gap: q*0.28), .init(hz: A5,  dur: q*0.72, gap: q*0.28),
            .init(hz: F5,  dur: h*0.70, gap: h*0.30),
            .init(hz: G5,  dur: q*0.72, gap: q*0.28), .init(hz: A5,  dur: q*0.72, gap: q*0.28),
            .init(hz: Bb4, dur: q*0.72, gap: q*0.28), .init(hz: A5,  dur: q*0.72, gap: q*0.28),
            .init(hz: G5,  dur: q*0.70, gap: q*0.30), .init(hz: F5,  dur: q*0.70, gap: q*0.30),
            .init(hz: A5,  dur: h*0.68, gap: h*0.32),
        ]
        let melVerseB: [MusicalNote] = [
            .init(hz: A5,  dur: q*0.70, gap: q*0.30), .init(hz: G5,  dur: q*0.70, gap: q*0.30),
            .init(hz: F5,  dur: q*0.70, gap: q*0.30), .init(hz: D5,  dur: q*0.70, gap: q*0.30),
            .init(hz: C5,  dur: h*0.68, gap: h*0.32),
            .init(hz: D5,  dur: q*0.70, gap: q*0.30), .init(hz: F5,  dur: q*0.70, gap: q*0.30),
            .init(hz: G5,  dur: q*0.70, gap: q*0.30), .init(hz: A5,  dur: q*0.70, gap: q*0.30),
            .init(hz: F5,  dur: q*0.70, gap: q*0.30), .init(hz: D5,  dur: q*0.70, gap: q*0.30),
            .init(hz: A4,  dur: h*0.68, gap: h*0.32),
        ]
        // Bridge: Bb major colour — Bb4 C5 D5 F5
        let melBridge: [MusicalNote] = [
            .init(hz: Bb4, dur: q*0.75, gap: q*0.25), .init(hz: C5,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5,  dur: h*0.72, gap: h*0.28),
            .init(hz: F5,  dur: q*0.75, gap: q*0.25), .init(hz: D5,  dur: q*0.75, gap: q*0.25),
            .init(hz: C5,  dur: h*0.72, gap: h*0.28),
            .init(hz: Bb4, dur: q*0.72, gap: q*0.28), .init(hz: C5,  dur: q*0.72, gap: q*0.28),
            .init(hz: D5,  dur: h*0.70, gap: h*0.30),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: A5, dur: q*0.72, gap: q*0.28), .init(hz: F5, dur: q*0.72, gap: q*0.28),
            .init(hz: D5, dur: h*0.70, gap: h*0.30), .init(hz: F5, dur: q*0.72, gap: q*0.28),
            .init(hz: D5, dur: h*0.68, gap: h*0.32),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.52),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.82),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.88),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.48),
        ]

        // ---- Bass (staccato, driving) ----------------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: D3, dur: q*0.55, gap: q*0.45), .init(hz: A3, dur: q*0.55, gap: q*0.45),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: D3,  dur: q*0.58, gap: q*0.42), .init(hz: D3,  dur: q*0.58, gap: q*0.42),
            .init(hz: F3,  dur: q*0.58, gap: q*0.42), .init(hz: A3,  dur: q*0.58, gap: q*0.42),
            .init(hz: C3,  dur: q*0.58, gap: q*0.42), .init(hz: D3,  dur: q*0.58, gap: q*0.42),
            .init(hz: A3,  dur: h*0.55, gap: h*0.45),
            .init(hz: Bb3, dur: q*0.58, gap: q*0.42), .init(hz: F3,  dur: q*0.58, gap: q*0.42),
            .init(hz: C3,  dur: q*0.58, gap: q*0.42), .init(hz: D3,  dur: q*0.58, gap: q*0.42),
            .init(hz: A3,  dur: q*0.58, gap: q*0.42), .init(hz: F3,  dur: q*0.58, gap: q*0.42),
            .init(hz: D3,  dur: h*0.55, gap: h*0.45),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: F3,  dur: q*0.55, gap: q*0.45), .init(hz: F3,  dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: q*0.55, gap: q*0.45), .init(hz: C4,  dur: q*0.55, gap: q*0.45),
            .init(hz: F3,  dur: h*0.52, gap: h*0.48),
            .init(hz: G3,  dur: q*0.55, gap: q*0.45), .init(hz: Bb3, dur: q*0.55, gap: q*0.45),
            .init(hz: F3,  dur: q*0.55, gap: q*0.45), .init(hz: A3,  dur: q*0.55, gap: q*0.45),
            .init(hz: C4,  dur: q*0.55, gap: q*0.45), .init(hz: F3,  dur: q*0.55, gap: q*0.45),
            .init(hz: A3,  dur: h*0.52, gap: h*0.48),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: Bb3, dur: h*0.60, gap: h*0.40), .init(hz: F3,  dur: h*0.60, gap: h*0.40),
            .init(hz: C4,  dur: h*0.60, gap: h*0.40), .init(hz: G3,  dur: h*0.60, gap: h*0.40),
            .init(hz: F3,  dur: h*0.60, gap: h*0.40), .init(hz: A3,  dur: h*0.60, gap: h*0.40),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.48),
            .init(notes: bassVerse,  volScale: 0.82),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.82),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.88),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.42),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpVerse: [MusicalNote] = [
            .init(hz: D4, dur: e*0.68, gap: e*0.32), .init(hz: F4,  dur: e*0.68, gap: e*0.32),
            .init(hz: A4, dur: e*0.68, gap: e*0.32), .init(hz: C5,  dur: e*0.68, gap: e*0.32),
        ]
        let arpChorus: [MusicalNote] = [
            .init(hz: F4, dur: e*0.65, gap: e*0.35), .init(hz: A4,  dur: e*0.65, gap: e*0.35),
            .init(hz: C5, dur: e*0.65, gap: e*0.35), .init(hz: F5,  dur: e*0.65, gap: e*0.35),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: Bb3, dur: e*0.68, gap: e*0.32), .init(hz: D4, dur: e*0.68, gap: e*0.32),
            .init(hz: F4,  dur: e*0.68, gap: e*0.32), .init(hz: Bb4, dur: e*0.68, gap: e*0.32),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpVerse,  volScale: 0.62),
            .init(notes: arpChorus, volScale: 1.00),
            .init(notes: arpVerse,  volScale: 0.65),
            .init(notes: arpChorus, volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpChorus, volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: D4, dur: h*0.91, gap: h*0.09), .init(hz: A4, dur: h*0.91, gap: h*0.09),
        ]
        let padVerse: [MusicalNote] = [
            .init(hz: D4, dur: h*0.91, gap: h*0.09), .init(hz: F4, dur: h*0.91, gap: h*0.09),
            .init(hz: A4, dur: h*0.91, gap: h*0.09), .init(hz: C5, dur: h*0.91, gap: h*0.09),
        ]
        let padChorus: [MusicalNote] = [
            .init(hz: F4, dur: h*0.91, gap: h*0.09), .init(hz: A4, dur: h*0.91, gap: h*0.09),
            .init(hz: C5, dur: h*0.91, gap: h*0.09), .init(hz: F5, dur: h*0.91, gap: h*0.09),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: Bb3, dur: h*0.91, gap: h*0.09), .init(hz: D4, dur: h*0.91, gap: h*0.09),
            .init(hz: F4,  dur: h*0.91, gap: h*0.09), .init(hz: C5, dur: h*0.91, gap: h*0.09),
            .init(hz: G4,  dur: h*0.91, gap: h*0.09), .init(hz: D4, dur: h*0.91, gap: h*0.09),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.38),
            .init(notes: padVerse,  volScale: 0.72),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padVerse,  volScale: 0.72),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.32),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.28) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.23) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .triangle, baseVol: 0.13) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 9 — "Voltage" (E minor, 128 BPM) [DAY]
    // -----------------------------------------------------------------------
    // Punchy laid-back groove with a walking minor-pentatonic bass line.
    // Feels like a cooler side-scroller; bridge opens briefly to G major.
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, G major colour) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 50.6 s at 128 BPM.

    private func buildTrack9_Voltage() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 128.0; let e: Float = q / 2; let h: Float = q * 2

        let E2: Float = 82.407;  let B2: Float = 123.471; let G2: Float = 97.999
        let D3: Float = 146.832; let E3: Float = 164.814; let G3: Float = 195.998; let B3: Float = 246.942; let A3: Float = 220.000
        let E4: Float = 329.628; let G4: Float = 391.995; let B4: Float = 493.883; let A4: Float = 440.000
        let D5: Float = 587.330
        let E5: Float = 659.255; let G5: Float = 783.991; let B5: Float = 987.767; let A5: Float = 880.000

        // ---- Melody ---------------------------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: E5, dur: q*0.72, gap: q*0.28), .init(hz: G5, dur: q*0.72, gap: q*0.28),
            .init(hz: B5, dur: h*0.70, gap: h*0.30), .init(hz: G5, dur: q*0.72, gap: q*0.28),
            .init(hz: E5, dur: h*0.68, gap: h*0.32),
        ]
        // Verse: Em pentatonic (E G A B D) driving run
        let melVerseA: [MusicalNote] = [
            .init(hz: E5,  dur: q*0.68, gap: q*0.32), .init(hz: G5,  dur: q*0.68, gap: q*0.32),
            .init(hz: A5,  dur: q*0.68, gap: q*0.32), .init(hz: B5,  dur: q*0.68, gap: q*0.32),
            .init(hz: A5,  dur: q*0.68, gap: q*0.32), .init(hz: G5,  dur: q*0.68, gap: q*0.32),
            .init(hz: E5,  dur: h*0.65, gap: h*0.35),
            .init(hz: D5,  dur: q*0.68, gap: q*0.32), .init(hz: E5,  dur: q*0.68, gap: q*0.32),
            .init(hz: G5,  dur: q*0.68, gap: q*0.32), .init(hz: B5,  dur: q*0.68, gap: q*0.32),
            .init(hz: A5,  dur: q*0.65, gap: q*0.35), .init(hz: G5,  dur: q*0.65, gap: q*0.35),
            .init(hz: E5,  dur: h*0.65, gap: h*0.35),
        ]
        // Chorus: syncopated Em → G lift, peak at B5
        let melChorus: [MusicalNote] = [
            .init(hz: B5,  dur: q*0.70, gap: q*0.30), .init(hz: A5,  dur: q*0.70, gap: q*0.30),
            .init(hz: G5,  dur: h*0.68, gap: h*0.32),
            .init(hz: E5,  dur: q*0.70, gap: q*0.30), .init(hz: D5,  dur: q*0.70, gap: q*0.30),
            .init(hz: E5,  dur: h*0.68, gap: h*0.32),
            .init(hz: G5,  dur: q*0.70, gap: q*0.30), .init(hz: A5,  dur: q*0.70, gap: q*0.30),
            .init(hz: B5,  dur: q*0.68, gap: q*0.32), .init(hz: G5,  dur: q*0.68, gap: q*0.32),
            .init(hz: E5,  dur: h*0.65, gap: h*0.35),
        ]
        let melVerseB: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.68, gap: q*0.32), .init(hz: A5,  dur: q*0.68, gap: q*0.32),
            .init(hz: B5,  dur: q*0.68, gap: q*0.32), .init(hz: A5,  dur: q*0.68, gap: q*0.32),
            .init(hz: G5,  dur: h*0.65, gap: h*0.35),
            .init(hz: E5,  dur: q*0.68, gap: q*0.32), .init(hz: G5,  dur: q*0.68, gap: q*0.32),
            .init(hz: A5,  dur: q*0.68, gap: q*0.32), .init(hz: G5,  dur: q*0.68, gap: q*0.32),
            .init(hz: D5,  dur: q*0.65, gap: q*0.35), .init(hz: E5,  dur: q*0.65, gap: q*0.35),
            .init(hz: B4,  dur: h*0.65, gap: h*0.35),
        ]
        // Bridge: opens to G major (G B D) — brighter contrast
        let melBridge: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.75, gap: q*0.25), .init(hz: B5,  dur: q*0.75, gap: q*0.25),
            .init(hz: D5,  dur: h*0.72, gap: h*0.28),
            .init(hz: A5,  dur: q*0.72, gap: q*0.28), .init(hz: G5,  dur: q*0.72, gap: q*0.28),
            .init(hz: B4,  dur: h*0.70, gap: h*0.30),
            .init(hz: A4,  dur: q*0.72, gap: q*0.28), .init(hz: B4,  dur: q*0.72, gap: q*0.28),
            .init(hz: E5,  dur: h*0.70, gap: h*0.30),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: B5, dur: q*0.70, gap: q*0.30), .init(hz: G5, dur: q*0.70, gap: q*0.30),
            .init(hz: E5, dur: h*0.68, gap: h*0.32), .init(hz: G5, dur: q*0.70, gap: q*0.30),
            .init(hz: E5, dur: h*0.65, gap: h*0.35),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.52),
            .init(notes: melVerseA, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.82),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.88),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.48),
        ]

        // ---- Bass (walking minor-pentatonic, punchy) -------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: E2, dur: q*0.52, gap: q*0.48), .init(hz: B2, dur: q*0.52, gap: q*0.48),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: E3, dur: q*0.55, gap: q*0.45), .init(hz: G3, dur: q*0.55, gap: q*0.45),
            .init(hz: A3, dur: q*0.55, gap: q*0.45), .init(hz: B3, dur: q*0.55, gap: q*0.45),
            .init(hz: E3, dur: q*0.55, gap: q*0.45), .init(hz: D3, dur: q*0.55, gap: q*0.45),
            .init(hz: E3, dur: h*0.52, gap: h*0.48),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: A3, dur: q*0.55, gap: q*0.45),
            .init(hz: B3, dur: q*0.55, gap: q*0.45), .init(hz: A3, dur: q*0.55, gap: q*0.45),
            .init(hz: G3, dur: q*0.55, gap: q*0.45), .init(hz: E3, dur: q*0.55, gap: q*0.45),
            .init(hz: B2, dur: h*0.52, gap: h*0.48),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: E3, dur: q*0.52, gap: q*0.48), .init(hz: E3, dur: q*0.52, gap: q*0.48),
            .init(hz: B3, dur: q*0.52, gap: q*0.48), .init(hz: A3, dur: q*0.52, gap: q*0.48),
            .init(hz: G3, dur: q*0.52, gap: q*0.48), .init(hz: E3, dur: q*0.52, gap: q*0.48),
            .init(hz: D3, dur: q*0.52, gap: q*0.48), .init(hz: E3, dur: q*0.52, gap: q*0.48),
            .init(hz: G3, dur: q*0.52, gap: q*0.48), .init(hz: B3, dur: q*0.52, gap: q*0.48),
            .init(hz: E3, dur: h*0.50, gap: h*0.50),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: G2, dur: h*0.58, gap: h*0.42), .init(hz: B2, dur: h*0.58, gap: h*0.42),
            .init(hz: G3, dur: h*0.58, gap: h*0.42), .init(hz: D3, dur: h*0.58, gap: h*0.42),
            .init(hz: A3, dur: h*0.58, gap: h*0.42), .init(hz: E3, dur: h*0.58, gap: h*0.42),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.48),
            .init(notes: bassVerse,  volScale: 0.82),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.82),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.88),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.42),
        ]

        // ---- Arpeggio -------------------------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpVerse: [MusicalNote] = [
            .init(hz: E4, dur: e*0.65, gap: e*0.35), .init(hz: G4, dur: e*0.65, gap: e*0.35),
            .init(hz: B4, dur: e*0.65, gap: e*0.35), .init(hz: E5, dur: e*0.65, gap: e*0.35),
        ]
        let arpChorus: [MusicalNote] = [
            .init(hz: G4, dur: e*0.62, gap: e*0.38), .init(hz: B4, dur: e*0.62, gap: e*0.38),
            .init(hz: E5, dur: e*0.62, gap: e*0.38), .init(hz: G5, dur: e*0.62, gap: e*0.38),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: G4, dur: e*0.65, gap: e*0.35), .init(hz: B4, dur: e*0.65, gap: e*0.35),
            .init(hz: D5, dur: e*0.65, gap: e*0.35), .init(hz: G5, dur: e*0.65, gap: e*0.35),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpVerse,  volScale: 0.62),
            .init(notes: arpChorus, volScale: 1.00),
            .init(notes: arpVerse,  volScale: 0.65),
            .init(notes: arpChorus, volScale: 1.00),
            .init(notes: arpBridge, volScale: 0.80),
            .init(notes: arpChorus, volScale: 1.00),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad ------------------------------------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: E4, dur: h*0.92, gap: h*0.08), .init(hz: B4, dur: h*0.92, gap: h*0.08),
        ]
        let padVerse: [MusicalNote] = [
            .init(hz: E4, dur: h*0.92, gap: h*0.08), .init(hz: G4, dur: h*0.92, gap: h*0.08),
            .init(hz: B4, dur: h*0.92, gap: h*0.08), .init(hz: D5, dur: h*0.92, gap: h*0.08),
        ]
        let padChorus: [MusicalNote] = [
            .init(hz: G4, dur: h*0.92, gap: h*0.08), .init(hz: B4, dur: h*0.92, gap: h*0.08),
            .init(hz: E5, dur: h*0.92, gap: h*0.08), .init(hz: G5, dur: h*0.92, gap: h*0.08),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: G4, dur: h*0.92, gap: h*0.08), .init(hz: B4, dur: h*0.92, gap: h*0.08),
            .init(hz: D5, dur: h*0.92, gap: h*0.08), .init(hz: A4, dur: h*0.92, gap: h*0.08),
            .init(hz: E5, dur: h*0.92, gap: h*0.08), .init(hz: B4, dur: h*0.92, gap: h*0.08),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.38),
            .init(notes: padVerse,  volScale: 0.72),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padVerse,  volScale: 0.75),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.32),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.27) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.23) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .triangle, baseVol: 0.12) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.09) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 10 — "Lost Ruins" (A minor, 100 BPM) [EVENING]
    // -----------------------------------------------------------------------
    // Epic-but-gentle exploration theme. Melodic arch: Am → C → G → F → Am.
    // Bridge modulates briefly to F major for contrast before returning to Am.
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, F major colour) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 64.8 s at 100 BPM.
    //
    // Sound: slower, more legato melody (longer gate dur, smaller gap).
    // Bass uses gentle half-note pulse. Arpeggio is softer and more atmospheric.

    private func buildTrack10_LostRuins() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 100.0; let e: Float = q / 2; let h: Float = q * 2

        let A2: Float = 110.000; let C3: Float = 130.813; let E3: Float = 164.814
        let A3: Float = 220.000; let C4: Float = 261.626; let E4: Float = 329.628; let G3: Float = 195.998
        let A4: Float = 440.000; let C5: Float = 523.251; let E5: Float = 659.255; let G4: Float = 391.995
        let F4: Float = 349.228; let F5: Float = 698.456; let F3: Float = 174.614; let B4: Float = 493.883
        let D5: Float = 587.330; let G5: Float = 783.991; let A5: Float = 880.000

        // ---- Melody (legato, expressive) ------------------------------------
        let melIntro: [MusicalNote] = [
            .init(hz: A4, dur: q*0.90, gap: q*0.10), .init(hz: C5,  dur: q*0.90, gap: q*0.10),
            .init(hz: E5, dur: h*0.88, gap: h*0.12), .init(hz: C5,  dur: q*0.90, gap: q*0.10),
            .init(hz: A4, dur: h*0.85, gap: h*0.15),
        ]
        // Verse A: Am → C → G arc
        let melVerseA: [MusicalNote] = [
            .init(hz: A5,  dur: q*0.90, gap: q*0.10), .init(hz: G5,  dur: q*0.90, gap: q*0.10),
            .init(hz: E5,  dur: h*0.88, gap: h*0.12),
            .init(hz: C5,  dur: q*0.90, gap: q*0.10), .init(hz: D5,  dur: q*0.90, gap: q*0.10),
            .init(hz: E5,  dur: h*0.88, gap: h*0.12),
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: A4,  dur: q*0.88, gap: q*0.12),
            .init(hz: B4,  dur: q*0.88, gap: q*0.12), .init(hz: C5,  dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: h*0.85, gap: h*0.15),
        ]
        // Chorus: sweeps up to G5, fuller and more epic
        let melChorus: [MusicalNote] = [
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: G5,  dur: q*0.88, gap: q*0.12),
            .init(hz: A5,  dur: h*0.88, gap: h*0.12),
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: h*0.88, gap: h*0.12),
            .init(hz: D5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: A5,  dur: q*0.88, gap: q*0.12),
            .init(hz: E5,  dur: h*0.85, gap: h*0.15),
        ]
        // Verse B: starts on C5, different shape
        let melVerseB: [MusicalNote] = [
            .init(hz: C5,  dur: q*0.90, gap: q*0.10), .init(hz: E5,  dur: q*0.90, gap: q*0.10),
            .init(hz: G5,  dur: h*0.88, gap: h*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: G5,  dur: q*0.88, gap: q*0.12),
            .init(hz: E5,  dur: h*0.88, gap: h*0.12),
            .init(hz: F5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: A4,  dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: E5,  dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: h*0.85, gap: h*0.15),
        ]
        // Bridge: F major colour (F A C) — lighter contrast
        let melBridge: [MusicalNote] = [
            .init(hz: F5,  dur: q*0.90, gap: q*0.10), .init(hz: A5,  dur: q*0.90, gap: q*0.10),
            .init(hz: C5,  dur: h*0.88, gap: h*0.12),
            .init(hz: A5,  dur: q*0.88, gap: q*0.12), .init(hz: G5,  dur: q*0.88, gap: q*0.12),
            .init(hz: F5,  dur: h*0.88, gap: h*0.12),
            .init(hz: E5,  dur: q*0.88, gap: q*0.12), .init(hz: C5,  dur: q*0.88, gap: q*0.12),
            .init(hz: A4,  dur: h*0.85, gap: h*0.15),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.90, gap: q*0.10), .init(hz: E5,  dur: q*0.90, gap: q*0.10),
            .init(hz: A4,  dur: h*0.88, gap: h*0.12), .init(hz: C5,  dur: q*0.90, gap: q*0.10),
            .init(hz: A4,  dur: h*0.85, gap: h*0.15),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.50),
            .init(notes: melVerseA, volScale: 0.78),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.85),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.45),
        ]

        // ---- Bass (legato half-note pulse) ----------------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: A2, dur: h*0.80, gap: h*0.20), .init(hz: E3, dur: h*0.80, gap: h*0.20),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: A3, dur: h*0.80, gap: h*0.20), .init(hz: C4, dur: h*0.80, gap: h*0.20),
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: E4, dur: h*0.80, gap: h*0.20),
            .init(hz: A3, dur: h*0.80, gap: h*0.20), .init(hz: C4, dur: h*0.80, gap: h*0.20),
            .init(hz: E3, dur: h*0.80, gap: h*0.20), .init(hz: A3, dur: h*0.80, gap: h*0.20),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: A3, dur: q*0.75, gap: q*0.25), .init(hz: E4, dur: q*0.75, gap: q*0.25),
            .init(hz: C4, dur: q*0.75, gap: q*0.25), .init(hz: G3, dur: q*0.75, gap: q*0.25),
            .init(hz: A3, dur: q*0.75, gap: q*0.25), .init(hz: C4, dur: q*0.75, gap: q*0.25),
            .init(hz: G3, dur: q*0.75, gap: q*0.25), .init(hz: E4, dur: q*0.75, gap: q*0.25),
            .init(hz: A3, dur: q*0.75, gap: q*0.25), .init(hz: E3, dur: q*0.75, gap: q*0.25),
            .init(hz: A3, dur: h*0.72, gap: h*0.28),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: F3, dur: h*0.80, gap: h*0.20), .init(hz: C4, dur: h*0.80, gap: h*0.20),
            .init(hz: G3, dur: h*0.80, gap: h*0.20), .init(hz: C3, dur: h*0.80, gap: h*0.20),
            .init(hz: F3, dur: h*0.80, gap: h*0.20), .init(hz: A3, dur: h*0.80, gap: h*0.20),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.45),
            .init(notes: bassVerse,  volScale: 0.78),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.85),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.40),
        ]

        // ---- Arpeggio (atmospheric, softer) ---------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpVerse: [MusicalNote] = [
            .init(hz: A4, dur: e*0.72, gap: e*0.28), .init(hz: C5, dur: e*0.72, gap: e*0.28),
            .init(hz: E5, dur: e*0.72, gap: e*0.28), .init(hz: A5, dur: e*0.72, gap: e*0.28),
        ]
        let arpChorus: [MusicalNote] = [
            .init(hz: C5, dur: e*0.70, gap: e*0.30), .init(hz: E5, dur: e*0.70, gap: e*0.30),
            .init(hz: G5, dur: e*0.70, gap: e*0.30), .init(hz: C5, dur: e*0.70, gap: e*0.30),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: F4, dur: e*0.72, gap: e*0.28), .init(hz: A4, dur: e*0.72, gap: e*0.28),
            .init(hz: C5, dur: e*0.72, gap: e*0.28), .init(hz: F5, dur: e*0.72, gap: e*0.28),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpVerse,  volScale: 0.55),
            .init(notes: arpChorus, volScale: 0.90),
            .init(notes: arpVerse,  volScale: 0.58),
            .init(notes: arpChorus, volScale: 0.90),
            .init(notes: arpBridge, volScale: 0.75),
            .init(notes: arpChorus, volScale: 0.90),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad (sustained, atmospheric) -----------------------------------
        let padIntro: [MusicalNote] = [
            .init(hz: A4, dur: h*0.95, gap: h*0.05), .init(hz: E4, dur: h*0.95, gap: h*0.05),
        ]
        let padVerse: [MusicalNote] = [
            .init(hz: A4, dur: h*0.95, gap: h*0.05), .init(hz: C5, dur: h*0.95, gap: h*0.05),
            .init(hz: G4, dur: h*0.95, gap: h*0.05), .init(hz: E5, dur: h*0.95, gap: h*0.05),
        ]
        let padChorus: [MusicalNote] = [
            .init(hz: A4, dur: h*0.95, gap: h*0.05), .init(hz: E5, dur: h*0.95, gap: h*0.05),
            .init(hz: C5, dur: h*0.95, gap: h*0.05), .init(hz: G5, dur: h*0.95, gap: h*0.05),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: F4, dur: h*0.95, gap: h*0.05), .init(hz: C5, dur: h*0.95, gap: h*0.05),
            .init(hz: A4, dur: h*0.95, gap: h*0.05), .init(hz: E5, dur: h*0.95, gap: h*0.05),
            .init(hz: G4, dur: h*0.95, gap: h*0.05), .init(hz: C5, dur: h*0.95, gap: h*0.05),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.40),
            .init(notes: padVerse,  volScale: 0.75),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padVerse,  volScale: 0.75),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.35),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.26) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.20) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.10) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.11) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    // -----------------------------------------------------------------------
    // MARK: Track 11 — "Dusk Drift" (C minor → Eb major, 92 BPM) [EVENING]
    // -----------------------------------------------------------------------
    // Cool laid-back groove, half-time feel. Verse in C minor; chorus brightens
    // to Eb major. Synth-pad texture, sparse punchy bass hits (quarter-note pulse).
    // Form: Intro(8q) → Verse A(16q) → Chorus(16q) → Verse B(16q) →
    //       Chorus(16q) → Bridge(12q, Ab major colour) → Chorus-out(16q) → Outro(8q)
    // Total ≈ 108 q ≈ 70.4 s at 92 BPM.

    private func buildTrack11_DuskDrift() -> [AVAudioPCMBuffer] {
        let q: Float = 60.0 / 92.0; let e: Float = q / 2; let h: Float = q * 2

        let C3: Float = 130.813; let Eb3: Float = 155.563; let G3: Float = 195.998; let Ab2: Float = 103.826
        let C4: Float = 261.626; let Eb4: Float = 311.127; let G4: Float = 391.995; let Ab3: Float = 207.652
        let C5: Float = 523.251; let Eb5: Float = 622.254; let G5: Float = 783.991; let Ab4: Float = 415.305
        let Bb3: Float = 233.082; let Bb4: Float = 466.164; let F4: Float = 349.228; let F3: Float = 174.614

        // ---- Melody (slower, more legato — laid-back groove feel) -----------
        let melIntro: [MusicalNote] = [
            .init(hz: C5,  dur: q*0.88, gap: q*0.12), .init(hz: Eb5, dur: q*0.88, gap: q*0.12),
            .init(hz: G5,  dur: h*0.85, gap: h*0.15), .init(hz: Eb5, dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: h*0.83, gap: h*0.17),
        ]
        // Verse A: Cm groove — C Eb G Bb
        let melVerseA: [MusicalNote] = [
            .init(hz: C5,  dur: q*0.85, gap: q*0.15), .init(hz: Eb5, dur: q*0.85, gap: q*0.15),
            .init(hz: G5,  dur: h*0.83, gap: h*0.17),
            .init(hz: Bb4, dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Eb5, dur: h*0.83, gap: h*0.17),
            .init(hz: C5,  dur: q*0.83, gap: q*0.17), .init(hz: Bb4, dur: q*0.83, gap: q*0.17),
            .init(hz: G4,  dur: q*0.83, gap: q*0.17), .init(hz: Ab4, dur: q*0.83, gap: q*0.17),
            .init(hz: Bb4, dur: q*0.83, gap: q*0.17), .init(hz: C5,  dur: q*0.83, gap: q*0.17),
            .init(hz: G4,  dur: h*0.80, gap: h*0.20),
        ]
        // Chorus: lifts to Eb major — Eb G Bb, brighter and warmer
        let melChorus: [MusicalNote] = [
            .init(hz: Eb5, dur: q*0.85, gap: q*0.15), .init(hz: G5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Bb4, dur: h*0.83, gap: h*0.17),
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: Eb5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5,  dur: h*0.83, gap: h*0.17),
            .init(hz: Bb4, dur: q*0.83, gap: q*0.17), .init(hz: C5,  dur: q*0.83, gap: q*0.17),
            .init(hz: Eb5, dur: q*0.83, gap: q*0.17), .init(hz: G5,  dur: q*0.83, gap: q*0.17),
            .init(hz: Eb5, dur: h*0.80, gap: h*0.20),
        ]
        let melVerseB: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: Eb5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5,  dur: h*0.83, gap: h*0.17),
            .init(hz: Bb4, dur: q*0.85, gap: q*0.15), .init(hz: C5,  dur: q*0.85, gap: q*0.15),
            .init(hz: Eb5, dur: h*0.83, gap: h*0.17),
            .init(hz: G5,  dur: q*0.83, gap: q*0.17), .init(hz: Bb4, dur: q*0.83, gap: q*0.17),
            .init(hz: Ab4, dur: q*0.83, gap: q*0.17), .init(hz: G4,  dur: q*0.83, gap: q*0.17),
            .init(hz: Ab4, dur: q*0.83, gap: q*0.17), .init(hz: Bb4, dur: q*0.83, gap: q*0.17),
            .init(hz: C5,  dur: h*0.80, gap: h*0.20),
        ]
        // Bridge: Ab major colour (Ab C Eb) — dream-like contrast
        let melBridge: [MusicalNote] = [
            .init(hz: Ab4, dur: q*0.88, gap: q*0.12), .init(hz: C5,  dur: q*0.88, gap: q*0.12),
            .init(hz: Eb5, dur: h*0.85, gap: h*0.15),
            .init(hz: G5,  dur: q*0.85, gap: q*0.15), .init(hz: Eb5, dur: q*0.85, gap: q*0.15),
            .init(hz: C5,  dur: h*0.83, gap: h*0.17),
            .init(hz: Bb4, dur: q*0.83, gap: q*0.17), .init(hz: G4,  dur: q*0.83, gap: q*0.17),
            .init(hz: Ab4, dur: h*0.80, gap: h*0.20),
        ]
        let melOutro: [MusicalNote] = [
            .init(hz: G5,  dur: q*0.88, gap: q*0.12), .init(hz: Eb5, dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: h*0.85, gap: h*0.15), .init(hz: Eb5, dur: q*0.88, gap: q*0.12),
            .init(hz: C5,  dur: h*0.83, gap: h*0.17),
        ]

        let melSections: [SectionSpec] = [
            .init(notes: melIntro,  volScale: 0.50),
            .init(notes: melVerseA, volScale: 0.78),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melVerseB, volScale: 0.80),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melBridge, volScale: 0.85),
            .init(notes: melChorus, volScale: 1.00),
            .init(notes: melOutro,  volScale: 0.45),
        ]

        // ---- Bass (sparse half-note hits, laid-back) -------------------------
        let bassIntro: [MusicalNote] = [
            .init(hz: C3,  dur: h*0.65, gap: h*0.35), .init(hz: G3,  dur: h*0.65, gap: h*0.35),
        ]
        let bassVerse: [MusicalNote] = [
            .init(hz: C3,  dur: h*0.68, gap: h*0.32), .init(hz: Eb3, dur: h*0.68, gap: h*0.32),
            .init(hz: G3,  dur: h*0.68, gap: h*0.32), .init(hz: Bb3, dur: h*0.68, gap: h*0.32),
            .init(hz: C3,  dur: h*0.68, gap: h*0.32), .init(hz: G3,  dur: h*0.68, gap: h*0.32),
            .init(hz: Ab2, dur: h*0.68, gap: h*0.32), .init(hz: Eb3, dur: h*0.68, gap: h*0.32),
        ]
        let bassChorus: [MusicalNote] = [
            .init(hz: Eb3, dur: h*0.68, gap: h*0.32), .init(hz: G3,  dur: h*0.68, gap: h*0.32),
            .init(hz: Bb3, dur: h*0.68, gap: h*0.32), .init(hz: G3,  dur: h*0.68, gap: h*0.32),
            .init(hz: Eb3, dur: h*0.68, gap: h*0.32), .init(hz: C4,  dur: h*0.68, gap: h*0.32),
            .init(hz: Bb3, dur: h*0.68, gap: h*0.32), .init(hz: Eb3, dur: h*0.68, gap: h*0.32),
        ]
        let bassBridge: [MusicalNote] = [
            .init(hz: Ab2, dur: h*0.70, gap: h*0.30), .init(hz: C3,  dur: h*0.70, gap: h*0.30),
            .init(hz: Eb3, dur: h*0.70, gap: h*0.30), .init(hz: Ab3, dur: h*0.70, gap: h*0.30),
            .init(hz: F3,  dur: h*0.70, gap: h*0.30), .init(hz: C3,  dur: h*0.70, gap: h*0.30),
        ]

        let bassSections: [SectionSpec] = [
            .init(notes: bassIntro,  volScale: 0.45),
            .init(notes: bassVerse,  volScale: 0.78),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassVerse,  volScale: 0.80),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassBridge, volScale: 0.85),
            .init(notes: bassChorus, volScale: 1.00),
            .init(notes: bassIntro,  volScale: 0.40),
        ]

        // ---- Arpeggio (sparse, floating) ------------------------------------
        let arpOff: [MusicalNote] = (0..<8).map { _ in .init(hz: 0, dur: q*0.5, gap: q*0.5) }
        let arpVerse: [MusicalNote] = [
            .init(hz: C4,  dur: e*0.72, gap: e*0.28), .init(hz: Eb4, dur: e*0.72, gap: e*0.28),
            .init(hz: G4,  dur: e*0.72, gap: e*0.28), .init(hz: C5,  dur: e*0.72, gap: e*0.28),
        ]
        let arpChorus: [MusicalNote] = [
            .init(hz: Eb4, dur: e*0.70, gap: e*0.30), .init(hz: G4,  dur: e*0.70, gap: e*0.30),
            .init(hz: Bb4, dur: e*0.70, gap: e*0.30), .init(hz: Eb5, dur: e*0.70, gap: e*0.30),
        ]
        let arpBridge: [MusicalNote] = [
            .init(hz: Ab3, dur: e*0.72, gap: e*0.28), .init(hz: C4,  dur: e*0.72, gap: e*0.28),
            .init(hz: Eb4, dur: e*0.72, gap: e*0.28), .init(hz: Ab4, dur: e*0.72, gap: e*0.28),
        ]

        let arpSections: [SectionSpec] = [
            .init(notes: arpOff,    volScale: 0.0),
            .init(notes: arpVerse,  volScale: 0.55),
            .init(notes: arpChorus, volScale: 0.95),
            .init(notes: arpVerse,  volScale: 0.58),
            .init(notes: arpChorus, volScale: 0.95),
            .init(notes: arpBridge, volScale: 0.75),
            .init(notes: arpChorus, volScale: 0.95),
            .init(notes: arpOff,    volScale: 0.0),
        ]

        // ---- Pad (warm, sustained — the dominant texture) -------------------
        let padIntro: [MusicalNote] = [
            .init(hz: C4,  dur: h*0.96, gap: h*0.04), .init(hz: G4,  dur: h*0.96, gap: h*0.04),
        ]
        let padVerse: [MusicalNote] = [
            .init(hz: C4,  dur: h*0.96, gap: h*0.04), .init(hz: Eb4, dur: h*0.96, gap: h*0.04),
            .init(hz: G4,  dur: h*0.96, gap: h*0.04), .init(hz: Bb4, dur: h*0.96, gap: h*0.04),
        ]
        let padChorus: [MusicalNote] = [
            .init(hz: Eb4, dur: h*0.96, gap: h*0.04), .init(hz: G4,  dur: h*0.96, gap: h*0.04),
            .init(hz: Bb4, dur: h*0.96, gap: h*0.04), .init(hz: Eb5, dur: h*0.96, gap: h*0.04),
        ]
        let padBridge: [MusicalNote] = [
            .init(hz: Ab3, dur: h*0.96, gap: h*0.04), .init(hz: C4,  dur: h*0.96, gap: h*0.04),
            .init(hz: Eb4, dur: h*0.96, gap: h*0.04), .init(hz: Ab4, dur: h*0.96, gap: h*0.04),
            .init(hz: F4,  dur: h*0.96, gap: h*0.04), .init(hz: C4,  dur: h*0.96, gap: h*0.04),
        ]

        let padSections: [SectionSpec] = [
            .init(notes: padIntro,  volScale: 0.42),
            .init(notes: padVerse,  volScale: 0.78),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padVerse,  volScale: 0.80),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padBridge, volScale: 0.85),
            .init(notes: padChorus, volScale: 1.00),
            .init(notes: padIntro,  volScale: 0.36),
        ]

        var voices: [AVAudioPCMBuffer] = []
        if let v = buildSectionedVoice(sections: melSections,  shape: .sine,     baseVol: 0.25) { voices.append(v) }
        if let v = buildSectionedVoice(sections: bassSections,  shape: .triangle, baseVol: 0.19) { voices.append(v) }
        if let v = buildSectionedVoice(sections: arpSections,   shape: .sine,     baseVol: 0.10) { voices.append(v) }
        if let v = buildSectionedVoice(sections: padSections,   shape: .sine,     baseVol: 0.12) { voices.append(v) }
        return alignVoiceLengths(voices)
    }

    /// Smooth pad envelope: retained for any future callers.
    @inline(__always)
    private func padEnvelope(_ t: Float, attack: Float, release: Float, total: Float) -> Float {
        if t < attack { return t / attack }
        let tail = total - release
        if t > tail  { return max(0, (total - t) / release) }
        return 1.0
    }

    /// Pad all voice buffers to the same frame length (the longest one) by appending silence.
    /// This ensures all 4 voices of a track loop in lock-step with no drift.
    private func alignVoiceLengths(_ voices: [AVAudioPCMBuffer]) -> [AVAudioPCMBuffer] {
        guard voices.count > 1 else { return voices }
        let maxLen = voices.map { Int($0.frameLength) }.max() ?? 0
        return voices.map { buf in
            let n = Int(buf.frameLength)
            guard n < maxLen else { return buf }
            // Create a new buffer with the padded length.
            guard let padded = AVAudioPCMBuffer(pcmFormat: buf.format,
                                               frameCapacity: AVAudioFrameCount(maxLen)) else { return buf }
            padded.frameLength = AVAudioFrameCount(maxLen)
            guard let srcL = buf.floatChannelData?[0],
                  let srcR = buf.floatChannelData?[1],
                  let dstL = padded.floatChannelData?[0],
                  let dstR = padded.floatChannelData?[1] else { return buf }
            // Copy existing samples
            for i in 0 ..< n { dstL[i] = srcL[i]; dstR[i] = srcR[i] }
            // Pad with silence (already zeroed by AVAudioPCMBuffer allocation, but be explicit)
            for i in n ..< maxLen { dstL[i] = 0; dstR[i] = 0 }
            return padded
        }
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
        guard isReady else { return }
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
        normalizePeak(L, R, samples: n)
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
        guard sfxEnabled, isReady, let engine, engine.isRunning else { return }
        guard !breakMaterialBuffers.isEmpty else { return }   // nothing built yet
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
        sfxBuffers[.hurt]          = makeHurtBuffer()
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

    /// hurt — sharp impact when player takes damage: descending sine sweep 440→200 Hz
    /// with a short noise transient, ~180 ms. Clearly distinct from mine.
    private func makeHurtBuffer() -> AVAudioPCMBuffer? {
        let dur: Float = 0.18
        var phase: Float = 0
        return synthesize(duration: dur) { i, sr in
            let t   = Float(i) / sr
            // Sharp attack, moderate release — punchy impact feel
            let env = self.envelope(t, a: 0.003, d: 0.05, s: 0.25, sLen: 0.04, r: 0.09, total: dur)
            // Pitch descends from 440 Hz to 200 Hz over the duration
            let hz  = 440.0 + (200.0 - 440.0) * (t / dur)
            phase  += hz / sr
            let tone = 0.60 * sin(2 * .pi * phase)
            // Short noise transient concentrated in the first 30 ms
            let noiseFade = max(0, 1.0 - t / 0.03)
            let noise = 0.40 * self.whitenoise() * noiseFade
            return env * (tone + noise)
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
        normalizePeak(L, R, samples: n)
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

    /// Peak-normalize a stereo buffer to targetPeak if the current peak exceeds it.
    /// Scans max(abs(sample)) over both channels; if > targetPeak, rescales uniformly.
    /// No DC offset is introduced because we multiply every sample by the same positive scalar.
    private func normalizePeak(_ L: UnsafeMutablePointer<Float>,
                               _ R: UnsafeMutablePointer<Float>,
                               samples: Int,
                               targetPeak: Float = 0.90) {
        guard samples > 0 else { return }
        var peak: Float = 0
        for i in 0 ..< samples {
            let al = abs(L[i]); let ar = abs(R[i])
            if al > peak { peak = al }
            if ar > peak { peak = ar }
        }
        guard peak > targetPeak else { return }
        let gain = targetPeak / peak
        for i in 0 ..< samples {
            L[i] *= gain
            R[i] *= gain
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
