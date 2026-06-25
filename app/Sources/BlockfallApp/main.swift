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
    // #: pause-menu HUD-option controls (held so the action handlers can update
    // the live value label). Rebuilt each time the pause overlay opens.
    private weak var hudScaleSlider: NSSlider?
    private weak var hudScaleValueLabel: NSTextField?

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
        // #42: 'L' in GameView flips the quest-log overlay in the HUD.
        mtkView.onToggleQuestLog = { [weak h] in h?.toggleQuestLog() }
        // #: apply the persisted HUD options (text size + visibility) so they
        // stick between sessions.
        h.hudScale = AppDelegate.loadHUDScale()
        h.hudVisible = AppDelegate.loadHUDVisible()
        r.hud = h

        let container = NSView(frame: frame)
        mtkView.autoresizingMask = [.width, .height]
        container.addSubview(mtkView)
        container.addSubview(h)
        window.contentView = container
        window.makeFirstResponder(mtkView)
        renderer = r
        hud = h
        gameView = mtkView
        gameContainer = container
    }

    // ---- pause menu (Esc) ----
    @objc private func pauseGame() {
        guard pauseOverlay == nil, let container = gameContainer else { return }
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
        let fxTitle = NSTextField(labelWithString: "Effects")
        fxTitle.font = .boldSystemFont(ofSize: 16); fxTitle.textColor = .white
        let fxStack = NSStackView(views: [
            gfxCheckbox("Waving Foliage",    tag: 0, on: renderer?.gfxFoliage ?? false),
            gfxCheckbox("Water Reflections", tag: 1, on: renderer?.gfxWater   ?? true),
            gfxCheckbox("God Rays",          tag: 2, on: renderer?.gfxGodRays ?? true),
            gfxCheckbox("Pollen Motes",      tag: 3, on: renderer?.gfxPollen  ?? true),
            gfxCheckbox("Soft Shadows",      tag: 4, on: renderer?.gfxShadows ?? false),
        ])
        fxStack.orientation = .vertical; fxStack.spacing = 8; fxStack.alignment = .leading

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

        let stack = NSStackView(views: [title, sliderRow, showHUD, fxTitle, fxStack, auTitle, auStack, resume, menuBtn])
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
        let keys = ["gfxFoliage", "gfxWater", "gfxGodRays", "gfxPollen", "gfxShadows"]
        guard sender.tag >= 0 && sender.tag < keys.count else { return }
        UserDefaults.standard.set(on, forKey: keys[sender.tag])
        switch sender.tag {
        case 0: renderer?.gfxFoliage = on
        case 1: renderer?.gfxWater   = on
        case 2: renderer?.gfxGodRays = on
        case 3: renderer?.gfxPollen  = on
        case 4: renderer?.gfxShadows = on
        default: break
        }
    }
    @objc private func quitToMenu() {
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
