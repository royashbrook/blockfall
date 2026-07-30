import AVFoundation
import GameController
import MetalKit
import UIKit

final class GameViewController: UIViewController {
    private var gameView: GameView!
    private var renderer: Renderer?
    private var audio: GameAudio?
    private let hud = HUDView()
    private let loadingLabel = UILabel()
    private let pauseOverlay = PauseOverlay()
    private var controllerObservers: [NSObjectProtocol] = []
    private var dialoguePresented = false
    private var sceneIsActive = false

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.left, .right] }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else {
            showFatal("This iPad does not support Metal.")
            return
        }

        let metalView = GameView(frame: view.bounds, device: device)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        // Keep UIKit controls composited above the asynchronously rendered Metal
        // layer. Without the transaction, portions of labels/buttons can be
        // overwritten by a late drawable present on iPad.
        metalView.presentsWithTransaction = true
        view.addSubview(metalView)

        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.isUserInteractionEnabled = true
        hud.backgroundColor = .clear
        hud.input = metalView
        hud.onPause = { [weak self] in self?.setPaused(true) }
        view.addSubview(hud)

        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.text = "Growing your world…"
        loadingLabel.textColor = .white
        loadingLabel.font = .boldSystemFont(ofSize: 24)
        loadingLabel.backgroundColor = UIColor(white: 0.05, alpha: 0.78)
        loadingLabel.textAlignment = .center
        loadingLabel.layer.cornerRadius = 18
        loadingLabel.clipsToBounds = true
        view.addSubview(loadingLabel)

        pauseOverlay.translatesAutoresizingMaskIntoConstraints = false
        pauseOverlay.isHidden = true
        pauseOverlay.onResume = { [weak self] in self?.setPaused(false) }
        pauseOverlay.onMode = { [weak self] in
            self?.gameView.toggleMode()
            self?.pauseOverlay.showStatus("Mode toggled.")
        }
        pauseOverlay.onHost = { [weak self] in
            self?.renderer?.startHost()
            self?.pauseOverlay.showStatus("Hosting on this local network.")
        }
        pauseOverlay.onJoin = { [weak self] in
            self?.renderer?.joinLAN()
            self?.pauseOverlay.showStatus("Looking for a nearby Blockfall game…")
        }
        pauseOverlay.onTouchSize = { [weak self] size in
            self?.hud.setTouchControlSize(size)
            self?.pauseOverlay.showStatus("Touch controls: \(size.title)")
        }
        view.addSubview(pauseOverlay)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hud.topAnchor.constraint(equalTo: view.topAnchor),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingLabel.widthAnchor.constraint(equalToConstant: 290),
            loadingLabel.heightAnchor.constraint(equalToConstant: 76),
            pauseOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pauseOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pauseOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            pauseOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        gameView = metalView
        do {
            let saveDir = try Self.defaultSaveDirectory()
            let audio = GameAudio()
            let renderer = Renderer(
                view: metalView,
                device: device,
                saveDir: saveDir.path,
                audio: audio
            )
            renderer.hud = hud
            hud.onChestTake = { [weak renderer] slot in renderer?.enqueueChestTake(slot) }
            hud.onChestClose = { [weak renderer] in renderer?.closeChest() }
            renderer.onDialogue = { [weak self] npcId in
                DispatchQueue.main.async { self?.showDialogue(npcId: npcId) }
            }
            renderer.onReady = { [weak self] in
                UIView.animate(withDuration: 0.25) {
                    self?.loadingLabel.alpha = 0
                }
            }
            metalView.delegate = renderer
            self.audio = audio
            self.renderer = renderer
            installControllerSupport()
            installAudioInterruptionSupport()
        } catch {
            showFatal("Could not create the Blockfall save: \(error.localizedDescription)")
        }
    }

    deinit {
        for observer in controllerObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        audio?.stop()
        deactivateAudioSession()
        gameView?.delegate = nil
        renderer?.shutdown()
    }

    func handleSceneDidBecomeActive() {
        sceneIsActive = true
        gameView?.isPaused = false
        gameView?.setPaused(!pauseOverlay.isHidden)
        activateAudioSession()
    }

    func handleSceneWillResignActive() {
        sceneIsActive = false
        suspendForSystem()
    }

    func handleSceneDidEnterBackground() {
        // Resigning active normally checkpointed already. Save again here so
        // unusual scene transitions still have a durable boundary.
        _ = renderer?.saveWorld()
    }

    func handleSceneDidDisconnect() {
        suspendForSystem()
        gameView?.delegate = nil
        renderer?.shutdown()
        renderer = nil
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Shed future chunk pressure immediately, then preserve the current
        // world in case iPadOS subsequently reclaims the process.
        renderer?.setRenderDistance(8)
        _ = renderer?.saveWorld()
        NSLog("Blockfall: memory warning; render distance reduced to 8 chunks")
    }

    private func setPaused(_ paused: Bool) {
        hud.resetTouchControls()
        gameView.setPaused(paused)
        pauseOverlay.showStatus("")
        pauseOverlay.isHidden = !paused
        if paused { view.bringSubviewToFront(pauseOverlay) }
    }

    private func suspendForSystem() {
        hud.resetTouchControls()
        gameView?.setPaused(true)
        _ = renderer?.saveWorld()
        gameView?.isPaused = true
        audio?.stop()
        deactivateAudioSession()
    }

    private func installAudioInterruptionSupport() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.audio?.stop()
            } else if self.sceneIsActive {
                self.activateAudioSession()
            }
        }
        controllerObservers.append(observer)
    }

    private func activateAudioSession() {
        guard sceneIsActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audio?.start()
        } catch {
            // Audio is optional; a route/session failure must never stop play.
            NSLog("Blockfall: audio session unavailable: %@", "\(error)")
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }

    private func installControllerSupport() {
        let center = NotificationCenter.default
        controllerObservers.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.configure(controller)
        })
        controllerObservers.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.gameView.setControllerMovement(strafe: 0, forward: 0)
            self?.gameView.setControllerLook(x: 0, y: 0)
            self?.gameView.endMine()
        })
        GCController.controllers().forEach(configure)
        GCController.startWirelessControllerDiscovery()
    }

    private func configure(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.playerIndex = .index1
        pad.leftThumbstick.valueChangedHandler = { [weak gameView] _, x, y in
            gameView?.setControllerMovement(strafe: x, forward: y)
        }
        pad.rightThumbstick.valueChangedHandler = { [weak gameView] _, x, y in
            gameView?.setControllerLook(x: x, y: y)
        }
        pad.buttonA.valueChangedHandler = { [weak gameView] _, _, pressed in
            gameView?.setJumping(pressed)
        }
        pad.buttonB.valueChangedHandler = { [weak gameView] _, _, pressed in
            gameView?.setDescending(pressed)
        }
        pad.leftTrigger.valueChangedHandler = { [weak gameView] _, _, pressed in
            if pressed { gameView?.beginMine() } else { gameView?.endMine() }
        }
        pad.rightTrigger.valueChangedHandler = { [weak gameView] _, _, pressed in
            if pressed { gameView?.interact() }
        }
        pad.buttonX.valueChangedHandler = { [weak gameView] _, _, pressed in
            if pressed { gameView?.interact() }
        }
        pad.buttonY.valueChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.hud.toggleInventoryFromExternalControl() }
        }
        pad.dpad.left.valueChangedHandler = { [weak gameView] _, _, pressed in
            if pressed { gameView?.scrollHotbar(-1) }
        }
        pad.dpad.right.valueChangedHandler = { [weak gameView] _, _, pressed in
            if pressed { gameView?.scrollHotbar(1) }
        }
        pad.buttonMenu.valueChangedHandler = { [weak self] _, _, pressed in
            if pressed, let self { self.setPaused(self.pauseOverlay.isHidden) }
        }
    }

    private func showDialogue(npcId: Int) {
        guard !dialoguePresented, presentedViewController == nil else { return }
        dialoguePresented = true
        hud.resetTouchControls()
        gameView.setInterfaceBlocked(true)

        let lookedName = renderer?.lookName ?? ""
        let name = lookedName.isEmpty ? "Villager" : lookedName
        let alert = UIAlertController(
            title: name,
            message: "How can we help this town?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Donate what is needed", style: .default) {
            [weak self] _ in
            self?.gameView.requestDonate()
            self?.finishDialogue()
        })
        if let offers = renderer?.tradeOffers(npcId: Int32(npcId)) {
            for (index, offer) in offers.prefix(4).enumerated() {
                let title = "\(offer.giveCount) \(itemName(offer.giveItem)) → "
                    + "\(offer.getCount) \(itemName(offer.getItem))"
                alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    _ = self?.renderer?.tradeExecute(npcId: Int32(npcId), index: UInt32(index))
                    self?.finishDialogue()
                })
            }
        }
        alert.addAction(UIAlertAction(title: "Done", style: .cancel) { [weak self] _ in
            self?.finishDialogue()
        })
        present(alert, animated: true)
    }

    private func finishDialogue() {
        gameView.requestDialogueEnd()
        gameView.setInterfaceBlocked(false)
        dialoguePresented = false
    }

    private static func defaultSaveDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let save = base.appendingPathComponent("Blockfall/Worlds/iPad World", isDirectory: true)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: save.path
        )
        return save
    }

    private func showFatal(_ message: String) {
        let label = UILabel(frame: view.bounds.insetBy(dx: 40, dy: 40))
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .title2)
        label.text = message
        view.addSubview(label)
    }
}
