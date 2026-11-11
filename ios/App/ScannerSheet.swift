import AVFoundation
import SwiftUI
import TouchyClient
import VisionKit

/// Scans the pairing code from inside the app. The system Camera works too:
/// the code is a `touchytua://` link that opens the app.
struct ScannerSheet: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss
    /// Nil while the system is asking.
    @State private var cameraAllowed: Bool?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !DataScannerViewController.isSupported {
                message("This device can't scan codes here. Open the Camera app and point it at the code instead.")
            } else if cameraAllowed == true {
                QRScanner { code in
                    dismiss()
                    Task { await connection.pair(url: code) }
                }
                .ignoresSafeArea()
            } else if cameraAllowed == false {
                message("Camera access is off. Turn it on in Settings, or scan the code with the Camera app.")
            } else {
                ProgressView()
            }
        }
        .task { cameraAllowed = await AVCaptureDevice.requestAccess(for: .video) }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(17))
            .foregroundStyle(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(32)
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var reported = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in added {
                guard !reported, case let .barcode(code) = item,
                      let text = code.payloadStringValue, text.hasPrefix("touchytua://") else { continue }
                reported = true
                onCode(text)
            }
        }
    }
}
