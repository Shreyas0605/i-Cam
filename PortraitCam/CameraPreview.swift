import SwiftUI

/// Hosts the controller's live Metal preview inside SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> MetalCameraView {
        controller.metalView
    }

    func updateUIView(_ uiView: MetalCameraView, context: Context) {}
}
