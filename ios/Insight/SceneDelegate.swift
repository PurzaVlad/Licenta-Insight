import UIKit
import React
import React_RCTAppDelegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var privacyShieldView: UIView?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

    let rootView = appDelegate.rootViewFactory.view(
      withModuleName: appDelegate.moduleName ?? "Insight",
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

  func sceneWillResignActive(_ scene: UIScene) {
    guard shouldProtectSnapshot(), let window else { return }
    if privacyShieldView == nil {
      let shield = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
      shield.frame = window.bounds
      shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      privacyShieldView = shield
    }
    if let privacyShieldView, privacyShieldView.superview == nil {
      window.addSubview(privacyShieldView)
    }
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    privacyShieldView?.removeFromSuperview()
  }

  private func shouldProtectSnapshot() -> Bool {
    let useFaceID = UserDefaults.standard.bool(forKey: AppConstants.UserDefaultsKeys.useFaceID)
    return useFaceID || KeychainService.passcodeExists()
  }
}
