import Foundation
import SwiftUI
import UIKit
import React

@objc(NativeChatViewManager)
class NativeChatViewManager: RCTViewManager {

    override static func requiresMainQueueSetup() -> Bool {
        true
    }

    override func view() -> UIView! {
        let hosting = UIHostingController(rootView: NativeChatView())
        hosting.view.backgroundColor = UIColor.clear
        return hosting.view
    }
    
    override class func moduleName() -> String! {
        return "NativeChatView"
    }
}
