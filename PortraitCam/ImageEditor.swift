import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Post-capture editor for a portrait photo.
///
/// - Refocus: pick which detected subject stays sharp (the rest is blurred),
///   like the iOS Photos portrait editor. Uses per-instance segmentation
///   (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+).
/// - Remove: erase a tapped object and fill the hole by diffusion inpainting.
///   This is a basic fill (great on clean backgrounds, soft on busy ones) —
///   there is no public generative-erase API on-device.
final class ImageEditor: ObservableObject {

    enum Mode { case focus, remove }

    @Published var displayImage: UIImage
    @Published var isProcessing = false
    @Published var isReady = false
    @Published var mode: Mode = .focus
    @Published var supportsSubjects: Bool
    @Published var blur: Double = 0.6 {
        didSet { if mode == .focus { rerender() } }
    }

    private let ciContext = CIContext()
    private let originalCI: CIImage        // sharp master
    private var workingCI: CIImage         // master with any removals applied
    private var focusedInstances: [Int] = []

    private var observation: Any?          // VNInstanceMaskObservation (iOS 17+)
    private var handler: VNImageRequestHandler?
    private let clearColor = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    private let downsample: CGFloat = 0.5

    init(master: UIImage) {
        displayImage = master
        let ci = CIImage(image: master) ?? CIImage.empty()
        originalCI = ci
        workingCI = ci
        if #available(iOS 17.0, *) { supportsSubjects = true } else { supportsSubjects = false }

        guard let cg = master.cgImage else { isReady = true; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.prepareSegmentation(cg)
        }
    }

    // MARK: - Setup

    private func prepareSegmentation(_ cg: CGImage) {
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        self.handler = handler
        if #available(iOS 17.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            do {
                try handler.perform([request])
                observation = request.results?.first
            } catch {
                observation = nil
            }
        }
        DispatchQueue.main.async { self.isReady = true }
    }

    // MARK: - Tap handling

    func handleTap(atNormalized point: CGPoint) {
        guard isReady else { return }
        if #available(iOS 17.0, *) {
            let index = instanceIndex(atNormalized: point)
            guard index > 0 else { return }   // 0 = background
            if mode == .focus {
                focusedInstances = [index]
                rerender()
            } else {
                removeInstance(index)
            }
        }
    }

    func reset() {
        workingCI = originalCI
        focusedInstances = []
        displayImage = image(from: originalCI)
    }

    func currentImage() -> UIImage { displayImage }

    // MARK: - Instance helpers (iOS 17+)

    @available(iOS 17.0, *)
    private func instanceIndex(atNormalized point: CGPoint) -> Int {
        guard let obs = observation as? VNInstanceMaskObservation else { return 0 }
        let mask = obs.instanceMask
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask), width > 0, height > 0 else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        let px = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let py = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
        let pixel = base.advanced(by: py * bytesPerRow + px).assumingMemoryBound(to: UInt8.self)
        return Int(pixel.pointee)
    }

    @available(iOS 17.0, *)
    private func instanceMaskImage(for indices: IndexSet) -> CIImage? {
        guard let obs = observation as? VNInstanceMaskObservation, let handler = handler,
              !indices.isEmpty else { return nil }
        do {
            let buffer = try obs.generateScaledMaskForImage(forInstances: indices, from: handler)
            return scaled(CIImage(cvPixelBuffer: buffer), to: workingCI.extent)
        } catch {
            return nil
        }
    }

    // MARK: - Rendering

    private func rerender() {
        guard #available(iOS 17.0, *) else { return }
        isProcessing = true
        let radius = CGFloat(blur * 40)
        let indices = makeIndexSet(focusedInstances)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let output: CIImage
            if self.focusedInstances.isEmpty || radius < 1 {
                output = self.workingCI
            } else if let mask = self.instanceMaskImage(for: indices) {
                output = self.composePortrait(base: self.workingCI, mask: mask, sigma: Double(radius))
            } else {
                output = self.workingCI
            }
            let ui = self.image(from: output)
            DispatchQueue.main.async {
                self.displayImage = ui
                self.isProcessing = false
            }
        }
    }

    @available(iOS 17.0, *)
    private func removeInstance(_ index: Int) {
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let mask = self.instanceMaskImage(for: IndexSet(integer: index)) else {
                DispatchQueue.main.async { self?.isProcessing = false }
                return
            }
            let dilated = mask
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 6.0])
                .cropped(to: self.workingCI.extent)
            self.workingCI = self.inpaint(self.workingCI, holeMask: dilated)

            // Re-apply focus blur over the newly cleaned image if a subject is selected.
            let radius = CGFloat(self.blur * 40)
            let output: CIImage
            if !self.focusedInstances.isEmpty, radius >= 1,
               let focusMask = self.instanceMaskImage(for: self.makeIndexSet(self.focusedInstances)) {
                output = self.composePortrait(base: self.workingCI, mask: focusMask, sigma: Double(radius))
            } else {
                output = self.workingCI
            }
            let ui = self.image(from: output)
            DispatchQueue.main.async {
                self.displayImage = ui
                self.isProcessing = false
            }
        }
    }

    private func makeIndexSet(_ values: [Int]) -> IndexSet {
        var set = IndexSet()
        for value in values { set.insert(value) }
        return set
    }

    // MARK: - Core Image

    private func composePortrait(base: CIImage, mask: CIImage, sigma: Double) -> CIImage {
        let clear = CIImage(color: clearColor).cropped(to: base.extent)
        let invMask = mask.applyingFilter("CIColorInvert")
        let backgroundOnly = base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: invMask
        ])
        let blurred = downsampledBlur(backgroundOnly, sigma: sigma, extent: base.extent)
        let filled = blurred.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: base
        ])
        return base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: filled,
            kCIInputMaskImageKey: mask
        ]).cropped(to: base.extent)
    }

    /// Diffusion inpaint: repeatedly blur and restore the known region so the
    /// hole fills with surrounding colours.
    private func inpaint(_ image: CIImage, holeMask: CIImage, iterations: Int = 16, sigma: Double = 9) -> CIImage {
        let keepMask = holeMask.applyingFilter("CIColorInvert")
        var current = image
        for _ in 0..<iterations {
            let blurred = current
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: image.extent)
            current = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: keepMask
            ])
        }
        return current.cropped(to: image.extent)
    }

    private func downsampledBlur(_ image: CIImage, sigma: Double, extent: CGRect) -> CIImage {
        let small = image.transformed(by: CGAffineTransform(scaleX: downsample, y: downsample))
        let blurred = small
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma * Double(downsample))
        return blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / downsample, y: 1 / downsample))
            .cropped(to: extent)
    }

    private func scaled(_ mask: CIImage, to extent: CGRect) -> CIImage {
        guard mask.extent.width > 0, mask.extent.height > 0 else { return mask }
        if mask.extent.width == extent.width && mask.extent.height == extent.height { return mask }
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    private func image(from ci: CIImage) -> UIImage {
        if let cg = ciContext.createCGImage(ci, from: ci.extent) {
            return UIImage(cgImage: cg)
        }
        return displayImage
    }
}
