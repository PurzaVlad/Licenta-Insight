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
        HostingContainerView(rootView: TabContainerView())
    }
    
    override class func moduleName() -> String! {
        return "NativeChatView"
    }
}

private final class HostingContainerView<Content: View>: UIView {
    private let hostingController: UIHostingController<Content>

    init(rootView: Content) {
        self.hostingController = UIHostingController(rootView: rootView)
        super.init(frame: .zero)

        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
