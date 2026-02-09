import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

@main
class AppDelegate: RCTAppDelegate {
  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    self.moduleName = "Identity"
    self.dependencyProvider = RCTAppDependencyProvider()
    self.automaticallyLoadReactNativeWindow = false

    // Ensure standard iOS horizontal margins for nav bar titles and bar buttons.

    // Configure Tab Bar to be completely transparent
    let tabBarAppearance = UITabBarAppearance()
    tabBarAppearance.configureWithTransparentBackground()
    tabBarAppearance.backgroundEffect = nil
    tabBarAppearance.backgroundColor = .clear
    tabBarAppearance.shadowColor = .clear
    tabBarAppearance.shadowImage = nil

    let tabBar = UITabBar.appearance()
    tabBar.standardAppearance = tabBarAppearance
    tabBar.scrollEdgeAppearance = tabBarAppearance
    tabBar.isTranslucent = true
    tabBar.backgroundColor = .clear
    
    // Configure Navigation Bar to be completely transparent
    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navBarAppearance.backgroundEffect = nil
    navBarAppearance.backgroundColor = .clear
    navBarAppearance.shadowColor = .clear
    navBarAppearance.shadowImage = nil
    
    let navBar = UINavigationBar.appearance()
    navBar.standardAppearance = navBarAppearance
    navBar.compactAppearance = navBarAppearance
    navBar.scrollEdgeAppearance = navBarAppearance
    navBar.compactScrollEdgeAppearance = navBarAppearance
    navBar.isTranslucent = true
    navBar.preservesSuperviewLayoutMargins = true
    navBar.insetsLayoutMarginsFromSafeArea = true
    navBar.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

    // You can add your custom initial props in the dictionary below.
    // They will be passed down to the ViewController used by React Native.
    self.initialProps = [:]

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }

  override func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}
