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
        window?.rootViewController as? GameViewController
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = GameViewController()
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
