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
        HostingContainerView(rootView: TabContainerView().environmentObject(AuthService.shared))
    }
    
    override class func moduleName() -> String! {
        return "NativeChatView"
    }
}

private final class HostingContainerView<Content: View>: UIView {
    private let hostingController: UIHostingController<Content>
    private weak var attachedParentViewController: UIViewController?

    init(rootView: Content) {
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(frame: UIScreen.main.bounds)

        hostingController.view.backgroundColor = UIColor.systemGroupedBackground
        hostingController.view.frame = bounds
        hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(hostingController.view)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detachHostingController()
        } else {
            attachHostingControllerIfNeeded()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        attachHostingControllerIfNeeded()
    }

    private func attachHostingControllerIfNeeded() {
        guard attachedParentViewController == nil else { return }
        guard let parentViewController = nearestViewController() else { return }
        parentViewController.addChild(hostingController)
        hostingController.didMove(toParent: parentViewController)
        attachedParentViewController = parentViewController
    }

    private func detachHostingController() {
        guard attachedParentViewController != nil else { return }
        hostingController.willMove(toParent: nil)
        hostingController.removeFromParent()
        attachedParentViewController = nil
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
