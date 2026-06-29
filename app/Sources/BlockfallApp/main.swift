// ============================================================================
// Blockfall — app shell (Phase 0 / M0)
// Opens a window with a Metal view, creates the engine over the frozen C ABI,
// runs the frame loop, clears a sky-colored frame, and overlays a HUD.
// This is the M0 exit-gate artifact: "stub .app launches, clears a colored
// frame, shows a HUD overlay." Renderer + gameplay grow behind the same ABI.
// ============================================================================
import AppKit
import MetalKit
import CBlockcore

// Keep C strings alive for the engine's lifetime (process-scoped).
func persistentCString(_ s: String) -> UnsafePointer<CChar> {
    return UnsafePointer(strdup(s))!
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

    // ---- HUD option persistence (#: text size + visibility) ----
    // UserDefaults keys. Loaded at startup (startGame) and written on change.
    static let kHUDScaleKey = "hudScale"
    static let kHUDVisibleKey = "hudVisible"
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

    func applicationDidFinishLaunching(_: Notification) {
        guard bf_abi_version() == BF_ABI_VERSION else {
            fatalError("ABI mismatch: app=\(BF_ABI_VERSION) engine=\(bf_abi_version())")
        }
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
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
        mtkView.preferredFramesPerSecond = 60
        mtkView.presentsWithTransaction = true   // so the AppKit HUD overlay composites on top

        let r = Renderer(view: mtkView, device: device, saveDir: saveDir, audio: audio,
                         fresh: fresh, seed: seed)
        mtkView.delegate = r
        mtkView.onHost = { [weak r] in r?.startHost() }
        mtkView.onJoin = { [weak r] in r?.joinLAN() }
        mtkView.onPause = { [weak self] in self?.pauseGame() }

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
        // #: apply the persisted HUD options (text size + visibility) so they
        // stick between sessions.
        h.hudScale = AppDelegate.loadHUDScale()
        h.hudVisible = AppDelegate.loadHUDVisible()
        r.hud = h

        let container = NSView(frame: frame)
        mtkView.autoresizingMask = [.width, .height]
        container.addSubview(mtkView)
        container.addSubview(h)

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
        dialogue.onClose = { [weak self] in self?.gameView?.grabMouse() }
        r.onDialogue = { [weak self] npcId in
            guard let self = self, let cv = self.window.contentView, !self.dialogue.isOpen else { return }
            self.gameView?.releaseMouse()
            self.dialogue.show(npcId: npcId, in: cv)
        }
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
    @objc private func pauseGame() {
        // ESC toggles: if the pause overlay is already up, ESC resumes (keep playing)
        // instead of being a no-op. Lets the player open the pause menu, click a graphics
        // checkbox, and ESC straight back to the game without reaching for the mouse.
        if pauseOverlay != nil { resumeGame(); return }
        guard let container = gameContainer else { return }
        gameView?.setPaused(true)
        let ov = NSView(frame: container.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.wantsLayer = true
        ov.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        let title = NSTextField(labelWithString: "Paused")
        title.font = .boldSystemFont(ofSize: 40); title.textColor = .white
        title.alignment = .center; title.translatesAutoresizingMaskIntoConstraints = false

        let resume = pauseButton("Keep Playing", #selector(resumeGame))
        let menuBtn = pauseButton("Save & Go to Menu", #selector(quitToMenu))

        // ---- HUD options (#: text size + visibility) ----
        // Text Size: a slider 1.0–2.0 with a live label. Show HUD: a checkbox.
        // Both write through to the live HUDView immediately and persist to
        // UserDefaults so they stick between sessions.
        let textLabel = NSTextField(labelWithString: "Text Size")
        textLabel.font = .boldSystemFont(ofSize: 16); textLabel.textColor = .white

        let slider = NSSlider(value: Double(hud?.hudScale ?? AppDelegate.loadHUDScale()),
                              minValue: 1.0, maxValue: 2.0,
                              target: self, action: #selector(hudScaleChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        hudScaleSlider = slider

        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.font = .systemFont(ofSize: 14); valueLabel.textColor = .white
        valueLabel.alignment = .center
        hudScaleValueLabel = valueLabel

        let sliderRow = NSStackView(views: [textLabel, slider, valueLabel])
        sliderRow.orientation = .horizontal; sliderRow.spacing = 12; sliderRow.alignment = .centerY

        let showHUD = NSButton(checkboxWithTitle: "Show HUD",
                               target: self, action: #selector(hudVisibleChanged(_:)))
        showHUD.state = (hud?.hudVisible ?? AppDelegate.loadHUDVisible()) ? .on : .off
        showHUD.contentTintColor = .white
        showHUD.attributedTitle = NSAttributedString(string: "Show HUD", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.white,
        ])

        updateHUDScaleLabel()   // fill the live value label now that it exists

        // ---- Graphics effect toggles (#: click each effect on/off, live + persisted) ----
        // #136 effects with a meaningful strength (God Rays, Cel Shading) carry an intensity
        // slider beside the checkbox; Bloom (always on) gets its own labelled slider row. The
        // slider greys out when the effect is toggled off. Lens Flare stays a plain toggle.
        let fxTitle = NSTextField(labelWithString: "Effects")
        fxTitle.font = .boldSystemFont(ofSize: 16); fxTitle.textColor = .white

        // God Rays + Cel Shading: checkbox with an intensity slider beside it.
        let godRayCb = gfxCheckbox("God Rays", tag: 2, on: renderer?.gfxGodRays ?? true)
        let grSlider = gfxIntensitySlider(value: Double(renderer?.gfxGodRayStr ?? 0.5),
                                          sel: #selector(godRayStrChanged(_:)),
                                          enabled: renderer?.gfxGodRays ?? true)
        godRaySlider = grSlider

        let celCb = gfxCheckbox("Cel Shading", tag: 5, on: renderer?.gfxCelShade ?? true)
        let celSlider = gfxIntensitySlider(value: Double(renderer?.gfxCelOutlineStr ?? 1.0),
                                           sel: #selector(celOutlineStrChanged(_:)),
                                           enabled: renderer?.gfxCelShade ?? true)
        celOutlineSlider = celSlider

        // Bloom is always on (no toggle); a plain labelled intensity slider.
        let bloomLabel = NSTextField(labelWithString: "Bloom")
        bloomLabel.font = .systemFont(ofSize: 14); bloomLabel.textColor = .white
        let bloomSlider = gfxIntensitySlider(value: Double(renderer?.gfxBloomStr ?? 0.5),
                                             sel: #selector(bloomStrChanged(_:)), enabled: true)
        let bloomRow = NSStackView(views: [bloomLabel, bloomSlider])
        bloomRow.orientation = .horizontal; bloomRow.spacing = 12; bloomRow.alignment = .centerY

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
        ])
        fxStack.orientation = .vertical; fxStack.spacing = 8; fxStack.alignment = .leading

        // #85 Render-distance slider (chunks 8..28), live + persisted.
        let rdLabel = NSTextField(labelWithString: "Render Distance")
        rdLabel.font = .systemFont(ofSize: 14); rdLabel.textColor = .white
        let rdVal = UserDefaults.standard.object(forKey: "gfxRenderDist") as? Int ?? 24
        let rdSlider = NSSlider(value: Double(rdVal), minValue: 8, maxValue: 40,
                                target: self, action: #selector(renderDistChanged(_:)))
        rdSlider.translatesAutoresizingMaskIntoConstraints = false
        rdSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let rdRow = NSStackView(views: [rdLabel, rdSlider])
        rdRow.orientation = .horizontal; rdRow.spacing = 10; rdRow.alignment = .centerY

        // ---- Audio toggles (#3: music + ambience on/off, live + persisted) ----
        let auTitle = NSTextField(labelWithString: "Audio")
        auTitle.font = .boldSystemFont(ofSize: 16); auTitle.textColor = .white
        let auStack = NSStackView(views: [
            volumeSliderRow("Music Volume", key: "audMusicVol", sel: #selector(musicVolChanged(_:))),
            volumeSliderRow("Sound Volume", key: "audSoundVol", sel: #selector(soundVolChanged(_:))),
            audioCheckbox("Music",    tag: 0, on: UserDefaults.standard.object(forKey: "audMusic")    as? Bool ?? true),
            audioCheckbox("Ambience", tag: 1, on: UserDefaults.standard.object(forKey: "audAmbience") as? Bool ?? true),
        ])
        auStack.orientation = .vertical; auStack.spacing = 8; auStack.alignment = .leading

        let charBtn = pauseButton("Customize Character", #selector(openCharacterEditor))
        let stack = NSStackView(views: [title, sliderRow, showHUD, fxTitle, fxStack, rdRow, auTitle, auStack, charBtn, resume, menuBtn])
        stack.orientation = .vertical; stack.spacing = 18; stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: ov.centerYAnchor),
        ])
        container.addSubview(ov)
        pauseOverlay = ov
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
            .font: NSFont.boldSystemFont(ofSize: 20),
            .foregroundColor: NSColor.white,
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        b.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return b
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
        renderer?.setCharacterAppearance(skin: editorAppearance.skinRGB, shirt: editorAppearance.shirtRGB)
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
        lbl.font = .systemFont(ofSize: 14); lbl.textColor = .white
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
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white,
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
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white,
        ])
        return b
    }
    // #: graphics toggle → live renderer + persisted. Tags match gfxCheckbox order.
    @objc private func gfxToggleChanged(_ sender: NSButton) {
        let on = (sender.state == .on)
        let keys = ["gfxFoliage", "gfxWater", "gfxGodRays", "gfxPollen", "gfxShadows", "gfxCelShade", "gfxLensFlare", "gfxCharShadows", "gfxClouds"]
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
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
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
    let ok = runHeadlessSelfTest()
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--rendertest") {
    let ok = runRenderSelfTest()
    exit(ok ? 0 : 1)
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
    let ok = runPerfTest(seconds: secs, jsonPath: "/tmp/blockfall_perf.json")
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

// #95 --villageshot <path>: render the living-villages donation HUD panel at each tier
// (wood -> stone -> iron) stacked into one PNG, so the kid-facing donation panel can be
// reviewed without driving the live app. Mirrors --chestshot.
if let idx = CommandLine.arguments.firstIndex(of: "--villageshot"), idx + 1 < CommandLine.arguments.count {
    let W = 900, rowH = 220
    // Four sample states: tier 0 (needs wood, half ring), tier 1->stone, tier 2->iron, tier 3 done.
    let states: [(UInt8, UInt32, UInt32, UInt32, UInt32, String)] = [
        (0, 30, 62, 0, 0, "wood"),    // building the wooden wall
        (1, 62, 62, 8, 16, "stone"),  // wall done, donating stone to the mason
        (2, 62, 62, 5, 8, "iron"),    // stone done, donating iron to the blacksmith
        (3, 62, 62, 0, 0, ""),        // complete
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
