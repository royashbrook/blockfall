import MetalKit
import UIKit

final class GameViewController: UIViewController {
    private var gameView: GameView!
    private var renderer: Renderer?
    private let hud = HUDView()
    private let loadingLabel = UILabel()

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.left, .right] }

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
        metalView.presentsWithTransaction = false
        view.addSubview(metalView)

        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.isUserInteractionEnabled = false
        hud.backgroundColor = .clear
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
        ])

        gameView = metalView
        do {
            let saveDir = try Self.defaultSaveDirectory()
            let renderer = Renderer(
                view: metalView,
                device: device,
                saveDir: saveDir.path,
                audio: nil
            )
            renderer.hud = hud
            renderer.onReady = { [weak self] in
                UIView.animate(withDuration: 0.25) {
                    self?.loadingLabel.alpha = 0
                }
            }
            metalView.delegate = renderer
            self.renderer = renderer
        } catch {
            showFatal("Could not create the Blockfall save: \(error.localizedDescription)")
        }
    }

    deinit {
        gameView?.delegate = nil
        renderer?.shutdown()
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
