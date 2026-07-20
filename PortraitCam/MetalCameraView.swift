import MetalKit
import CoreImage

/// A Metal view that renders the latest camera frame, aspect-filled and centered.
///
/// It runs on its own display link (`isPaused = false`) and *pulls* the most
/// recent image each refresh, instead of being pushed a redraw per frame. This
/// keeps the preview updating smoothly and continuously even when the main
/// thread is busy — so blur changes show in real time and never "stick".
final class MetalCameraView: MTKView {

    private let imageLock = NSLock()
    private var latestImage: CIImage?

    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private let renderColorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        if device == nil { device = MTLCreateSystemDefaultDevice() }
        configure()
    }

    /// Thread-safe: called from the camera's video queue for every frame.
    func updateImage(_ image: CIImage?) {
        imageLock.lock()
        latestImage = image
        imageLock.unlock()
    }

    private func currentImage() -> CIImage? {
        imageLock.lock()
        let image = latestImage
        imageLock.unlock()
        return image
    }

    private func configure() {
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        isOpaque = true
        backgroundColor = .black
        // Display-link driven: redraw continuously, pull the latest frame.
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 30
        autoResizeDrawable = true
        presentsWithTransaction = false
        contentMode = .scaleAspectFill
        if let device = device {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device)
        }
        delegate = self
    }
}

extension MetalCameraView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let image = currentImage(),
              let drawable = currentDrawable,
              let commandQueue = commandQueue,
              let ciContext = ciContext,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let dw = drawableSize.width
        let dh = drawableSize.height
        let iw = image.extent.width
        let ih = image.extent.height
        guard dw > 0, dh > 0, iw > 0, ih > 0 else { return }

        // Aspect-fill the image into the drawable and center it.
        let scale = max(dw / iw, dh / ih)
        let tx = (dw - iw * scale) / 2.0
        let ty = (dh - ih * scale) / 2.0

        let rendered = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX * scale + tx,
                                               y: -image.extent.minY * scale + ty))

        let destination = CGRect(x: 0, y: 0, width: dw, height: dh)
        ciContext.render(rendered,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: destination,
                         colorSpace: renderColorSpace)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
