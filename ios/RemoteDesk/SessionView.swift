import SwiftUI
import UIKit

struct SessionView: UIViewControllerRepresentable {
    let host: String
    let port: UInt16
    let pin: String
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> SessionViewController {
        let vc = SessionViewController(host: host, port: port, pin: pin)
        vc.onClose = onClose
        return vc
    }

    func updateUIViewController(_ uiViewController: SessionViewController, context: Context) {
        uiViewController.onClose = onClose
    }
}
