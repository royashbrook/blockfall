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
    var renderer: Renderer!
    var hud: HUDView!

    func applicationDidFinishLaunching(_: Notification) {
        // Verify ABI before doing anything (hard rule from the contract).
        guard bf_abi_version() == BF_ABI_VERSION else {
            fatalError("ABI mismatch: app=\(BF_ABI_VERSION) engine=\(bf_abi_version())")
        }

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Blockfall"
        window.center()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("No Metal device (this build targets Apple Silicon).")
        }

        let mtkView = MTKView(frame: frame, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60

        renderer = Renderer(view: mtkView, device: device)
        mtkView.delegate = renderer

        // HUD overlay drawn on top of the Metal view (AppKit, M0-simple).
        hud = HUDView(frame: frame)
        hud.autoresizingMask = [.width, .height]
        renderer.hud = hud

        let container = NSView(frame: frame)
        mtkView.autoresizingMask = [.width, .height]
        container.addSubview(mtkView)
        container.addSubview(hud)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }

    func applicationWillTerminate(_: Notification) {
        renderer?.shutdown()
    }
}

// Headless self-check mode for CI: --selftest creates the engine, runs a few
// frames without a window, and exits 0. Lets ci/check.sh exercise the Swift<->
// C++ boundary on a machine with no display.
if CommandLine.arguments.contains("--selftest") {
    let ok = runHeadlessSelfTest()
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
