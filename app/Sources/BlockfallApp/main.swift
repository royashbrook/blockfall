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
    var device: MTLDevice!
    weak var gameView: GameView?
    var gameContainer: NSView?
    var pauseOverlay: NSView?

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
        audio.start()
        audio.setAmbienceEnabled(true)

        // Show the main menu first; start the game when a world is chosen.
        menu.onPlayWorld = { [weak self] saveDir, _, _ in self?.startGame(saveDir: saveDir) }
        menu.onQuit = { NSApp.terminate(nil) }
        window.contentView = menu.rootView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startGame(saveDir: String) {
        let frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let mtkView = GameView(frame: frame, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60

        let r = Renderer(view: mtkView, device: device, saveDir: saveDir, audio: audio)
        mtkView.delegate = r
        mtkView.onHost = { [weak r] in r?.startHost() }
        mtkView.onJoin = { [weak r] in r?.joinLAN() }
        mtkView.onPause = { [weak self] in self?.pauseGame() }

        let h = HUDView(frame: frame)
        h.autoresizingMask = [.width, .height]
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
        gameView?.releaseMouse()
        let ov = NSView(frame: container.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.wantsLayer = true
        ov.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        let title = NSTextField(labelWithString: "Paused")
        title.font = .boldSystemFont(ofSize: 40); title.textColor = .white
        title.alignment = .center; title.translatesAutoresizingMaskIntoConstraints = false

        let resume = pauseButton("Resume", #selector(resumeGame))
        let menuBtn = pauseButton("Save & Quit to Menu", #selector(quitToMenu))
        let stack = NSStackView(views: [title, resume, menuBtn])
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
        b.bezelStyle = .rounded; b.font = .systemFont(ofSize: 18)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return b
    }
    @objc private func resumeGame() {
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
        gameView?.grabMouse()
        if let gv = gameView { window.makeFirstResponder(gv) }
    }
    @objc private func quitToMenu() {
        pauseOverlay?.removeFromSuperview(); pauseOverlay = nil
        renderer?.shutdown(); renderer = nil    // saves the world
        gameView = nil; gameContainer = nil; hud = nil
        menu.refresh()
        window.contentView = menu.rootView
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
if let idx = CommandLine.arguments.firstIndex(of: "--screenshot"), idx + 1 < CommandLine.arguments.count {
    let ok = runRenderSelfTest(savePath: CommandLine.arguments[idx + 1], width: 960, height: 720)
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
