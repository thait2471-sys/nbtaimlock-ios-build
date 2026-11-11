import UIKit
import SwiftUI

public final class MainViewController: UIViewController {

    private var hostingController: UIHostingController<NativeAppView>?

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 6/255.0, green: 9/255.0, blue: 19/255.0, alpha: 1.0)

        // 1. Verify runtime security environment.
        //
        // Hard tamper evidence (rewritten bundle id, injected dylib) locks the
        // app before any KEY is accepted; NABATICore re-checks on every unlock
        // because a debugger can attach after launch. Jailbreak heuristics are
        // logged only — they false-positive on ordinary devices, and the server
        // remains the authority on whether the KEY is valid.
        let securityStatus = NABATISecurity.shared.checkSecurityEnvironment()
        if securityStatus.isTampered {
            print("[NABATISecurity] TAMPERED: \(securityStatus.warnings.joined(separator: ", "))")
        } else if !securityStatus.isSecure {
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
