import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import CoreVideo
import QuartzCore

/// Turns a raw camera frame into a portrait-composited image: a sharp subject
/// over a blurred background, using a segmentation mask from Vision. Works at
/// any zoom because it operates on the (already zoomed) image, not on hardware
/// depth data.
///
/// Performance model: segmentation (especially "Any subject", which uses the
/// heavy `VNGenerateForegroundInstanceMaskRequest`) is far too slow to run on
/// every frame. So it runs **asynchronously and throttled** on its own queue;
/// the latest result is cached. Every incoming frame re-applies the cheap blur
/// using the cached mask — so dragging the blur slider updates in real time even
/// while segmentation is catching up.
///
/// Subject detection:
/// - "Any subject" → `VNGenerateForegroundInstanceMaskRequest` (iOS 17+),
///   isolates prominent subjects (objects, animals, people). No instances → sharp.
/// - "People" (and the iOS < 17 fallback) → `VNGeneratePersonSegmentationRequest`.
///   An essentially-empty mask (no person in frame) is treated as no subject, so
///   the scene stays sharp instead of blurring everything.
final class FrameProcessor {

    enum Quality {
        case fast, balanced, accurate
        var vnLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .fast:     return .fast
            case .balanced: return .balanced
            case .accurate: return .accurate
            }
        }
    }

    /// Blur radius in points. 0 (or near-0) = no effect (segmentation skipped).
    var blurRadius: CGFloat = 0
    /// Horizontal mirror for the front camera.
    var mirror: Bool = false
    /// Blur the subject instead of the background (subject blurred, background sharp).
    var invert: Bool = false
    var quality: Quality = .balanced
    var subjectMode: SubjectMode = .anySubject

    private let personRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let clearColor = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    private let downsample: CGFloat = 0.5

    // Async, throttled segmentation state.
    private let segmentQueue = DispatchQueue(label: "portraitcam.segment", qos: .userInitiated)
    private let maskLock = NSLock()
    private var cachedMask: CIImage?        // scaled to base extent, NOT mirrored
    private var cachedMaskEmpty = true
    private var segmenting = false
    private var lastSegmentTime: CFTimeInterval = 0

    // MARK: - Live processing

    func process(pixelBuffer: CVPixelBuffer) -> CIImage? {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        let source = mirror ? mirrored(base) : base

        // Read once so a mid-frame slider change can't split the decision.
        let radius = blurRadius
        if radius < 1 {
            return source   // no blur → passthrough (fast, clean)
        }

        // Kick off segmentation in the background if it's time; never blocks here.
        scheduleMaskUpdate(pixelBuffer: pixelBuffer, baseExtent: base.extent)

        // Apply blur every frame using the latest cached mask (cheap → real-time).
        maskLock.lock()
        let maskOpt = cachedMaskEmpty ? nil : cachedMask
        maskLock.unlock()

        // No subject (yet, or none detected) → keep the whole frame sharp.
        guard var mask = maskOpt else { return source }
        if mirror { mask = mirrored(mask) }
        mask = mask.cropped(to: source.extent)

        let sigma = Double(radius)

        // Inverted mode: blur the subject, keep the background sharp.
        if invert {
            let fullBlur = downsampledBlur(source, sigma: sigma, extent: source.extent)
            let inverted = fullBlur.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: source,
                kCIInputMaskImageKey: mask
            ])
            return inverted.cropped(to: source.extent)
        }

        // Bleed-free background: remove the subject, blur, recomposite sharp subject.
        let clear = CIImage(color: clearColor).cropped(to: source.extent)
        let invMask = mask.applyingFilter("CIColorInvert")
        let backgroundOnly = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clear,
            kCIInputMaskImageKey: invMask
        ])
        let cleanBlur = downsampledBlur(backgroundOnly, sigma: sigma, extent: source.extent)
        let filledBackground = cleanBlur.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: source
        ])
        let result = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: filledBackground,
            kCIInputMaskImageKey: mask
        ])
        return result.cropped(to: source.extent)
    }

    // MARK: - Async masking

    /// Dispatch a segmentation pass at most every `interval` seconds, and only
    /// one at a time. The pixel buffer is retained for the duration.
    private func scheduleMaskUpdate(pixelBuffer: CVPixelBuffer, baseExtent: CGRect) {
        let now = CACurrentMediaTime()
        let interval: CFTimeInterval = (subjectMode == .anySubject) ? 0.20 : 0.05

        maskLock.lock()
        let shouldRun = !segmenting && (now - lastSegmentTime) >= interval
        if shouldRun { segmenting = true }
        maskLock.unlock()
        guard shouldRun else { return }

        let mode = subjectMode
        let level = quality
        segmentQueue.async { [weak self] in
            guard let self = self else { return }
            let (mask, empty) = self.buildMask(pixelBuffer: pixelBuffer, baseExtent: baseExtent,
                                               mode: mode, quality: level)
            self.maskLock.lock()
            self.cachedMask = mask
            self.cachedMaskEmpty = empty
            self.segmenting = false
            self.lastSegmentTime = CACurrentMediaTime()
            self.maskLock.unlock()
        }
    }

    /// Build a subject mask. Returns (mask, isEmpty). Runs on the segment queue.
    private func buildMask(pixelBuffer: CVPixelBuffer, baseExtent: CGRect,
                           mode: SubjectMode, quality: Quality) -> (CIImage?, Bool) {
        if mode == .anySubject, #available(iOS 17.0, *) {
            // Foreground request already returns nil when no instance is found.
            let mask = foregroundMask(pixelBuffer: pixelBuffer, baseExtent: baseExtent)
            return (mask, mask == nil)
        }
        guard let mask = personMask(pixelBuffer: pixelBuffer, baseExtent: baseExtent, quality: quality) else {
            return (nil, true)
        }
        // Person segmentation returns an all-black mask when no one is present;
        // treat near-empty coverage as "no subject" so we don't blur everything.
        return (mask, maskCoverage(mask) < 0.006)
    }

    private func personMask(pixelBuffer: CVPixelBuffer, baseExtent: CGRect, quality: Quality) -> CIImage? {
        personRequest.qualityLevel = quality.vnLevel
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([personRequest]) } catch { return nil }
        guard let observation = personRequest.results?.first else { return nil }
        let mask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        return scaled(mask, to: baseExtent)
    }

    @available(iOS 17.0, *)
    private func foregroundMask(pixelBuffer: CVPixelBuffer, baseExtent: CGRect) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        do {
            let maskBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            return scaled(CIImage(cvPixelBuffer: maskBuffer), to: baseExtent)
        } catch {
            return nil
        }
    }

    /// Average brightness of a mask (0…1) ≈ fraction of the frame it covers.
    private func maskCoverage(_ mask: CIImage) -> CGFloat {
        let extent = mask.extent
        guard extent.width > 0, extent.height > 0 else { return 0 }
        let average = mask.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        return CGFloat(pixel[0]) / 255.0
    }

    private func scaled(_ mask: CIImage, to extent: CGRect) -> CIImage {
        guard mask.extent.width > 0, mask.extent.height > 0 else { return mask }
        if mask.extent.width == extent.width && mask.extent.height == extent.height {
            return mask
        }
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    // MARK: - Helpers

    /// Blur a half-resolution copy and scale back up — visually identical for
    /// background blur, far cheaper, so the preview stays fluid under load.
    private func downsampledBlur(_ image: CIImage, sigma: Double, extent: CGRect) -> CIImage {
        let small = image.transformed(by: CGAffineTransform(scaleX: downsample, y: downsample))
        let blurred = small
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma * Double(downsample))
        let restored = blurred.transformed(by: CGAffineTransform(scaleX: 1 / downsample, y: 1 / downsample))
        return restored.cropped(to: extent)
    }

    private func mirrored(_ image: CIImage) -> CIImage {
        image
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: image.extent.width, y: 0))
    }

    // MARK: - Still export

    func makeCGImage(from image: CIImage) -> CGImage? {
        ciContext.createCGImage(image, from: image.extent)
    }

    /// The sharp source (mirror applied for the front camera), with no blur —
    /// saved as the editable master at capture time.
    func sharpImage(pixelBuffer: CVPixelBuffer) -> CIImage {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        return mirror ? mirrored(base) : base
    }
}
