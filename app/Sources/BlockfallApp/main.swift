// ============================================================================
// Blockfall — app shell (Phase 0 / M0)
// Opens a window with a Metal view, creates the engine over the frozen C ABI,
// runs the frame loop, clears a sky-colored frame, and overlays a HUD.
// This is the M0 exit-gate artifact: "stub .app launches, clears a colored
// frame, shows a HUD overlay." Renderer + gameplay grow behind the same ABI.
// ============================================================================
import AppKit
import MetalKit
import QuartzCore
import CBlockcore

// Keep C strings alive for the engine's lifetime (process-scoped).
func persistentCString(_ s: String) -> UnsafePointer<CChar> {
    return UnsafePointer(strdup(s))!
}

// #261: choose the pause layout from only the available width and the shared
// text scale. Keeping this pure makes the responsive breakpoints cheap to guard
// in the existing headless self-test.
private struct PauseLayoutPolicy: Equatable {
    let twoOptionColumns: Bool
    let stackedActions: Bool
}

private final class PauseDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private func pauseLayoutPolicy(width: CGFloat, scale: CGFloat) -> PauseLayoutPolicy {
    let s = min(2.0, max(1.0, scale))
    return PauseLayoutPolicy(
        twoOptionColumns: width >= 760 + 180 * (s - 1),
        stackedActions: width < 560 + 260 * (s - 1)
    )
}

private func pauseLayoutPolicySelfTest() -> Bool {
    let cases: [(CGFloat, CGFloat, PauseLayoutPolicy)] = [
        (1280, 1, PauseLayoutPolicy(twoOptionColumns: true,  stackedActions: false)),
        (1280, 2, PauseLayoutPolicy(twoOptionColumns: true,  stackedActions: false)),
        (700,  1, PauseLayoutPolicy(twoOptionColumns: false, stackedActions: false)),
        (700,  2, PauseLayoutPolicy(twoOptionColumns: false, stackedActions: true)),
        (560,  2, PauseLayoutPolicy(twoOptionColumns: false, stackedActions: true)),
    ]
    return cases.allSatisfy { pauseLayoutPolicy(width: $0.0, scale: $0.1) == $0.2 }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: Renderer?
    var hud: HUDView?
    let audio = GameAudio()
    let menu = MenuController()
    var guide: GuideController?
    var device: MTLDevice!
    weak var gameView: GameView?
    var gameContainer: NSView?
    var pauseOverlay: NSView?
    // #182 world map overlay (M key / pause-menu button). The world pauses
    // underneath (same setPaused path as the pause menu, #127).
    var mapOverlay: MapView?
    var tradeOverlay: TradeView?   // #203 trade panel (opened from dialogue)
    // #187 always-on corner minimap (toggle in the pause menu, hidden while the
    // big map is open).
    var minimapOverlay: MinimapView?
    // #135 loading overlay: covers the 1-2 fps first-load stutter (spawn chunks
    // meshing + uploading) and lifts once the renderer reports the world is ready.
    var loadingOverlay: LoadingView?
    private var loadStartTime: CFTimeInterval = 0
    private let kMinLoadingSecs: CFTimeInterval = 1.2   // avoid a flicker on fast loads
    let dialogue = DialogueController()   // #82 villager dialogue
    // #71 character editor state.
    var charEditorOverlay: NSView?
    private weak var charPreview: CharacterPreviewView?
    private var charRowLabels: [NSTextField] = []
    private var editorAppearance = CharacterAppearance()
    private let charTraits: [CharacterAppearance.Trait] = [.skin, .shirt, .headShape, .bodyShape, .hairColor, .hairStyle, .eyeStyle, .eyeColor, .nose, .mouth]
    private let charTraitNames = ["Skin", "Shirt", "Head Shape", "Body Shape", "Hair Colour", "Hair Style", "Eyes", "Eye Colour", "Nose", "Mouth"]
    // #: pause-menu HUD-option controls (held so the action handlers can update
    // the live value label). Rebuilt each time the pause overlay opens.
    private weak var hudScaleSlider: NSSlider?
    private weak var hudScaleValueLabel: NSTextField?
    // #136 graphics intensity sliders, held so a checkbox toggle can grey/enable its
    // companion slider live. Rebuilt each time the pause overlay opens.
    private weak var godRaySlider: NSSlider?
    private weak var celOutlineSlider: NSSlider?
    private weak var bloomSlider: NSSlider?   // #205 greyed when Bloom is toggled off
    private var uncappedDrawTimer: DispatchSourceTimer?
    private var pauseRebuildPending = false

    // ---- HUD option persistence (#: text size + visibility) ----
    // UserDefaults keys. Loaded at startup (startGame) and written on change.
    static let kHUDScaleKey = "hudScale"
    static let kHUDVisibleKey = "hudVisible"
    static let kVSyncKey = "gfxVSync"
    static func loadHUDScale() -> CGFloat {
        let d = UserDefaults.standard
        // Absent key -> default 1.0; clamp to the supported 1.0–2.0 range.
        guard d.object(forKey: kHUDScaleKey) != nil else { return 1.0 }
        return min(2.0, max(1.0, CGFloat(d.double(forKey: kHUDScaleKey))))
    }
    static func loadHUDVisible() -> Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: kHUDVisibleKey) != nil else { return true }  // default ON
        return d.bool(forKey: kHUDVisibleKey)
    }
    static func loadVSyncEnabled() -> Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: kVSyncKey) != nil else { return true }
        return d.bool(forKey: kVSyncKey)
    }

    private func stopUncappedDrawPump() {
        uncappedDrawTimer?.cancel()
        uncappedDrawTimer = nil
    }

    private func applyFrameSync(_ enabled: Bool, to target: GameView? = nil) {
        UserDefaults.standard.set(enabled, forKey: AppDelegate.kVSyncKey)
        guard let view = target ?? gameView else { return }
        let maxHz = max(60, window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        view.preferredFramesPerSecond = enabled ? maxHz : 1000
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = enabled
        if enabled {
            stopUncappedDrawPump()
            view.isPaused = false
        } else {
            view.isPaused = true
            guard uncappedDrawTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(0))
            timer.setEventHandler { [weak view] in view?.draw() }
            uncappedDrawTimer = timer
            timer.resume()
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard bf_abi_version() == BF_ABI_VERSION else {
            fatalError("ABI mismatch: app=\(BF_ABI_VERSION) engine=\(bf_abi_version())")
        }
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        // Below this there is not enough room for the title, four reachable
        // actions, and a useful slice of the scrollable options at 2x text.
        window.contentMinSize = NSSize(width: 560, height: 440)
        window.title = "Blockfall"
        window.center()
        window.acceptsMouseMovedEvents = true

        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("No Metal device (this build targets Apple Silicon).")
        }
        device = dev
        // #3: respect the persisted music/ambience toggles + volumes before starting.
        audio.setMusicEnabled(UserDefaults.standard.object(forKey: "audMusic") as? Bool ?? true)
        audio.setMusicVolume(Float(UserDefaults.standard.object(forKey: "audMusicVol") as? Double ?? 1.0))
        audio.setSoundVolume(Float(UserDefaults.standard.object(forKey: "audSoundVol") as? Double ?? 1.0))
        audio.start()
        guide = GuideController()   // on-device AI "Guide" companion (press 'G')
        audio.setAmbienceEnabled(UserDefaults.standard.object(forKey: "audAmbience") as? Bool ?? true)

        // Show the main menu first; start the game when a world is chosen.
        menu.onPlayWorld = { [weak self] saveDir, _, isNew, seed in
            self?.startGame(saveDir: saveDir, fresh: isNew, seed: seed)
        }
        menu.onQuit = { NSApp.terminate(nil) }
        // #207: rebuild the pause menu after a window resize so its layout can never
        // stay stuck stacked/overlapped (didEndLiveResize covers drag-resizes; the
        // plain didResize covers zoom/tile).
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResizedWhilePaused(_:)),
            name: NSWindow.didEndLiveResizeNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResizedWhilePaused(_:)),
            name: NSWindow.didResizeNotification, object: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // --playtest: boot straight into a fresh world (skips the menu) so the
        // live in-game HUD can be screenshot for verification.
        if CommandLine.arguments.contains("--playtest") {
            let dir = NSTemporaryDirectory() + "bf_playtest_\(Int.random(in: 0...99999))"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            startGame(saveDir: dir, fresh: true, seed: 24)
        } else {
            window.contentView = menu.rootView
        }
    }

    private func startGame(saveDir: String, fresh: Bool = false, seed: UInt64 = 0) {
        // Guard against a second start before the first finishes wiring up (e.g. a
        // fast double-click on "Start Adventure!") — that would spin up a second
        // engine and leak the first renderer mid-frame.
        guard renderer == nil else { return }
        let frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let mtkView = GameView(frame: frame, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.presentsWithTransaction = true   // so the AppKit HUD overlay composites on top
        applyFrameSync(AppDelegate.loadVSyncEnabled(), to: mtkView)

        let r = Renderer(view: mtkView, device: device, saveDir: saveDir, audio: audio,
                         fresh: fresh, seed: seed)
        mtkView.delegate = r
        mtkView.onHost = { [weak r] in r?.startHost() }
        mtkView.onJoin = { [weak r] in r?.joinLAN() }
        mtkView.onPause = { [weak self] in self?.pauseGame() }
        // #182 'M' opens the world map (the overlay handles its own close keys).
        mtkView.onOpenMap = { [weak self] in self?.openMap() }

        let h = HUDView(frame: frame)
        h.autoresizingMask = [.width, .height]
        h.onMove = { [weak mtkView] from, to, count in
            mtkView?.enqueueMove(from: from, to: to, count: count)
        }
        h.onCraft = { [weak mtkView] index in
            mtkView?.enqueueCraft(index)
        }
        h.onGiveItem = { [weak mtkView] itemId in
            mtkView?.enqueueGive(itemId)
        }
        h.onDestroy = { [weak mtkView] slot in
            mtkView?.enqueueDestroy(slot)
        }
        // #109 chest panel: take from a chest slot / deposit from an inventory slot.
        // Routed through the Renderer (direct ABI calls need the live engine handle).
        h.onChestTake = { [weak r] slot in r?.enqueueChestTake(slot) }
        h.onChestDeposit = { [weak r] slot in r?.enqueueChestDeposit(slot) }
        // ESC in GameView while the chest panel is open closes the engine's chest.
        mtkView.onChestClose = { [weak r] in r?.closeChest() }
        // #42: 'L' in GameView flips the quest-log overlay in the HUD.
        mtkView.onToggleQuestLog = { [weak h] in h?.toggleQuestLog() }
        // 'T' day/night pin: show a visible indicator so the player can confirm it.
        mtkView.onTimeModeChanged = { [weak h] m in h?.setTimeMode(m) }
        // #184: re-apply the persisted hyperspeed toggle to the fresh engine.
        if UserDefaults.standard.bool(forKey: "hyperspeed") { mtkView.setHyperspeed(true) }
        // #: apply the persisted HUD options (text size + visibility) so they
        // stick between sessions.
        h.hudScale = AppDelegate.loadHUDScale()
        h.hudVisible = AppDelegate.loadHUDVisible()
        r.hud = h

        let container = NSView(frame: frame)
        mtkView.autoresizingMask = [.width, .height]
        container.addSubview(mtkView)
        container.addSubview(h)

        // #187 minimap: pinned BOTTOM-right (top-right is the status box, top-left
        // the coords readout, bottom-centre the hotbar). Display-only. Default on.
        let mmSize: CGFloat = 176, mmMargin: CGFloat = 16
        let mm = MinimapView(frame: NSRect(x: frame.width - mmSize - mmMargin,
                                           y: mmMargin,
                                           width: mmSize, height: mmSize))
        mm.autoresizingMask = [.minXMargin, .maxYMargin]
        mm.renderer = r
        // #191: stay hidden until the loading overlay lifts (hideLoadingOverlay),
        // so the minimap does not appear over the load screen.
        mm.isHidden = true
        container.addSubview(mm)
        mm.start()
        minimapOverlay = mm

        // #135 loading screen: cover the first-load stutter from launch. The MTKView
        // keeps rendering (and meshing) underneath; this opaque overlay sits on top of
        // both the scene and the HUD until the renderer reports the world is ready, so
        // the player never sees the 1-2 fps spawn-area load. Input stays locked because
        // we do NOT grab the mouse until the overlay lifts (see onReady below).
        let loading = LoadingView(frame: container.bounds)
        loading.autoresizingMask = [.width, .height]
        container.addSubview(loading)
        loadingOverlay = loading
        loadStartTime = CACurrentMediaTime()
        NSLog("[Blockfall #135] showing loading overlay")
        // Drive the spinner/progress bar from the renderer's load fraction each frame.
        r.onLoadProgress = { [weak loading, weak r] in
            loading?.progress = r?.loadProgress ?? 0
        }

        window.contentView = container
        window.makeFirstResponder(mtkView)
        renderer = r
        hud = h
        // #135 hand control to the player once the spawn neighbourhood is meshed +
        // uploaded and the framerate has settled. Honour a small minimum display time
        // so a fast load does not flash the overlay, then fade it out and grab the mouse.
        r.onReady = { [weak self] in
            guard let self = self else { return }
            let elapsed = CACurrentMediaTime() - self.loadStartTime
            let wait = max(0, self.kMinLoadingSecs - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.hideLoadingOverlay()
            }
        }
        // #82 villager dialogue: load the trees and open the overlay when the engine reports
        // a right-click on a villager. Release the pointer so the player can click choices.
        dialogue.load()
        dialogue.onEnd = { [weak self] in self?.gameView?.requestDialogueEnd() }
        dialogue.onClose = { [weak self] in self?.gameView?.grabMouse() }
        // #203: villagers with an offer sheet grow a Trade button in dialogue.
        dialogue.hasTrade = { [weak r] npc in r?.tradeOffers(npcId: Int32(npc)) != nil }
        dialogue.onOpenTrade = { [weak self] npc in self?.openTrade(npcId: Int32(npc)) }
        // #227/#305: donate to the villager held by this dialogue.
        dialogue.onDonate = { [weak mtkView] _ in mtkView?.requestDonate() }
        dialogue.onQuest = { [weak r] quest in r?.sideQuestTalk(questId: UInt32(quest)) }
        r.onDialogue = { [weak self, weak r] npcId in
            // The guard-fail logs stay: a silently-refused open is exactly the
            // "interact froze me with no dialogue" report, and these only fire
            // on the anomaly (#239).
            guard let self = self else { NSLog("dlg: no app delegate"); return }
            guard let cv = self.window.contentView else { NSLog("dlg: no contentView"); return }
            guard !self.dialogue.isOpen else { NSLog("dlg: already open, ignored"); return }
            self.gameView?.releaseMouse()
            // #240: header carries the clicked villager's full nameplate.
            self.dialogue.show(npcId: npcId, in: cv, title: r?.lookName)
            if !self.dialogue.isOpen {
                NSLog("dlg: show refused (npc trees loaded?)")
                self.gameView?.requestDialogueEnd()
            }
        }
        // #239: walking ~5 blocks away ends the chat naturally.
        r.onPlayerPos = { [weak self] x, z in self?.dialogue.playerMoved(x: x, z: z) }
        gameView = mtkView
        gameContainer = container
    }

    // #135 fade out and remove the loading overlay, then hand the player control
    // (grab the mouse for camera look). Idempotent — safe if called after teardown.
    private func hideLoadingOverlay() {
        guard let ov = loadingOverlay else { return }
        loadingOverlay = nil
        renderer?.onLoadProgress = nil
        let elapsed = CACurrentMediaTime() - loadStartTime
        NSLog("[Blockfall #135] hiding loading overlay after %.2fs", elapsed)
        // #191: reveal the minimap now that the world is up (if the toggle is on),
        // so it comes in with the rest of the HUD, not over the load screen.
        if UserDefaults.standard.object(forKey: "minimap") as? Bool ?? true {
            minimapOverlay?.isHidden = false
        }
        // Only capture the mouse if we are still in-game and not paused (the player
        // could have hit Esc during load). The fade is a short, kid-friendly reveal.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ov.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak ov] in
            ov?.removeFromSuperview()
            guard let self = self else { return }
            // Hand control to the player. Match the existing "click to look around"
            // model: just make the game view first responder and leave the mouse
            // uncaptured until the player clicks in (same as a normal world start).
            if self.pauseOverlay == nil, let gv = self.gameView {
                self.window.makeFirstResponder(gv)
            }
        })
    }

    // ---- pause menu (Esc) ----
    // #207/#261: coalesce resize-end notifications and rebuild on the next run-loop
    // turn. The same path is used after Text Size tracking, so a control is never
    // removed while AppKit is still dispatching its action.
    @objc private func windowResizedWhilePaused(_ n: Notification) {
        guard pauseOverlay != nil else { return }
        if let w = n.object as? NSWindow, w.inLiveResize { return }
        rebuildPauseOverlayDeferred()
    }

    private func rebuildPauseOverlayDeferred() {
        guard pauseOverlay != nil, !pauseRebuildPending else { return }
        pauseRebuildPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pauseRebuildPending = false
            guard self.pauseOverlay != nil else { return }
            self.pauseOverlay?.removeFromSuperview()
            self.pauseOverlay = nil
            self.buildPauseOverlay()
        }
    }

    @objc private func pauseGame() {
        // ESC toggles: if the pause overlay is already up, ESC resumes (keep playing)
        // instead of being a no-op. Lets the player open the pause menu, click a graphics
        // checkbox, and ESC straight back to the game without reaching for the mouse.
        if pauseOverlay != nil { resumeGame(); return }
        buildPauseOverlay()
    }

    // #206/#261: pause and HUD text share one multiplier. Pause-menu body bases
    // stay in the HUD's 14-20pt range; only semantic headings are larger.
    private var menuScale: CGFloat { CGFloat(hud?.hudScale ?? AppDelegate.loadHUDScale()) }
    private func mfs(_ base: CGFloat) -> CGFloat { (base * menuScale).rounded() }

    private func buildPauseOverlay() {
        guard let container = gameContainer else { return }
        gameView?.setPaused(true)
        let ov = NSView(frame: container.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.wantsLayer = true
        ov.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        let policy = pauseLayoutPolicy(width: container.bounds.width, scale: menuScale)

        let title = NSTextField(labelWithString: "Paused")
        title.font = .boldSystemFont(ofSize: mfs(28)); title.textColor = .white
        title.alignment = .center; title.translatesAutoresizingMaskIntoConstraints = false

        let resume = pauseButton("Keep Playing", #selector(resumeGame))
        let menuBtn = pauseButton("Save & Go to Menu", #selector(quitToMenu))

        // ---- HUD options (#: text size + visibility) ----
        // Text Size: a slider 1.0–2.0 with a live label. Show HUD: a checkbox.
        // Both write through to the live HUDView immediately and persist to
        // UserDefaults so they stick between sessions.
        let textLabel = NSTextField(labelWithString: "Text Size")
        textLabel.font = .boldSystemFont(ofSize: mfs(16)); textLabel.textColor = .white

        let slider = NSSlider(value: Double(hud?.hudScale ?? AppDelegate.loadHUDScale()),
                              minValue: 1.0, maxValue: 2.0,
                              target: self, action: #selector(hudScaleChanged(_:)))
        slider.isContinuous = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        hudScaleSlider = slider

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .systemFont(ofSize: mfs(14)); valueLabel.textColor = .white
        valueLabel.alignment = .center
        hudScaleValueLabel = valueLabel

        let sliderRow = NSStackView(views: [textLabel, slider, valueLabel])
        sliderRow.orientation = .horizontal; sliderRow.spacing = 12; sliderRow.alignment = .centerY

        let showHUD = NSButton(checkboxWithTitle: "Show HUD",
                               target: self, action: #selector(hudVisibleChanged(_:)))
        showHUD.state = (hud?.hudVisible ?? AppDelegate.loadHUDVisible()) ? .on : .off
        showHUD.contentTintColor = .white
        showHUD.attributedTitle = NSAttributedString(string: "Show HUD", attributes: [
            .font: NSFont.boldSystemFont(ofSize: mfs(16)), .foregroundColor: NSColor.white,
        ])

        updateHUDScaleLabel()   // fill the live value label now that it exists

        // ---- Graphics effect toggles (#: click each effect on/off, live + persisted) ----
        // #136 effects with a meaningful strength (God Rays, Cel Shading) carry an intensity
        // slider beside the checkbox; Bloom (always on) gets its own labelled slider row. The
        // slider greys out when the effect is toggled off. Lens Flare stays a plain toggle.
        let fxTitle = NSTextField(labelWithString: "Effects")
        fxTitle.font = .boldSystemFont(ofSize: mfs(18)); fxTitle.textColor = .white

        // God Rays + Cel Shading: checkbox with an intensity slider beside it.
        let godRayCb = gfxCheckbox("God Rays", tag: 2, on: renderer?.gfxGodRays ?? false)
        let grSlider = gfxIntensitySlider(value: Double(renderer?.gfxGodRayStr ?? 0.5),
                                          sel: #selector(godRayStrChanged(_:)),
                                          enabled: renderer?.gfxGodRays ?? false)
        godRaySlider = grSlider

        let celCb = gfxCheckbox("Cel Shading", tag: 5, on: renderer?.gfxCelShade ?? true)
        let celSlider = gfxIntensitySlider(value: Double(renderer?.gfxCelOutlineStr ?? 1.0),
                                           sel: #selector(celOutlineStrChanged(_:)),
                                           enabled: renderer?.gfxCelShade ?? true)
        celOutlineSlider = celSlider

        // #205: Bloom now has a checkbox like the other effects (was label-only).
        let bloomCb = gfxCheckbox("Bloom", tag: 11, on: renderer?.gfxBloom ?? true)
        let bloomSl = gfxIntensitySlider(value: Double(renderer?.gfxBloomStr ?? 0.5),
                                         sel: #selector(bloomStrChanged(_:)),
                                         enabled: renderer?.gfxBloom ?? true)
        bloomSlider = bloomSl
        let bloomRow = gfxRow(bloomCb, bloomSl)

        let fxStack = NSStackView(views: [
            gfxCheckbox("Waving Foliage",    tag: 0, on: renderer?.gfxFoliage ?? false),
            gfxCheckbox("Water Reflections", tag: 1, on: renderer?.gfxWater   ?? true),
            gfxRow(godRayCb, grSlider),
            gfxCheckbox("Pollen Motes",      tag: 3, on: renderer?.gfxPollen  ?? true),
            gfxCheckbox("Soft Shadows",      tag: 4, on: renderer?.gfxShadows ?? false),
            gfxRow(celCb, celSlider),
            bloomRow,
            gfxCheckbox("Lens Flare",        tag: 6, on: renderer?.gfxLensFlare ?? true),
            // #116 character (entity) shadows: receive world shade + cast a ground contact blob.
            gfxCheckbox("Character Shadows", tag: 7, on: renderer?.gfxCharShadows ?? true),
            // #47 volumetric clouds toggle.
            gfxCheckbox("Volumetric Clouds", tag: 8, on: renderer?.gfxClouds ?? true),
            // #184: creative-only 100x flight for circumnavigating the planet (and
            // stress-testing streaming). Engine ignores it in survival.
            gfxCheckbox("Hyperspeed Flight (100x)", tag: 9,
                        on: UserDefaults.standard.bool(forKey: "hyperspeed")),
            // #187 corner minimap toggle (default on).
            gfxCheckbox("Minimap", tag: 10,
                        on: UserDefaults.standard.object(forKey: "minimap") as? Bool ?? true),
            gfxCheckbox("VSync", tag: 12, on: AppDelegate.loadVSyncEnabled()),
        ])
        fxStack.orientation = .vertical; fxStack.spacing = 8; fxStack.alignment = .leading

        // #85 Render-distance slider (chunks 8..28), live + persisted.
        let rdLabel = NSTextField(labelWithString: "Render Distance")
        rdLabel.font = .systemFont(ofSize: mfs(14)); rdLabel.textColor = .white
        let rdVal = UserDefaults.standard.object(forKey: "gfxRenderDist") as? Int ?? 24
        let rdSlider = NSSlider(value: Double(rdVal), minValue: 8, maxValue: 40,
                                target: self, action: #selector(renderDistChanged(_:)))
        rdSlider.translatesAutoresizingMaskIntoConstraints = false
        rdSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let rdRow = NSStackView(views: [rdLabel, rdSlider])
        rdRow.orientation = .horizontal; rdRow.spacing = 10; rdRow.alignment = .centerY

        // #238 Difficulty: Easy = no bad guys at all, Normal = the usual night
        // monsters, Hard = lots more of them. Per-world, live + persisted.
        let diffLabel = NSTextField(labelWithString: "Difficulty")
        diffLabel.font = .systemFont(ofSize: mfs(14)); diffLabel.textColor = .white
        let diffSeg = NSSegmentedControl(labels: ["Easy", "Normal", "Hard"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(difficultyChanged(_:)))
        diffSeg.selectedSegment = Int(renderer?.difficulty ?? 1)
        let diffRow = NSStackView(views: [diffLabel, diffSeg])
        diffRow.orientation = .horizontal; diffRow.spacing = 10; diffRow.alignment = .centerY

        // ---- Audio toggles (#3: music + ambience on/off, live + persisted) ----
        let auTitle = NSTextField(labelWithString: "Audio")
        auTitle.font = .boldSystemFont(ofSize: mfs(18)); auTitle.textColor = .white
        let auStack = NSStackView(views: [
            volumeSliderRow("Music Volume", key: "audMusicVol", sel: #selector(musicVolChanged(_:))),
            volumeSliderRow("Sound Volume", key: "audSoundVol", sel: #selector(soundVolChanged(_:))),
            audioCheckbox("Music",    tag: 0, on: UserDefaults.standard.object(forKey: "audMusic")    as? Bool ?? true),
            audioCheckbox("Ambience", tag: 1, on: UserDefaults.standard.object(forKey: "audAmbience") as? Bool ?? true),
        ])
        auStack.orientation = .vertical; auStack.spacing = 8; auStack.alignment = .leading

        let charBtn = pauseButton("Customize Character", #selector(openCharacterEditor))
        // #182 world map: same journey as pressing M, reachable from the pause menu.
        let mapBtn = pauseButton("World Map", #selector(openMapFromPause))
        // #205: three fixed regions so the primary actions can NEVER be clipped
        // off-screen at any window height: a pinned title at the top, the options
        // in a SCROLL VIEW in the middle (scroll when they overflow), and a pinned
        // action bar (Keep Playing / Save & Go to Menu) at the bottom.
        // Wide windows use two columns. Compact windows put Text Size first in
        // one vertical column, so it remains the first reachable scroll item.
        let leftCol = NSStackView(views: [fxTitle, fxStack])
        leftCol.orientation = .vertical; leftCol.spacing = 14; leftCol.alignment = .leading
        let rightCol = NSStackView(views: [sliderRow, showHUD, rdRow, diffRow, auTitle, auStack])
        rightCol.orientation = .vertical; rightCol.spacing = 16; rightCol.alignment = .leading
        let optionsStack = NSStackView(views: policy.twoOptionColumns ? [leftCol, rightCol] : [rightCol, leftCol])
        optionsStack.orientation = policy.twoOptionColumns ? .horizontal : .vertical
        optionsStack.spacing = policy.twoOptionColumns ? 36 : 20
        optionsStack.alignment = policy.twoOptionColumns ? .top : .leading
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // A flipped document view makes scroll position zero mean "top". The
        // default AppKit view is bottom-origin, which could reopen the rebuilt
        // 2.0x menu scrolled past Text Size and its headings (#267).
        let doc = PauseDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(optionsStack)
        scroll.documentView = doc

        // Four pinned actions: a 2x2 grid when labels fit, one stack on narrow
        // windows at large text. The button chrome stays fixed; only text scales.
        let actionBar: NSStackView
        if policy.stackedActions {
            let buttons = [mapBtn, charBtn, resume, menuBtn]
            actionBar = NSStackView(views: buttons)
            actionBar.orientation = .vertical
            actionBar.spacing = 8
            actionBar.alignment = .leading
            for button in buttons {
                button.widthAnchor.constraint(equalTo: actionBar.widthAnchor).isActive = true
            }
        } else {
            let topActions = NSStackView(views: [mapBtn, charBtn])
            topActions.orientation = .horizontal; topActions.spacing = 12; topActions.distribution = .fillEqually
            let bottomActions = NSStackView(views: [resume, menuBtn])
            bottomActions.orientation = .horizontal; bottomActions.spacing = 12; bottomActions.distribution = .fillEqually
            actionBar = NSStackView(views: [topActions, bottomActions])
            actionBar.orientation = .vertical; actionBar.spacing = 8; actionBar.alignment = .centerX
            topActions.widthAnchor.constraint(equalTo: actionBar.widthAnchor).isActive = true
            bottomActions.widthAnchor.constraint(equalTo: actionBar.widthAnchor).isActive = true
        }
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        // Keep the menu itself centred. The dim backdrop still fills the game,
        // but the title/options/actions live in one bounded panel instead of
        // stretching from the top edge to a bottom-anchored action bar (#267).
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.88).cgColor
        panel.layer?.cornerRadius = 18
        panel.addSubview(title)
        panel.addSubview(scroll)
        panel.addSubview(actionBar)
        ov.addSubview(panel)

        // Preferred widths yield to hard edge bounds on compact windows.
        let scrollW = scroll.widthAnchor.constraint(equalToConstant: policy.twoOptionColumns ? 900 : 520)
        scrollW.priority = .defaultHigh; scrollW.isActive = true
        let actionW = actionBar.widthAnchor.constraint(equalToConstant: policy.stackedActions ? 460 : 820)
        actionW.priority = .defaultHigh; actionW.isActive = true
        let panelH = max(1, min(container.bounds.height - 32, 760))
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: ov.centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: ov.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: ov.trailingAnchor, constant: -16),
            panel.heightAnchor.constraint(equalToConstant: panelH),

            title.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),

            actionBar.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            actionBar.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor, constant: 16),
            actionBar.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),
            actionBar.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),

            scroll.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            scroll.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -12),

            // Vertical-only scroll; options get a left/right margin so the
            // checkboxes on the left column are never clipped at the edge.
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            optionsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            optionsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            optionsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 16),
            optionsStack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -16),
        ])
        container.addSubview(ov)
        pauseOverlay = ov
        ov.layoutSubtreeIfNeeded()
    }
    private func pauseButton(_ t: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: t, target: self, action: sel)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.42, alpha: 1).cgColor
        b.layer?.cornerRadius = 12
        b.contentTintColor = .white
        b.attributedTitle = NSAttributedString(string: t, attributes: [
            .font: NSFont.boldSystemFont(ofSize: mfs(18)),
            .foregroundColor: NSColor.white,
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return b
    }
    // ---- world map (#182) ----
    // Opens the full-screen map overlay: pauses the world (creatures + sun
    // freeze, #127-consistent), releases the pointer, and feeds the MapView a
    // one-shot snapshot (explored mask + markers) from the engine. Confirming
    // a marker runs the MapView's charge-up, then teleports and closes.
    @objc private func openMapFromPause() {
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
        openMap()
    }

    private func openMap() {
        guard mapOverlay == nil, pauseOverlay == nil, loadingOverlay == nil,
              charEditorOverlay == nil, !dialogue.isOpen,
              let container = gameContainer, let r = renderer,
              let snap = r.mapQuery() else { return }
        gameView?.setPaused(true)   // freezes the sim + releases the pointer
        minimapOverlay?.isHidden = true   // #187 the big map supersedes the minimap
        let mv = MapView(frame: container.bounds)
        mv.autoresizingMask = [.width, .height]
        mv.explored = snap.explored
        mv.period = snap.period
        mv.cellSize = snap.cellSize
        mv.cells = snap.cells
        mv.markers = snap.markers
        mv.biomes = r.mapBiomes(cells: snap.cells) ?? []   // #224 biome tint layer
        mv.playerX = snap.playerX
        mv.playerZ = snap.playerZ
        mv.playerFacing = snap.facing
        mv.onClose = { [weak self] in self?.closeMap() }
        mv.onChargeStart = { [weak self] in self?.audio.play(.craft) }
        mv.onTeleport = { [weak self] id in
            self?.renderer?.mapTeleport(id)   // engine fires the arrival fx
            self?.closeMap()
        }
        container.addSubview(mv)
        mv.rebuild()
        mapOverlay = mv
        window.makeFirstResponder(mv)
    }

    // #203: trade panel over the game, pointer released like dialogue/chest.
    private func openTrade(npcId: Int32) {
        guard tradeOverlay == nil, let container = gameContainer else { return }
        gameView?.releaseMouse()
        let tv = TradeView(frame: container.bounds, npcId: npcId, renderer: renderer)
        tv.onClose = { [weak self] in
            self?.tradeOverlay?.removeFromSuperview()
            self?.tradeOverlay = nil
            self?.gameView?.grabMouse()
            if let gv = self?.gameView { self?.window.makeFirstResponder(gv) }
        }
        tv.onTraded = { [weak self] in self?.audio.play(.craft) }
        container.addSubview(tv)
        tradeOverlay = tv
        window.makeFirstResponder(tv)
    }

    private func closeMap() {
        guard let mv = mapOverlay else { return }
        mv.removeFromSuperview()
        mapOverlay = nil
        if UserDefaults.standard.object(forKey: "minimap") as? Bool ?? true {
            minimapOverlay?.isHidden = false   // #187 restore if enabled
        }
        gameView?.setPaused(false)
        gameView?.grabMouse()
        if let gv = gameView { window.makeFirstResponder(gv) }
    }

    @objc private func resumeGame() {
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
        gameView?.setPaused(false)
        gameView?.grabMouse()
        if let gv = gameView { window.makeFirstResponder(gv) }
    }

    // #71 character editor: a focused overlay with a live portrait preview and a row of
    // +/- pickers for each trait. Changes save and apply to the player immediately.
    @objc private func openCharacterEditor() {
        guard let parent = window.contentView else { return }
        editorAppearance = CharacterAppearance.load()

        let ov = NSView(frame: parent.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.wantsLayer = true
        ov.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.82).cgColor

        let title = NSTextField(labelWithString: "Customize Character")
        title.font = .boldSystemFont(ofSize: 24); title.textColor = .white

        let preview = CharacterPreviewView(frame: .zero)
        preview.character = editorAppearance
        preview.wantsLayer = true; preview.layer?.cornerRadius = 12
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 180).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 180).isActive = true
        charPreview = preview

        charRowLabels = []
        var rows: [NSView] = [title, preview]
        for (i, name) in charTraitNames.enumerated() { rows.append(charTraitRow(i, name)) }
        // Randomize previews a look; Save commits it; Cancel backs out without changing
        // your real appearance.
        let actions = NSStackView(views: [
            charActionButton("Randomize", #selector(randomizeChar)),
            charActionButton("Save",      #selector(saveChar)),
            charActionButton("Cancel",    #selector(closeCharacterEditor)),
        ])
        actions.orientation = .horizontal; actions.spacing = 10; actions.alignment = .centerY
        rows.append(actions)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.spacing = 12; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: ov.centerYAnchor),
        ])
        parent.addSubview(ov)
        charEditorOverlay = ov
        refreshCharRows()
    }

    private func charTraitRow(_ idx: Int, _ name: String) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .boldSystemFont(ofSize: 15); label.textColor = .white
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true

        func arrow(_ glyph: String, _ tag: Int) -> NSButton {
            let b = NSButton(title: glyph, target: self, action: #selector(charCycle(_:)))
            b.tag = tag; b.bezelStyle = .regularSquare; b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.42, alpha: 1).cgColor
            b.layer?.cornerRadius = 8
            b.attributedTitle = NSAttributedString(string: glyph, attributes: [
                .font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white])
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            return b
        }
        let value = NSTextField(labelWithString: "")
        value.font = .systemFont(ofSize: 15); value.textColor = .white; value.alignment = .center
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 120).isActive = true
        charRowLabels.append(value)

        let row = NSStackView(views: [label, arrow("\u{25C0}", idx * 2), value, arrow("\u{25B6}", idx * 2 + 1)])
        row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        return row
    }

    // A compact green action button for the editor (Randomize / Save / Cancel).
    private func charActionButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .regularSquare; b.isBordered = false; b.wantsLayer = true
        b.layer?.backgroundColor = NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.42, alpha: 1).cgColor
        b.layer?.cornerRadius = 10
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 150).isActive = true
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }
    // Cycle a trait in the PREVIEW only; nothing is committed until Save.
    @objc private func charCycle(_ sender: NSButton) {
        let idx = sender.tag / 2, dir = (sender.tag % 2 == 0) ? -1 : 1
        guard idx >= 0 && idx < charTraits.count else { return }
        editorAppearance.cycle(charTraits[idx], by: dir)
        refreshCharRows()
        charPreview?.character = editorAppearance
    }
    @objc private func randomizeChar() {
        editorAppearance = CharacterAppearance.randomized()
        refreshCharRows()
        charPreview?.character = editorAppearance
    }
    @objc private func saveChar() {
        editorAppearance.save()
        renderer?.setCharacterAppearance(editorAppearance)
        charEditorOverlay?.removeFromSuperview(); charEditorOverlay = nil
    }

    private func refreshCharRows() {
        for (i, t) in charTraits.enumerated() where i < charRowLabels.count {
            charRowLabels[i].stringValue = editorAppearance.valueName(t)
        }
    }

    // Cancel: close without committing. The real appearance only changes on Save.
    @objc private func closeCharacterEditor() {
        charEditorOverlay?.removeFromSuperview(); charEditorOverlay = nil
    }

    // #: HUD Text Size slider → live HUD + persisted.
    @objc private func hudScaleChanged(_ sender: NSSlider) {
        let v = min(2.0, max(1.0, CGFloat(sender.doubleValue)))
        hud?.hudScale = v
        UserDefaults.standard.set(Double(v), forKey: AppDelegate.kHUDScaleKey)
        updateHUDScaleLabel()
        // The slider is non-continuous; defer one coalesced rebuild until after
        // AppKit has finished tracking and dispatching this control action.
        rebuildPauseOverlayDeferred()
    }
    // #: Show HUD checkbox → live HUD + persisted.
    @objc private func hudVisibleChanged(_ sender: NSButton) {
        let on = (sender.state == .on)
        hud?.hudVisible = on
        UserDefaults.standard.set(on, forKey: AppDelegate.kHUDVisibleKey)
    }
    private func updateHUDScaleLabel() {
        let v = hud?.hudScale ?? AppDelegate.loadHUDScale()
        hudScaleValueLabel?.stringValue = String(format: "%.1f×", Double(v))
    }

    // #: a labeled 0..1 volume slider row (independent music vs sounds).
    private func volumeSliderRow(_ title: String, key: String, sel: Selector) -> NSStackView {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: mfs(14)); lbl.textColor = .white
        let v = UserDefaults.standard.object(forKey: key) as? Double ?? 1.0
        let s = NSSlider(value: v, minValue: 0.0, maxValue: 1.0, target: self, action: sel)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let row = NSStackView(views: [lbl, s])
        row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
        return row
    }
    @objc private func renderDistChanged(_ s: NSSlider) {   // #85
        let v = Int(s.doubleValue.rounded())
        UserDefaults.standard.set(v, forKey: "gfxRenderDist")
        renderer?.setRenderDistance(v)
    }
    @objc private func difficultyChanged(_ s: NSSegmentedControl) {   // #238
        renderer?.setDifficulty(Int32(max(0, s.selectedSegment)))
    }
    @objc private func musicVolChanged(_ s: NSSlider) {
        UserDefaults.standard.set(s.doubleValue, forKey: "audMusicVol"); audio.setMusicVolume(Float(s.doubleValue))
    }
    @objc private func soundVolChanged(_ s: NSSlider) {
        UserDefaults.standard.set(s.doubleValue, forKey: "audSoundVol"); audio.setSoundVolume(Float(s.doubleValue))
    }

    // #3: a styled audio checkbox; tag 0 = Music, 1 = Ambience.
    private func audioCheckbox(_ title: String, tag: Int, on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(audioToggleChanged(_:)))
        b.tag = tag
        b.state = on ? .on : .off
        b.contentTintColor = .white
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: mfs(14)), .foregroundColor: NSColor.white,
        ])
        return b
    }
    @objc private func audioToggleChanged(_ sender: NSButton) {
        let on = (sender.state == .on)
        switch sender.tag {
        case 0: UserDefaults.standard.set(on, forKey: "audMusic");    audio.setMusicEnabled(on)
        case 1: UserDefaults.standard.set(on, forKey: "audAmbience"); audio.setAmbienceEnabled(on)
        default: break
        }
    }

    // #: a styled graphics-effect checkbox; tag selects which effect.
    private func gfxCheckbox(_ title: String, tag: Int, on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(gfxToggleChanged(_:)))
        b.tag = tag
        b.state = on ? .on : .off
        b.contentTintColor = .white
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: mfs(14)), .foregroundColor: NSColor.white,
        ])
        return b
    }
    // #: graphics toggle → live renderer + persisted. Tags match gfxCheckbox order.
    @objc private func gfxToggleChanged(_ sender: NSButton) {
        let on = (sender.state == .on)
        let keys = ["gfxFoliage", "gfxWater", "gfxGodRays", "gfxPollen", "gfxShadows", "gfxCelShade", "gfxLensFlare", "gfxCharShadows", "gfxClouds", "hyperspeed", "minimap", "gfxBloom", AppDelegate.kVSyncKey]
        guard sender.tag >= 0 && sender.tag < keys.count else { return }
        UserDefaults.standard.set(on, forKey: keys[sender.tag])
        switch sender.tag {
        case 0: renderer?.gfxFoliage = on
        case 1: renderer?.gfxWater   = on
        case 2: renderer?.gfxGodRays = on; godRaySlider?.isEnabled = on        // #136 grey the slider when off
        case 3: renderer?.gfxPollen  = on
        case 4: renderer?.gfxShadows = on
        case 5: renderer?.gfxCelShade = on; celOutlineSlider?.isEnabled = on   // #136 grey the slider when off
        case 6: renderer?.gfxLensFlare = on   // #132 lens-flare toggle
        case 7: renderer?.gfxCharShadows = on // #116 character (entity) shadows
        case 8: renderer?.gfxClouds = on      // #47 volumetric clouds toggle
        case 9: gameView?.setHyperspeed(on)   // #184 creative 100x flight
        case 10: minimapOverlay?.isHidden = !on   // #187 corner minimap
        case 11: renderer?.gfxBloom = on; bloomSlider?.isEnabled = on   // #205 bloom toggle
        case 12: applyFrameSync(on)
        default: break
        }
    }

    // #136 a compact intensity slider (0..1) styled to sit beside a gfxCheckbox. Greyed
    // (disabled) when its effect is toggled off.
    private func gfxIntensitySlider(value: Double, sel: Selector, enabled: Bool) -> NSSlider {
        let s = NSSlider(value: value, minValue: 0.0, maxValue: 1.0, target: self, action: sel)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.widthAnchor.constraint(equalToConstant: 120).isActive = true
        s.isEnabled = enabled
        return s
    }
    // #136 a horizontal row pairing an effect checkbox with its intensity slider.
    private func gfxRow(_ checkbox: NSButton, _ slider: NSSlider) -> NSStackView {
        let row = NSStackView(views: [checkbox, slider])
        row.orientation = .horizontal; row.spacing = 12; row.alignment = .centerY
        return row
    }
    // #136 intensity sliders → live renderer + persisted (matching their toggle's key style).
    @objc private func godRayStrChanged(_ s: NSSlider) {
        UserDefaults.standard.set(s.doubleValue, forKey: "gfxGodRayStr")
        renderer?.gfxGodRayStr = Float(s.doubleValue)
    }
    @objc private func celOutlineStrChanged(_ s: NSSlider) {
        UserDefaults.standard.set(s.doubleValue, forKey: "gfxCelOutlineStr")
        renderer?.gfxCelOutlineStr = Float(s.doubleValue)
    }
    @objc private func bloomStrChanged(_ s: NSSlider) {
        UserDefaults.standard.set(s.doubleValue, forKey: "gfxBloomStr")
        renderer?.gfxBloomStr = Float(s.doubleValue)
    }
    @objc private func quitToMenu() {
        stopUncappedDrawPump()
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
        mapOverlay?.removeFromSuperview(); mapOverlay = nil   // #182
        tradeOverlay?.removeFromSuperview(); tradeOverlay = nil   // #203
        minimapOverlay?.stop(); minimapOverlay?.removeFromSuperview(); minimapOverlay = nil  // #187
        // #135 drop the loading overlay if we quit mid-load (rare, but the
        // pending fade/grab callbacks must not run against a torn-down game).
        loadingOverlay?.removeFromSuperview(); loadingOverlay = nil
        renderer?.shutdown(); renderer = nil    // saves the world
        gameView = nil; gameContainer = nil; hud = nil
        menu.refresh()
        window.contentView = menu.rootView
    }

    // Losing focus (Cmd-Tab/Cmd-H) means keyUp/mouseUp won't arrive — clear held
    // input and release the mouse so the player doesn't return to a stuck-walking
    // character or a hidden cursor.
    func applicationWillResignActive(_: Notification) {
        gameView?.clearInput()
        if gameView?.isCaptured == true { gameView?.releaseMouse() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        stopUncappedDrawPump()
        renderer?.shutdown()
        audio.stop()
    }
}

// ============================================================================
// #135 LoadingView — the first-load cover screen.
// A self-contained, lazy AppKit view: a subtly animated sky-gradient background,
// the game name, a bouncing-dot spinner, and a thin progress bar driven by the
// renderer's load fraction. No engine data, no Metal — just a CALayer animation
// that runs on the main thread while the scene meshes underneath. Kid-friendly:
// big friendly title, soft colours, gentle motion. Opaque so it hides the scene
// and the HUD; being on top also swallows clicks so the player cannot capture
// the mouse / move the camera until the overlay lifts.
// ============================================================================
final class LoadingView: NSView {
    private let bar = CALayer()
    private let barTrack = CALayer()
    private var dots: [CALayer] = []
    // 0..1 from the renderer; the bar eases toward this each set.
    var progress: Float = 0 {
        didSet { updateBar() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.86, alpha: 1).cgColor
        buildBackground()
        buildTitle()
        buildSpinner()
        buildProgressBar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // A soft top-to-bottom sky gradient with a slow breathing animation so the
    // screen never looks frozen even if a load frame is slow to arrive.
    private func buildBackground() {
        let grad = CAGradientLayer()
        grad.frame = bounds
        grad.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grad.colors = [
            NSColor(calibratedRed: 0.42, green: 0.70, blue: 0.93, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.74, green: 0.88, blue: 0.98, alpha: 1).cgColor,
        ]
        grad.startPoint = CGPoint(x: 0.5, y: 1.0)
        grad.endPoint = CGPoint(x: 0.5, y: 0.0)
        let pulse = CABasicAnimation(keyPath: "colors")
        pulse.toValue = [
            NSColor(calibratedRed: 0.38, green: 0.66, blue: 0.90, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.66, green: 0.84, blue: 0.97, alpha: 1).cgColor,
        ]
        pulse.duration = 2.4
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        grad.add(pulse, forKey: "breathe")
        layer?.addSublayer(grad)
    }

    private func buildTitle() {
        let title = NSTextField(labelWithString: "Blockfall")
        title.font = .systemFont(ofSize: 56, weight: .heavy)
        title.textColor = .white
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        let sub = NSTextField(labelWithString: "Building your world\u{2026}")
        sub.font = .systemFont(ofSize: 20, weight: .medium)
        sub.textColor = NSColor.white.withAlphaComponent(0.92)
        sub.alignment = .center
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            sub.centerXAnchor.constraint(equalTo: centerXAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
        ])
    }

    // A simple, friendly three-dot bouncing spinner centred under the subtitle.
    private func buildSpinner() {
        let spinner = NSView(frame: .zero)
        spinner.wantsLayer = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 84),
            spinner.widthAnchor.constraint(equalToConstant: 96),
            spinner.heightAnchor.constraint(equalToConstant: 24),
        ])
        let r: CGFloat = 9, gap: CGFloat = 33
        for i in 0..<3 {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.cgColor
            dot.frame = CGRect(x: CGFloat(i) * gap, y: 8, width: r, height: r)
            dot.cornerRadius = r / 2
            spinner.layer?.addSublayer(dot)
            let bounce = CABasicAnimation(keyPath: "transform.translation.y")
            bounce.fromValue = 0
            bounce.toValue = 10
            bounce.duration = 0.45
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.beginTime = CACurrentMediaTime() + Double(i) * 0.15
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(bounce, forKey: "bounce")
            dots.append(dot)
        }
    }

    // A thin rounded progress bar near the bottom; width tracks `progress`.
    private func buildProgressBar() {
        let w: CGFloat = 320, h: CGFloat = 10
        barTrack.backgroundColor = NSColor.white.withAlphaComponent(0.30).cgColor
        barTrack.cornerRadius = h / 2
        bar.backgroundColor = NSColor.white.cgColor
        bar.cornerRadius = h / 2
        layer?.addSublayer(barTrack)
        barTrack.addSublayer(bar)
        layoutBar(w: w, h: h)
    }

    private func layoutBar(w: CGFloat, h: CGFloat) {
        let x = (bounds.width - w) / 2
        let y = bounds.height * 0.22
        barTrack.frame = CGRect(x: x, y: y, width: w, height: h)
        updateBar()
    }

    private func updateBar() {
        let frac = CGFloat(max(0, min(1, progress)))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        bar.frame = CGRect(x: 0, y: 0, width: barTrack.bounds.width * frac, height: barTrack.bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutBar(w: 320, h: 10)
    }

    // Swallow input so clicks never reach the game view while loading.
    override func mouseDown(with event: NSEvent) {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Stay opaque to the window's hit-testing so the MTKView underneath
        // cannot capture the pointer until we are removed.
        return self
    }
}

// Headless self-check mode for CI: --selftest creates the engine, runs a few
// frames without a window, and exits 0. Lets ci/check.sh exercise the Swift<->
// C++ boundary on a machine with no display.
if CommandLine.arguments.contains("--selftest") {
    guard pauseLayoutPolicySelfTest() else {
        print("SELFTEST FAIL: pause layout policy")
        exit(1)
    }
    let ok = runHeadlessSelfTest()
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--rendertest") {
    let ok = runRenderSelfTest()
    exit(ok ? 0 : 1)
}
// #239 headless dialogue smoke test: builds the REAL dialogue overlay in an
// offscreen view (no window is ever shown) and asserts it opens, carries its
// exit affordances, and closes on walk-away. Catches "interact does nothing"
// regressions that engine tests can't see, with no display needed.
if CommandLine.arguments.contains("--dialogueprobe") {
    _ = NSApplication.shared
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    let dc = DialogueController()
    dc.load()
    print("dialogueprobe: npc trees loaded = \(dc.loadedNPCCount)")
    guard dc.loadedNPCCount > 0 else {
        print("dialogueprobe FAIL: village_npcs.json missing or unparseable")
        exit(1)
    }
    var closed = 0
    var ended = 0
    dc.onEnd = { ended += 1 }
    dc.onClose = { closed += 1 }
    dc.onDonate = { _ in }
    dc.show(npcId: 4, in: parent, title: "Pip the Woodcutter")
    guard dc.isOpen, let ov = parent.subviews.first else {
        print("dialogueprobe FAIL: overlay did not open")
        exit(1)
    }
    // Panel must exist and carry at least one choice button plus the X.
    func allButtons(_ v: NSView) -> [NSButton] {
        v.subviews.flatMap { allButtons($0) } + (v.subviews.compactMap { $0 as? NSButton })
    }
    let btns = allButtons(ov)
    let hasX = btns.contains { $0.attributedTitle.string == "\u{2715}" }
    print("dialogueprobe: overlay open, buttons = \(btns.count), hasX = \(hasX)")
    guard btns.count >= 2, hasX else {
        print("dialogueprobe FAIL: expected choice buttons + X close")
        exit(1)
    }
    // Walk-away: anchor, then move 10 blocks; the chat must close exactly once.
    dc.playerMoved(x: 100, z: 100)
    dc.playerMoved(x: 110, z: 100)
    guard closed == 1, ended == 1, !dc.isOpen else {
        print("dialogueprobe FAIL: walk-away did not close/end (closed=\(closed), ended=\(ended))")
        exit(1)
    }
    // Reopen as the Mason: the action must name all three accepted stone blocks.
    dc.show(npcId: 5, in: parent)
    let masonButtons = parent.subviews.first.map(allButtons) ?? []
    let hasMasonMaterials = masonButtons.contains {
        $0.attributedTitle.string == "Donate held stone, cobblestone, or stone brick"
    }
    guard dc.isOpen, hasMasonMaterials else {
        print("dialogueprobe FAIL: Mason material guidance missing")
        exit(1)
    }
    // #317: the Elder can have enough offers to push the bottom Done button
    // offscreen. The trade header must always retain its own close affordance.
    var tradeClosed = 0
    let trade = TradeView(frame: parent.bounds, npcId: 3, renderer: nil)
    trade.onClose = { tradeClosed += 1 }
    let tradeButtons = allButtons(trade)
    guard let tradeX = tradeButtons.first(where: { $0.attributedTitle.string == "\u{2715}" }) else {
        print("dialogueprobe FAIL: trade overlay missing X close")
        exit(1)
    }
    tradeX.performClick(nil)
    guard tradeClosed == 1 else {
        print("dialogueprobe FAIL: trade X did not close")
        exit(1)
    }
    print("dialogueprobe OK")
    exit(0)
}
if CommandLine.arguments.contains("--washouttest") {
    let ok = runWashoutTest()
    exit(ok ? 0 : 1)
}
// #89 decisive shadow yaw experiment: fixed synthetic scene, fixed camera position,
// fixed sun; render at several yaws and report the shadow factor + colour at a FIXED
// world point. Answers "does a fixed point's shadow change with yaw?" with no streaming
// or physics confound (which the input-driven --shot harness cannot avoid).
if CommandLine.arguments.contains("--shadowprobe") {
    let ok = runShadowYawProbe()
    exit(ok ? 0 : 1)
}
// --shadowposprobe: the POSITION + SUN probe. Tall occluder, high vs low sun, sweep the
// camera POSITION and check a FIXED world point's shadow stays constant (the wipe test).
if CommandLine.arguments.contains("--shadowposprobe") {
    let ok = runShadowPosProbe()
    exit(ok ? 0 : 1)
}
// --shadowstabilitytest: GREEN/RED gate for the #115 position+sun shadow wipe. Walks the
// player past a tall occluder at high AND low sun and FAILS if a fixed world point's shadow
// factor moves more than a small tolerance (so the cascade-union fix cannot silently regress).
if CommandLine.arguments.contains("--shadowstabilitytest") {
    let ok = runShadowPosProbe(strict: true)
    exit(ok ? 0 : 1)
}
// --shadowyawprobe: SINGLE-PROCESS REAL-TERRAIN camera-yaw shadow wipe probe. Boots the
// engine, streams a fixed-seed region in, FIXES the camera position, low E/W sun, then
// renders the SAME scene through the FULL two-cascade shadow pipeline at yaws N/E/S/W and
// reports the shadowed-ground fraction per yaw (+ depth-map hashes). Reproduces the wipe
// the synthetic --shadowprobe (one pillar, one map) could not. Verbose. SYP_SHOTS=1 saves
// /tmp/syaw_<deg>.png colour shots.
if CommandLine.arguments.contains("--shadowyawprobe") {
    let ok = runShadowYawTerrainProbe(strict: false)
    exit(ok ? 0 : 1)
}
// --shadowyawtest: the GREEN/RED regression gate for the camera-yaw wipe. Same sweep; FAILS
// if the per-yaw shadow-coverage spread exceeds a small tolerance (shadows wipe by yaw).
if CommandLine.arguments.contains("--shadowyawtest") {
    let ok = runShadowYawTerrainProbe(strict: true)
    exit(ok ? 0 : 1)
}
// --groundnightprobe: SINGLE-PROCESS REAL-TERRAIN night yaw sweep (#117). Boots the
// engine, streams a fixed-seed region in, then renders the SAME ground at several yaws
// at deep night and reports the lower-half ground mean luma per yaw. Reproduces the
// player's view-direction-dependent night ground wash that the --shot harness could not
// (each --shot is a separate process streaming a different patch of world). Verbose probe.
if CommandLine.arguments.contains("--groundnightprobe") {
    let ok = runGroundNightProbe(strict: false)
    exit(ok ? 0 : 1)
}
// --groundnighttest: the GREEN/RED regression gate for #117. Same sweep; FAILS if the
// night ground luma spread across yaw exceeds a small tolerance.
if CommandLine.arguments.contains("--groundnighttest") {
    let ok = runGroundNightProbe(strict: true)
    exit(ok ? 0 : 1)
}
// --vistaprobe: #118 LONG-VIEW vista shadow-sweep probe. HIGH camera over real terrain
// looking across a large expanse; renders the SAME vista at several yaws through the FULL
// two-cascade pipeline, saves color + grayscale-shadow PNGs, and reports the radial shadow
// cutoff distance per yaw. Set BF_VISTA_FARR / BF_VISTA_FADE_END to render the OLD (300/298)
// vs NEW (380/380) behaviour from one binary for a true before/after.
if CommandLine.arguments.contains("--vistaprobe") {
    let ok = runVistaProbe()
    exit(ok ? 0 : 1)
}
// --vistatest: #118 GREEN/RED gate for the long-view shadow sweep. Boots a fixed-seed real
// terrain, perches HIGH over a long vista, renders several yaws through the full two-cascade
// pipeline, and FAILS if the post-fog shadow-coverage fade forms a perceptible ring (the
// boundary that swept across the land when turning). Needs a Metal device; self-skips otherwise.
if CommandLine.arguments.contains("--vistatest") {
    let ok = runVistaProbe(strict: true)
    exit(ok ? 0 : 1)
}
// --worldfixedprobe / --worldfixedtest: THE world-space voxel shadow guard. Boots a fixed-seed
// real-terrain region, freezes the player (and the world occupancy grid), then renders the SAME
// ground patch from many camera positions AND yaws and asserts a fixed world point's sun shadow
// is IDENTICAL from every camera (spread ~0). This is the defining property of the rebuild:
// shadows belong to the WORLD, not the camera. Replaces the retired shadow-MAP guards
// (--shadowyawtest / --shadowstabilitytest / --vistatest). Needs a Metal device; self-skips.
if CommandLine.arguments.contains("--worldfixedprobe") {
    let ok = runWorldFixedShadowTest(strict: false)
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--worldfixedtest") {
    let ok = runWorldFixedShadowTest(strict: true)
    exit(ok ? 0 : 1)
}
if let idx = CommandLine.arguments.firstIndex(of: "--screenshot"), idx + 1 < CommandLine.arguments.count {
    let ok = runRenderSelfTest(savePath: CommandLine.arguments[idx + 1], width: 960, height: 720)
    exit(ok ? 0 : 1)
}
// --shot <path>: headless gameplay screenshot — boots a real world, renders the
// full scene (terrain + props + sky + shadows + bloom) offscreen, writes a PNG. (#52)
if let idx = CommandLine.arguments.firstIndex(of: "--shot"), idx + 1 < CommandLine.arguments.count {
    let ok = runPerfTest(seconds: 0, jsonPath: nil, shotPath: CommandLine.arguments[idx + 1])
    exit(ok ? 0 : 1)
}
// --portrait <path>: headless render of the editor portrait across a few appearance
// variants, so the look can be checked without the desktop UI (#71).
if let idx = CommandLine.arguments.firstIndex(of: "--portrait"), idx + 1 < CommandLine.arguments.count {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let cell = 190, cols = 10
    var variants: [CharacterAppearance] = []
    for h in 0..<10 { variants.append(CharacterAppearance(skin: 2, shirt: 4, hairColor: 1, hairStyle: h)) }              // all hair styles
    for e in 0..<10 { variants.append(CharacterAppearance(skin: 2, shirt: 7, hairColor: 1, hairStyle: 2, eyeStyle: e, eyeColor: e)) } // all eyes + colours
    for n in 0..<10 { variants.append(CharacterAppearance(skin: 2, shirt: 8, hairColor: 1, hairStyle: 2, nose: n)) }    // all noses
    for m in 0..<10 { variants.append(CharacterAppearance(skin: 2, shirt: 3, hairColor: 1, hairStyle: 2, mouth: m)) }   // all mouths
    for hs in 0..<10 { variants.append(CharacterAppearance(skin: 2, shirt: 4, hairColor: 1, hairStyle: 2, headShape: hs)) } // all head shapes
    for bs in 0..<10 { variants.append(CharacterAppearance(skin: 2, shirt: 5, hairColor: 1, hairStyle: 2, bodyShape: bs)) } // all body shapes
    let W = cell * min(cols, variants.count)
    let H = cell * ((variants.count + cols - 1) / cols)
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, v) in variants.enumerated() {
        let r = CGRect(x: (i % cols) * cell, y: H - (i / cols + 1) * cell, width: cell, height: cell)
        v.drawPortrait(in: ctx, rect: r)
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
    exit(0)
}
// --critters <path>: headless gallery of every creature model (#51 sub-voxel review).
if let idx = CommandLine.arguments.firstIndex(of: "--critters"), idx + 1 < CommandLine.arguments.count {
    let ok = runCritterGallery(savePath: CommandLine.arguments[idx + 1])
    exit(ok ? 0 : 1)
}
if let idx = CommandLine.arguments.firstIndex(of: "--perftest") {
    let secs = (idx + 1 < CommandLine.arguments.count) ? (Double(CommandLine.arguments[idx + 1]) ?? 20) : 20
    let jsonPath = ProcessInfo.processInfo.environment["BF_METAL_PERF_JSON"] ?? "/tmp/blockfall_perf.json"
    let ok = runPerfTest(seconds: secs, jsonPath: jsonPath)
    exit(ok ? 0 : 1)
}

// #109 --chestshot <path>: render the chest panel overlay headlessly to a PNG so the
// kid-friendly chest UI can be reviewed without driving the live app. Builds a HUDView,
// seeds a few inventory items + a chest view with loot, and caches its display.
if let idx = CommandLine.arguments.firstIndex(of: "--chestshot"), idx + 1 < CommandLine.arguments.count {
    let W = 1000, H = 760
    let hv = HUDView(frame: NSRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    // Seed a player inventory: a few stacks across the hotbar + main rows.
    var hud = bf_hud_state()
    hud.selected_slot = 2
    withUnsafeMutableBytes(of: &hud.inventory) { raw in
        let inv = raw.bindMemory(to: bf_hud_slot.self)
        let seed: [(Int, UInt16, UInt16)] = [
            (0, 3, 41), (1, 24, 12), (2, 13, 7), (4, 56, 4),
            (9, 1, 33), (10, 51, 9), (12, 90, 6), (18, 16, 22),
        ]
        for (i, item, count) in seed { inv[i] = bf_hud_slot(item: item, count: count, durability: 0xFFFF, _pad: 0) }
    }
    hv.update(from: hud)
    // A chest with mixed loot (matches the ruin/structure tables).
    var view = bf_chest_view()
    view.pos = bf_ivec3(x: 12, y: 80, z: -34)
    view.present = 1
    withUnsafeMutableBytes(of: &view.slots) { raw in
        let s = raw.bindMemory(to: bf_hud_slot.self)
        let loot: [(Int, UInt16, UInt16)] = [
            (0, 56, 2), (1, 57, 3), (2, 61, 5), (3, 62, 2), (4, 92, 1), (6, 24, 8), (8, 51, 3),
        ]
        for (i, item, count) in loot { s[i] = bf_hud_slot(item: item, count: count, durability: 0xFFFF, _pad: 0) }
    }
    hv.setChestOpen(pos: view.pos, view: view)
    hv.layoutSubtreeIfNeeded()
    guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { exit(1) }
    hv.cacheDisplay(in: hv.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
    exit(0)
}

// #182 --mapshot <path>: render the world-map overlay headlessly to a PNG so the
// kid-facing map (explored blob + home/village/totem markers + player arrow) can
// be reviewed without driving the live app. Seeds a synthetic explored region
// around a pretend player plus a marker of each kind. Mirrors --chestshot.
if let idx = CommandLine.arguments.firstIndex(of: "--mapshot"), idx + 1 < CommandLine.arguments.count {
    let W = 1100, H = 860
    let mv = MapView(frame: NSRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    let cells = 512, cellSize = 64, period = 32768
    mv.period = period; mv.cellSize = cellSize; mv.cells = cells
    // Player mid-world; an irregular explored blob around them plus a thin
    // "travelled corridor" so the reveal-as-you-walk look is visible.
    let px = 16384, pz = 16384
    var explored = [UInt8](repeating: 0, count: cells * cells / 8)
    func reveal(_ cx: Int, _ cz: Int) {
        let x = ((cx % cells) + cells) % cells, z = ((cz % cells) + cells) % cells
        let bit = z * cells + x
        explored[bit >> 3] |= 1 << (bit & 7)
    }
    let pcx = px / cellSize, pcz = pz / cellSize
    // #189: fresh spawn reveals a ROUND clearing centred on home (8-cell radius),
    // matching the engine. Plus a walked corridor + far camp so the reveal-as-you
    // -walk look is still visible in the preview.
    let clearing = 8
    for dz in -clearing...clearing {
        for dx in -clearing...clearing where dx * dx + dz * dz <= clearing * clearing {
            reveal(pcx + dx, pcz + dz)
        }
    }
    for t in 0..<60 { reveal(pcx + 8 + t / 2, pcz - t / 3) }        // a walked corridor
    for dz in -4...4 { for dx in -4...4 where dx*dx + dz*dz <= 18 { // a far camp blob
        reveal(pcx + 38 + dx, pcz - 22 + dz) } }
    mv.explored = explored
    // #224: synthetic biome bands so the tint layer previews headless.
    var biomes = [UInt8](repeating: 0, count: cells * cells)
    for cz in 0..<cells { for cx in 0..<cells {
        biomes[cz * cells + cx] = UInt8((cx / 12 + cz / 16) % 7)
    } }
    mv.biomes = biomes
    mv.playerX = Float(px); mv.playerZ = Float(pz); mv.playerFacing = 0.8
    mv.markers = [
        // Home sits at spawn, dead-centre of the clearing (#189).
        MapView.Marker(x: Int32(px), z: Int32(pz), kind: 0, id: 1, name: "Home"),
        MapView.Marker(x: Int32(px + 550), z: Int32(pz - 350), kind: 4, id: 100,
                       name: "Town of " + TownNames.name(x: Int32(px + 550), z: Int32(pz - 350))),
        MapView.Marker(x: Int32(px - 620), z: Int32(pz - 480), kind: 3, id: 101,
                       name: "City of " + TownNames.name(x: Int32(px - 620), z: Int32(pz - 480))),
        MapView.Marker(x: Int32(px + 260), z: Int32(pz + 520), kind: 2, id: 200, name: "Totem 1"),
        MapView.Marker(x: Int32(px + 1500), z: Int32(pz - 1180), kind: 2, id: 201, name: "Totem 2"),
    ]
    // Two shots: the default local zoom (<path>) and the whole planet zoomed
    // out (<path minus .png>_planet.png) so the torus-wide view is reviewable.
    func mapShot(_ path: String) {
        mv.rebuild()
        mv.layoutSubtreeIfNeeded()
        guard let rep = mv.bitmapImageRepForCachingDisplay(in: mv.bounds) else { exit(1) }
        mv.cacheDisplay(in: mv.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    let path = CommandLine.arguments[idx + 1]
    let base = path.replacingOccurrences(of: ".png", with: "")
    mv.viewSpan = 4096   // #229: pin the harness shot, ignore persisted zoom
    mapShot(path)
    mv.debugSelectMarker(1)   // Town: shows the "Travel to ...?" chip
    mapShot(base + "_confirm.png")
    mv.debugSelectMarker(-1)
    mv.viewSpan = period
    // #241: keep HOME centred at planet zoom while the player sits elsewhere.
    mv.playerX = Float(px + 6000); mv.playerZ = Float(pz - 5000)
    mapShot(base + "_planet.png")
    // #258: a second full-planet fixture puts the first two settlements on
    // opposite chart edges but only 3,200 world blocks apart across the torus.
    // The dashed route should continue cleanly at both edges, never cross the
    // whole chart. This makes seam/zoom handling deterministic to review.
    let regularMarkers = mv.markers
    mv.markers = [
        MapView.Marker(x: Int32(px), z: Int32(pz), kind: 0, id: 1, name: "Home"),
        MapView.Marker(x: Int32(px + period / 2 - 1600), z: Int32(pz - 500),
                       kind: 4, id: 100, name: "Eastmarket"),
        MapView.Marker(x: Int32(px - period / 2 + 1600), z: Int32(pz + 500),
                       kind: 3, id: 101, name: "Westgate City"),
    ]
    mv.playerX = Float(px); mv.playerZ = Float(pz)
    mapShot(base + "_route_seam.png")
    mv.markers = regularMarkers
    // #187 also render the corner minimap with the same sample data (over a green
    // backdrop so the translucent disc reads) for review without the live app.
    let mm = MinimapView(frame: NSRect(x: 0, y: 0, width: 176, height: 176))
    mm.debugPreview(markers: mv.markers, playerX: Float(px), playerZ: Float(pz),
                    facing: 0.8, period: period)
    let bg = NSView(frame: NSRect(x: 0, y: 0, width: 208, height: 208))
    bg.wantsLayer = true
    bg.layer?.backgroundColor = NSColor(calibratedRed: 0.45, green: 0.62, blue: 0.36, alpha: 1).cgColor
    mm.setFrameOrigin(NSPoint(x: 16, y: 16))
    bg.addSubview(mm)
    if let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) {
        bg.cacheDisplay(in: bg.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: base + "_minimap.png"))
    }
    exit(0)
}

// #95 --villageshot <path>: render the living-villages donation HUD panel at each tier
// (wood -> stone -> iron) stacked into one PNG, so the kid-facing donation panel can be
// reviewed without driving the live app. Mirrors --chestshot.
if let idx = CommandLine.arguments.firstIndex(of: "--villageshot"), idx + 1 < CommandLine.arguments.count {
    let W = 900, rowH = 220
    // Four sample states: tier 0 (needs wood, half ring), tier 1->stone, tier 2->iron, tier 3 done.
    let states: [(UInt8, UInt32, UInt32, UInt32, UInt32, String, UInt8)] = [
        (0, 30, 62, 0, 0, "wood", 3),    // building the wooden wall + ward
        (1, 62, 62, 8, 16, "stone", 7),  // one light short, donating stone
        (2, 62, 62, 5, 8, "iron", 8),    // active ward, donating iron
        (3, 62, 62, 0, 0, "", 8),        // guarded city + active ward
    ]
    let H = rowH * states.count
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Soft dusk backdrop so the panel reads (the panel itself is semi-transparent dark).
    ctx.setFillColor(red: 0.18, green: 0.22, blue: 0.30, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    for (i, st) in states.enumerated() {
        let hv = HUDView(frame: NSRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(rowH)))
        var v = bf_village_view()
        v.present = 1
        v.tier = st.0
        v.wood_cells = st.1; v.wood_total = st.2
        v.progress = st.3; v.progress_needed = st.4
        v.lights = st.6; v.ward_active = st.6 >= 8 ? 1 : 0
        withUnsafeMutableBytes(of: &v.want) { raw in
            let p = raw.bindMemory(to: CChar.self)
            for (j, byte) in Array(st.5.utf8).prefix(15).enumerated() { p[j] = CChar(bitPattern: byte) }
        }
        hv.setVillage(v)
        hv.layoutSubtreeIfNeeded()
        guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { exit(1) }
        hv.cacheDisplay(in: hv.bounds, to: rep)
        if let img = rep.cgImage {
            ctx.draw(img, in: CGRect(x: 0, y: H - (i + 1) * rowH, width: W, height: rowH))
        }
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
