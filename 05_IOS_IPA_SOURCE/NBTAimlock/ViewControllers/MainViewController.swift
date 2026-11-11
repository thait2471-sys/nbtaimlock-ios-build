import UIKit
import SwiftUI

public final class MainViewController: UIViewController {

    private var hostingController: UIHostingController<NativeAppView>?

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 6/255.0, green: 9/255.0, blue: 19/255.0, alpha: 1.0)

        // 1. Verify runtime security environment
        let securityStatus = NABATISecurity.shared.checkSecurityEnvironment()
        if !securityStatus.isSecure {
            print("[NABATISecurity] Warnings: \(securityStatus.warnings.joined(separator: ", "))")
        }

        // 2. Embed 100% Native SwiftUI Interface (Zero HTML, Pure Native UI)
        setupNativeSwiftUIInterface()
    }

    override public var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    private func setupNativeSwiftUIInterface() {
        let nativeView = NativeAppView()
        let host = UIHostingController(rootView: nativeView)
        host.view.backgroundColor = .clear

        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        self.hostingController = host
    }
}
