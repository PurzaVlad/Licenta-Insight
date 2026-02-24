import UIKit
import React
import React_RCTAppDelegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

    let rootView = appDelegate.rootViewFactory.view(
      withModuleName: appDelegate.moduleName ?? "Identity",
      initialProperties: appDelegate.initialProps,
      launchOptions: nil
    )
    let rootViewController = appDelegate.createRootViewController()
    appDelegate.setRootView(rootView, toRootViewController: rootViewController)

    let window = UIWindow(windowScene: windowScene)
    let baseBackground = UIColor.systemGroupedBackground
    rootView.backgroundColor = baseBackground
    rootViewController?.view.backgroundColor = baseBackground
    window.backgroundColor = baseBackground
    window.tintColor = UIColor(named: "Primary")
    window.rootViewController = rootViewController
    self.window = window
    window.makeKeyAndVisible()
  }
}
