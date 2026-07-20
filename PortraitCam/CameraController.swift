import AVFoundation
import CoreImage
import CoreMedia
import UIKit
import Photos
import Metal
import Combine

// MARK: - Settings types

enum VideoResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4k = "4K"
    var id: String { rawValue }
    var dimensions: CMVideoDimensions {
        switch self {
        case .hd720:  return CMVideoDimensions(width: 1280, height: 720)
        case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
        case .uhd4k:  return CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    var id: Int { rawValue }
}

enum TorchSetting: String, CaseIterable, Identifiable {
    case off = "Off"
    case on = "On"
    case auto = "Auto"
    var id: String { rawValue }
}

enum CaptureTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case three = 3
    case ten = 10
    var id: Int { rawValue }
    var label: String { self == .off ? "Off" : "\(rawValue)s" }
}

enum SubjectMode: String, CaseIterable, Identifiable {
    case people = "People"
    case anySubject = "Any subject"
    var id: String { rawValue }
}

/// Owns the capture session and drives the live portrait pipeline.
final class CameraController: NSObject, ObservableObject {

    enum CaptureMode: Hashable { case photo, video }

    // MARK: - Published UI state
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var captureMode: CaptureMode = .photo
    @Published var zoomFactor: CGFloat = 1.0
    @Published var cameraPosition: AVCaptureDevice.Position = .back
    @Published var lastThumbnail: UIImage?
    @Published var permissionDenied = false
    @Published var errorMessage: String?

    // Settings (applied via explicit apply* calls from the UI's onChange)
    @Published var resolution: VideoResolution = .hd1080
    @Published var frameRate: FrameRate = .fps30
    @Published var torch: TorchSetting = .off
    @Published var exposureBias: Float = 0.0
    @Published var mirrorFrontCamera: Bool = true

    // Blur the subject instead of the background (person blurred, background sharp).
    @Published var invertBlur: Bool = false
    // What the effect keeps sharp: any prominent subject (iOS 17+) or people only.
    @Published var subjectMode: SubjectMode = .anySubject
    // Transient status shown to the user (e.g. "Saved to Photos").
    @Published var statusMessage: String?

    @Published var quality: FrameProcessor.Quality = .balanced {
        didSet { videoQueue.async { self.processor.quality = self.quality } }
    }

    /// Blur is applied immediately (a plain scalar, safe to set cross-thread) so
    /// the next frame reflects the slider with no queue lag. 0 = no blur.
    func setBlur(_ amount: Double) {
        let clamped = min(max(amount, 0), 1)
        processor.blurRadius = CGFloat(clamped * 40.0)
    }

    func applyInvert() {
        videoQueue.async { self.processor.invert = self.invertBlur }
    }

    func applySubjectMode() {
        videoQueue.async { self.processor.subjectMode = self.subjectMode }
    }

    /// The Metal view that renders processed frames (owned here, shown via SwiftUI).
    let metalView = MetalCameraView()

    // MARK: - Capture stack
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "portraitcam.session")
    private let videoQueue = DispatchQueue(label: "portraitcam.video", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "portraitcam.writer", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var currentPosition: AVCaptureDevice.Position = .back

    private let processor = FrameProcessor()

    // Render-once: composite is rendered a single time per frame into a pooled
    // pixel buffer, then reused for both the live preview and the recording.
    private let renderContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private var bufferPool: CVPixelBufferPool?
    private var bufferPoolDims: (width: Int, height: Int) = (0, 0)
    private var videoDimensions = CGSize(width: 1080, height: 1920)   // videoQueue
    private var captureStillRequested = false                          // videoQueue

    // MARK: - Recording state (writerQueue-owned unless noted)
    private var recording = false      // also read on videoQueue
    private var finalizing = false     // also read on videoQueue
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingURL: URL?
    private var sessionStarted = false

    override init() {
        super.init()
        processor.quality = quality
        processor.blurRadius = 0
        processor.invert = invertBlur
        processor.subjectMode = subjectMode
    }

    // MARK: - Lifecycle

    func configureAndStart() {
        requestPhotoPermission()
        requestPermissions { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                self.configureSession()
                self.startSession()
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        func requestAudioThen(_ videoGranted: Bool) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in completion(videoGranted) }
            default:
                completion(videoGranted) // audio optional
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestAudioThen(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in requestAudioThen(granted) }
        default:
            completion(false)
        }
    }

    private func requestPhotoPermission() {
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
        }
    }

    // MARK: - Session setup

    private func configureSession() {
        session.beginConfiguration()
        // Defer to the device's activeFormat so we can pick resolution + fps.
        session.sessionPreset = .inputPriority

        if let device = wideCamera(for: currentPosition),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoDeviceInput = input
        }

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        configureVideoConnection()

        // Audio delegate runs on the writer queue so every AVAssetWriter call
        // (video append, audio append, finish) is serialized on one queue.
        audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        session.commitConfiguration()

        applyFormatInternal()
        applyContinuousFocusInternal()
        applyTorchInternal()
        applyExposureInternal()
        processor.mirror = (currentPosition == .front && mirrorFrontCamera)
        DispatchQueue.main.async { self.zoomFactor = 1.0 }
    }

    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false   // we mirror in Core Image instead
        }
    }

    private func wideCamera(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func startSession() {
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { self.isSessionRunning = self.session.isRunning }
    }

    // MARK: - Format / fps

    func applyCaptureFormat() {
        sessionQueue.async { self.applyFormatInternal() }
    }

    private func applyFormatInternal() { // sessionQueue
        guard let device = videoDeviceInput?.device else { return }
        let target = resolution.dimensions
        let desiredFPS = frameRate.rawValue

        func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        }
        func supports(_ fps: Int, _ f: AVCaptureDevice.Format) -> Bool {
            f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }
        }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }

        let exact = device.formats.filter {
            let d = dims($0); return d.width == target.width && d.height == target.height
        }

        var chosen: AVCaptureDevice.Format?
        var actualFPS = desiredFPS

        if !exact.isEmpty {
            if let f = exact.first(where: { supports(desiredFPS, $0) }) {
                chosen = f; actualFPS = desiredFPS
            } else if let f = exact.max(by: { maxFPS($0) < maxFPS($1) }) {
                chosen = f; actualFPS = Int(min(Double(desiredFPS), maxFPS(f)))
            }
        } else {
            let targetArea = Int(target.width) * Int(target.height)
            let sorted = device.formats.sorted {
                let a = dims($0), b = dims($1)
                return abs(Int(a.width) * Int(a.height) - targetArea) < abs(Int(b.width) * Int(b.height) - targetArea)
            }
            if let f = sorted.first(where: { supports(desiredFPS, $0) }) {
                chosen = f; actualFPS = desiredFPS
            } else if let f = sorted.first {
                chosen = f; actualFPS = Int(min(Double(desiredFPS), maxFPS(f)))
            }
        }

        guard let format = chosen else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(max(actualFPS, 1)))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            return
        }

        // Changing format resets zoom; reflect that and any fps fallback in the UI.
        DispatchQueue.main.async {
            self.zoomFactor = 1.0
            if let fr = FrameRate(rawValue: actualFPS), fr != self.frameRate { self.frameRate = fr }
        }
    }

    // MARK: - Focus (continuous + tap)

    private func applyContinuousFocusInternal() { // sessionQueue
        guard let device = videoDeviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch { }
    }

    /// Tap-to-focus/expose. `viewPoint` is in the preview's own coordinates.
    func focusAndExpose(atViewPoint viewPoint: CGPoint, viewSize: CGSize) {
        let devicePoint = devicePoint(fromViewPoint: viewPoint, viewSize: viewSize)
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    /// Return to continuous focus (e.g. long-press or after a tap timeout).
    func resumeContinuousFocus() {
        sessionQueue.async { self.applyContinuousFocusInternal() }
    }

    private func devicePoint(fromViewPoint viewPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = videoDimensions.width
        let imgH = videoDimensions.height
        guard imgW > 0, imgH > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        // The preview is aspect-filled; undo the fill crop to get normalized
        // coordinates within the portrait image.
        let scale = max(viewSize.width / imgW, viewSize.height / imgH)
        let dispW = imgW * scale
        let dispH = imgH * scale
        let offX = (dispW - viewSize.width) / 2
        let offY = (dispH - viewSize.height) / 2
        var nx = (viewPoint.x + offX) / dispW
        var ny = (viewPoint.y + offY) / dispH
        nx = min(max(nx, 0), 1)
        ny = min(max(ny, 0), 1)
        // Portrait video → device point-of-interest space (sensor is landscape).
        if currentPosition == .front {
            return CGPoint(x: ny, y: nx)
        }
        return CGPoint(x: ny, y: 1 - nx)
    }

    // MARK: - Torch

    func applyTorch() {
        sessionQueue.async { self.applyTorchInternal() }
    }

    private func applyTorchInternal() { // sessionQueue
        guard let device = videoDeviceInput?.device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            switch torch {
            case .off:
                if device.isTorchModeSupported(.off) { device.torchMode = .off }
            case .on:
                if device.isTorchModeSupported(.on) { try? device.setTorchModeOn(level: 1.0) }
            case .auto:
                if device.isTorchModeSupported(.auto) { device.torchMode = .auto }
            }
            device.unlockForConfiguration()
        } catch { }
    }

    // MARK: - Exposure bias

    func applyExposure() {
        sessionQueue.async { self.applyExposureInternal() }
    }

    private func applyExposureInternal() { // sessionQueue
        guard let device = videoDeviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, exposureBias))
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        } catch { }
    }

    // MARK: - Mirror

    func applyMirror() {
        videoQueue.async {
            self.processor.mirror = (self.currentPosition == .front && self.mirrorFrontCamera)
        }
    }

    // MARK: - Zoom

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.videoDeviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
                let clamped = max(device.minAvailableVideoZoomFactor, min(factor, maxZoom))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch { }
        }
    }

    func zoom(by scale: CGFloat, from base: CGFloat) {
        setZoom(base * scale)
    }

    // MARK: - Switch camera

    func switchCamera() {
        sessionQueue.async {
            let newPosition: AVCaptureDevice.Position = (self.currentPosition == .back) ? .front : .back
            guard let newDevice = self.wideCamera(for: newPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

            self.session.beginConfiguration()
            if let current = self.videoDeviceInput { self.session.removeInput(current) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoDeviceInput = newInput
                self.currentPosition = newPosition
            } else if let current = self.videoDeviceInput {
                self.session.addInput(current)
            }
            self.configureVideoConnection()
            self.session.commitConfiguration()

            self.applyFormatInternal()
            self.applyContinuousFocusInternal()
            self.applyTorchInternal()
            self.applyExposureInternal()
            self.processor.mirror = (self.currentPosition == .front && self.mirrorFrontCamera)
            DispatchQueue.main.async {
                self.cameraPosition = self.currentPosition
                self.zoomFactor = 1.0
            }
        }
    }

    // MARK: - Photo capture (saves exactly what is on screen)

    func capturePhoto() {
        videoQueue.async { self.captureStillRequested = true }
    }

    private func saveImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self?.statusMessage = "Enable Photos access in Settings to save." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, _ in
                DispatchQueue.main.async {
                    self?.statusMessage = success ? "Saved to Photos" : "Couldn't save the photo."
                }
            })
        }
    }

    // MARK: - Video recording

    func toggleRecording() {
        writerQueue.async {
            if self.finalizing { return }           // ignore taps mid-finalize
            if self.recording { self.finishRecording() } else { self.beginRecording() }
        }
    }

    private func beginRecording() { // writerQueue
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portraitcam-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let width = Int(videoDimensions.width)
        let height = Int(videoDimensions.height)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceAttributes
        )
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 96_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) { writer.add(audioInput) }

        assetWriter = writer
        videoWriterInput = videoInput
        audioWriterInput = audioInput
        pixelBufferAdaptor = adaptor
        recordingURL = url
        sessionStarted = false
        recording = true

        DispatchQueue.main.async { self.isRecording = true }
    }

    private func finishRecording() { // writerQueue
        guard recording, !finalizing else { return }
        recording = false
        finalizing = true
        // Flip the button back immediately; finalize in the background.
        DispatchQueue.main.async { self.isRecording = false }

        guard let writer = assetWriter else { finalizing = false; return }
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        let url = recordingURL

        if writer.status == .writing {
            writer.finishWriting { [weak self] in
                guard let self = self else { return }
                self.writerQueue.async {
                    self.cleanupWriter()
                    self.finalizing = false          // resume preview
                }
                if let url = url { self.saveVideo(url) }
            }
        } else {
            cleanupWriter()
            finalizing = false
        }
    }

    private func cleanupWriter() { // writerQueue
        assetWriter = nil
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        recordingURL = nil
        sessionStarted = false
    }

    private func appendRenderedFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) { // writerQueue
        guard recording,
              let writer = assetWriter,
              let adaptor = pixelBufferAdaptor,
              let input = videoWriterInput else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    private func saveVideo(_ url: URL) {
        // Move the recording into the in-app gallery, then export a copy to Photos.
        if let galleryURL = GalleryStore.shared.importVideo(from: url) {
            PhotoLibrary.save(videoURL: galleryURL) { [weak self] ok in
                self?.statusMessage = ok ? "Saved to Photos" : "Saved to gallery"
            }
        } else {
            PhotoLibrary.save(videoURL: url) { [weak self] ok in
                self?.statusMessage = ok ? "Saved to Photos" : "Couldn't save the video."
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Pixel buffer pool

    private func ensureBufferPool(width: Int, height: Int) { // videoQueue
        if bufferPool != nil && bufferPoolDims == (width, height) { return }
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                poolAttributes as CFDictionary,
                                pixelAttributes as CFDictionary,
                                &pool)
        bufferPool = pool
        bufferPoolDims = (width, height)
    }
}

// MARK: - Frame delegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)     // videoQueue
        } else if output === audioOutput {
            handleAudio(sampleBuffer)     // writerQueue
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) { // videoQueue
        // Drop frames while finalizing so the GPU is free to flush the encoder
        // quickly (this is what keeps "stop" instant instead of hanging).
        if finalizing { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        videoDimensions = CGSize(width: width, height: height)

        guard let composite = processor.process(pixelBuffer: pixelBuffer) else { return }

        // Serve a pending photo from the exact composite while the source buffer
        // is still valid (reliable capture == preview).
        if captureStillRequested {
            captureStillRequested = false
            if let cgImage = processor.makeCGImage(from: composite) {
                let displayImage = UIImage(cgImage: cgImage)
                let sharp = processor.sharpImage(pixelBuffer: pixelBuffer)
                let masterImage = processor.makeCGImage(from: sharp).map { UIImage(cgImage: $0) }
                DispatchQueue.main.async { self.lastThumbnail = displayImage }
                saveImage(displayImage)                                                     // to Photos
                GalleryStore.shared.savePhoto(display: displayImage, master: masterImage)   // in-app gallery
            }
        }

        // Render the composite once into a stable buffer (the source buffer is
        // valid here). The display-link view and the recorder both read it.
        guard let outBuffer = renderedBuffer(width: width, height: height) else { return }
        renderContext.render(composite, to: outBuffer)

        // Preview: hand the rendered buffer to the display-link-driven view.
        // No per-frame main-queue dispatch, so nothing piles up or stalls.
        metalView.updateImage(CIImage(cvPixelBuffer: outBuffer))

        // Recording: reuse the same rendered buffer — no second render.
        if recording {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writerQueue.async { self.appendRenderedFrame(outBuffer, at: time) }
        }
    }

    /// Allocate a BGRA buffer for the composite (pooled; standalone fallback).
    private func renderedBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        ensureBufferPool(width: width, height: height)
        var buffer: CVPixelBuffer?
        if let pool = bufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        }
        return buffer
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) { // writerQueue
        guard recording,
              sessionStarted,
              let writer = assetWriter, writer.status == .writing,
              let audioInput = audioWriterInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }
}
