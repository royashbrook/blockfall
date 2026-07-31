import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Blockfall", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private var gameViewController: GameViewController? {
        (window?.rootViewController as? BlockfallRootViewController)?.currentGame
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = BlockfallRootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        gameViewController?.handleSceneDidBecomeActive()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        gameViewController?.handleSceneWillResignActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        gameViewController?.handleSceneDidEnterBackground()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        gameViewController?.handleSceneDidDisconnect()
    }
}

/// Owns the iPad shell so changing worlds never requires restarting the app.
final class BlockfallRootViewController: UIViewController {
    private(set) var currentGame: GameViewController?
    private var currentChild: UIViewController?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidLoad() {
        super.viewDidLoad()
        showWorldMenu()
    }

    private func showWorldMenu() {
        currentGame = nil
        let menu = WorldMenuViewController()
        menu.onPlay = { [weak self] saveDir, fresh, seed in
            self?.showGame(saveDir: saveDir, fresh: fresh, seed: seed)
        }
        replaceChild(with: menu)
    }

    private func showGame(saveDir: URL, fresh: Bool, seed: UInt64) {
        let game = GameViewController(saveDir: saveDir, freshWorld: fresh, worldSeed: seed)
        game.onExitToWorlds = { [weak self] in self?.showWorldMenu() }
        currentGame = game
        replaceChild(with: game)
        if view.window?.windowScene?.activationState == .foregroundActive {
            game.handleSceneDidBecomeActive()
        }
    }

    private func replaceChild(with child: UIViewController) {
        currentChild?.willMove(toParent: nil)
        currentChild?.view.removeFromSuperview()
        currentChild?.removeFromParent()
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
        currentChild = child
    }
}

private struct WorldInfo {
    let name: String
    let saveDir: URL
    let modified: Date
}

/// A kid-readable world picker with explicit create, restart, and delete actions.
final class WorldMenuViewController: UIViewController {
    var onPlay: ((URL, Bool, UInt64) -> Void)?

    private let worldsStack = UIStackView()
    private let emptyLabel = UILabel()

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        reloadWorlds()
    }

    private func buildUI() {
        view.backgroundColor = UIColor(red: 0.055, green: 0.075, blue: 0.12, alpha: 1)

        let title = UILabel()
        title.text = "BLOCKFALL"
        title.textColor = UIColor(red: 1, green: 0.78, blue: 0.30, alpha: 1)
        title.font = .systemFont(ofSize: 44, weight: .black)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Choose a world"
        subtitle.textColor = UIColor.white.withAlphaComponent(0.78)
        subtitle.font = .systemFont(ofSize: 20, weight: .semibold)
        subtitle.textAlignment = .center

        let newWorld = makeButton("＋  New World", color: .systemGreen)
        newWorld.addTarget(self, action: #selector(newWorldTapped), for: .touchUpInside)
        newWorld.widthAnchor.constraint(equalToConstant: 240).isActive = true
        newWorld.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true

        worldsStack.axis = .vertical
        worldsStack.spacing = 10
        worldsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(worldsStack)

        emptyLabel.text = "No worlds yet. Make one and start exploring!"
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        emptyLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [title, subtitle, newWorld])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(scroll)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 20),
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -18),
            scroll.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 760),
            worldsStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            worldsStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            worldsStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            worldsStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            worldsStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    private func reloadWorlds() {
        worldsStack.arrangedSubviews.forEach {
            worldsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let worlds = (try? Self.loadWorlds()) ?? []
        emptyLabel.removeFromSuperview()
        if worlds.isEmpty {
            worldsStack.addArrangedSubview(emptyLabel)
            emptyLabel.heightAnchor.constraint(equalToConstant: 80).isActive = true
            return
        }
        worlds.forEach { worldsStack.addArrangedSubview(makeWorldRow($0)) }
    }

    private func makeWorldRow(_ world: WorldInfo) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 0.98)
        card.layer.cornerRadius = 16
        card.layer.borderWidth = 2
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor

        let name = UILabel()
        name.text = world.name
        name.textColor = .white
        name.font = .systemFont(ofSize: 21, weight: .bold)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let play = makeButton("Play", color: .systemGreen)
        play.addAction(UIAction { [weak self] _ in self?.onPlay?(world.saveDir, false, 0) }, for: .touchUpInside)
        let restart = makeButton("Restart", color: .systemOrange)
        restart.addAction(UIAction { [weak self] _ in self?.confirmRestart(world) }, for: .touchUpInside)
        let delete = makeButton("Delete", color: .systemRed)
        delete.addAction(UIAction { [weak self] _ in self?.confirmDelete(world) }, for: .touchUpInside)
        [play, restart, delete].forEach { $0.widthAnchor.constraint(equalToConstant: 112).isActive = true }

        let row = UIStackView(arrangedSubviews: [name, play, restart, delete])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 72),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    @objc private func newWorldTapped() {
        let alert = UIAlertController(title: "New World", message: "Give it a name. A seed is optional.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "World name" }
        alert.addTextField {
            $0.placeholder = "Seed (optional)"
            $0.keyboardType = .numbersAndPunctuation
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            let requested = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = requested.isEmpty ? Self.nextWorldName() : requested
            do {
                let dir = try Self.uniqueWorldDirectory(named: name)
                self.onPlay?(dir, true, Self.seed(from: fields[1].text ?? ""))
            } catch {
                self.showError(error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func confirmRestart(_ world: WorldInfo) {
        confirm(
            title: "Restart \"\(world.name)\"?",
            message: "This erases this world's progress and generates it again with a new seed.",
            destructiveTitle: "Restart"
        ) { [weak self] in
            do {
                try FileManager.default.removeItem(at: world.saveDir)
                try Self.prepareDirectory(world.saveDir)
                self?.onPlay?(world.saveDir, true, UInt64.random(in: 1...UInt64.max))
            } catch { self?.showError(error.localizedDescription) }
        }
    }

    private func confirmDelete(_ world: WorldInfo) {
        confirm(
            title: "Delete \"\(world.name)\"?",
            message: "This world and everything built in it will be gone forever.",
            destructiveTitle: "Delete"
        ) { [weak self] in
            do {
                try FileManager.default.removeItem(at: world.saveDir)
                self?.reloadWorlds()
            } catch { self?.showError(error.localizedDescription) }
        }
    }

    private func confirm(title: String, message: String, destructiveTitle: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep It", style: .cancel))
        alert.addAction(UIAlertAction(title: destructiveTitle, style: .destructive) { _ in action() })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Could not change worlds", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func makeButton(_ title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = color
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 17, weight: .bold)
            return outgoing
        }
        button.configuration = config
        return button
    }

    private static func worldsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let worlds = base.appendingPathComponent("Blockfall/Worlds", isDirectory: true)
        try prepareDirectory(worlds)
        return worlds
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func loadWorlds() throws -> [WorldInfo] {
        let root = try worldsDirectory()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true else { return nil }
            return WorldInfo(
                name: url.lastPathComponent,
                saveDir: url,
                modified: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.modified > $1.modified }
    }

    private static func nextWorldName() -> String {
        let names = (try? loadWorlds().map(\.name)) ?? []
        var number = names.count + 1
        while names.contains("World \(number)") { number += 1 }
        return "World \(number)"
    }

    private static func uniqueWorldDirectory(named requested: String) throws -> URL {
        let safe = requested
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = safe.isEmpty ? nextWorldName() : String(safe.prefix(48))
        let root = try worldsDirectory()
        var candidate = root.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try prepareDirectory(candidate)
        return candidate
    }

    private static func seed(from raw: String) -> UInt64 {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return UInt64.random(in: 1...UInt64.max) }
        if let numeric = UInt64(value) { return numeric }
        return value.utf8.reduce(UInt64(1469598103934665603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }
}
