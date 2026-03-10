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

  // Always protect — document content must never appear in the app switcher
  // regardless of whether the user has configured a passcode or Face ID.
  private func shouldProtectSnapshot() -> Bool {
    return true
  }

  // MARK: - Jailbreak Detection

  private var jailbreakWarningShown = false

  func sceneDidBecomeActive(_ scene: UIScene) {
    privacyShieldView?.removeFromSuperview()
    if !jailbreakWarningShown && isDeviceJailbroken() {
      jailbreakWarningShown = true
      showJailbreakWarning()
    }
  }

  private func showJailbreakWarning() {
    guard let rootVC = window?.rootViewController else { return }
    let alert = UIAlertController(
      title: "Security Warning",
      message: "This device appears to be jailbroken. Insight's passcode and biometric protections cannot be fully guaranteed on a jailbroken device. Your documents may be accessible to other apps or users with physical device access.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "I Understand", style: .default))
    rootVC.present(alert, animated: true)
  }

  /// Detects common jailbreak indicators. Intentionally conservative —
  /// false positives are better than false negatives for a security check.
  /// NOTE: No jailbreak detection is foolproof; a sophisticated attacker
  /// can bypass file-based checks using hooks. App Attest (requires Apple
  /// Developer account) provides stronger attestation before publishing.
  private func isDeviceJailbroken() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    let suspiciousPaths = [
      "/Applications/Cydia.app",
      "/Library/MobileSubstrate/MobileSubstrate.dylib",
      "/bin/bash",
      "/usr/sbin/sshd",
      "/etc/apt",
      "/usr/bin/ssh",
      "/private/var/lib/apt",
    ]
    for path in suspiciousPaths where FileManager.default.fileExists(atPath: path) {
      return true
    }
    // Attempt a write outside the app sandbox — this succeeds only on jailbroken devices
    let testPath = "/private/jb_probe_\(UUID().uuidString)"
    do {
      try "x".write(toFile: testPath, atomically: true, encoding: .utf8)
      try? FileManager.default.removeItem(atPath: testPath)
      return true
    } catch {}
    return false
    #endif
  }
}
