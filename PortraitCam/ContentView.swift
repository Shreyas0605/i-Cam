import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraController()

    @State private var pinchBase: CGFloat = 1.0
    @State private var activeSheet: ActiveSheet?
    @State private var showGrid = false
    @State private var captureTimer: CaptureTimer = .off
    @State private var countdown: Int?
    @State private var countdownTimer: Timer?
    @State private var focusPoint: CGPoint?
    @State private var focusID = 0

    private let zoomPresets: [CGFloat] = [1, 2, 5]

    private enum ActiveSheet: Identifiable {
        case settings, gallery
        var id: Int { hashValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.permissionDenied {
                PermissionView()
            } else {
                CameraPreview(controller: camera)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in camera.zoom(by: value, from: pinchBase) }
                            .onEnded { _ in pinchBase = camera.zoomFactor }
                            .simultaneously(with:
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in handleTap(at: value.location, translation: value.translation) }
                            )
                    )

                if showGrid { GridOverlay().ignoresSafeArea().allowsHitTesting(false) }

                if let point = focusPoint {
                    FocusSquare().position(point).allowsHitTesting(false)
                }

                controls

                if let count = countdown {
                    Text("\(count)")
                        .font(.system(size: 96, weight: .thin, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(radius: 8)
                        .allowsHitTesting(false)
                }

                if let message = camera.statusMessage {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 60)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            camera.configureAndStart()
            pinchBase = camera.zoomFactor
        }
        .onDisappear {
            camera.stop()
            countdownTimer?.invalidate()
        }
        .statusBar(hidden: true)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(camera: camera, showGrid: $showGrid, captureTimer: $captureTimer)
            case .gallery:
                GalleryView()
            }
        }
        .onChange(of: camera.statusMessage) { message in
            guard message != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { camera.statusMessage = nil }
            }
        }
    }

    // MARK: - Gestures

    private func handleTap(at point: CGPoint, translation: CGSize) {
        // Treat only near-stationary touches as taps (ignore swipes / pinch ends).
        if hypot(translation.width, translation.height) > 12 { return }
        focusPoint = point
        focusID += 1
        let currentID = focusID
        camera.focusAndExpose(atViewPoint: point, viewSize: UIScreen.main.bounds.size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if focusID == currentID { withAnimation { focusPoint = nil } }
        }
    }

    // MARK: - Photo timer

    private func startCapture() {
        countdownTimer?.invalidate()
        if captureTimer == .off {
            camera.capturePhoto()
            return
        }
        countdown = captureTimer.rawValue
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard let value = countdown else { timer.invalidate(); return }
            if value <= 1 {
                timer.invalidate()
                countdown = nil
                camera.capturePhoto()
            } else {
                countdown = value - 1
            }
        }
    }

    // MARK: - Controls overlay

    private var controls: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomStack
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private var topBar: some View {
        HStack {
            circleButton(system: "gearshape.fill") { activeSheet = .settings }
            Spacer()
            if camera.isRecording {
                recordingBadge
                Spacer()
            }
            circleButton(system: "arrow.triangle.2.circlepath.camera") {
                camera.switchCamera()
                pinchBase = 1.0
            }
        }
    }

    private var bottomStack: some View {
        VStack(spacing: 18) {
            zoomPills
            BlurSliderBar { camera.setBlur($0) }
            modePicker
            actionRow
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("REC").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var zoomPills: some View {
        HStack(spacing: 10) {
            ForEach(zoomPresets, id: \.self) { preset in
                let active = abs(camera.zoomFactor - preset) < 0.15
                Button {
                    camera.setZoom(preset)
                    pinchBase = preset
                } label: {
                    Text(active ? String(format: "%.1f×", Double(camera.zoomFactor)) : "\(Int(preset))×")
                        .font(.system(size: active ? 15 : 13, weight: .semibold))
                        .foregroundColor(active ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $camera.captureMode) {
            Text("Photo").tag(CameraController.CaptureMode.photo)
            Text("Video").tag(CameraController.CaptureMode.video)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
    }

    private var actionRow: some View {
        HStack {
            thumbnail
            Spacer()
            shutterButton
            Spacer()
            Color.clear.frame(width: 56, height: 56)
        }
    }

    private var thumbnail: some View {
        Button { activeSheet = .gallery } label: {
            if let image = camera.lastThumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    )
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var shutterButton: some View {
        Button {
            if camera.captureMode == .photo {
                startCapture()
            } else {
                camera.toggleRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                if camera.captureMode == .photo {
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                } else {
                    RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 31, style: .continuous)
                        .fill(Color.red)
                        .frame(width: camera.isRecording ? 34 : 62,
                               height: camera.isRecording ? 34 : 62)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
        .animation(.easeInOut(duration: 0.2), value: camera.captureMode)
    }

    private func circleButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Blur slider (isolated so dragging doesn't re-render the whole screen)

private struct BlurSliderBar: View {
    let onChange: (Double) -> Void
    @State private var value: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").foregroundColor(.white.opacity(0.9))
            Slider(value: $value, in: 0...1)
                .tint(.yellow)
                .onChange(of: value) { onChange($0) }
            Image(systemName: "camera.aperture").font(.system(size: 22)).foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Focus square

private struct FocusSquare: View {
    @State private var scale: CGFloat = 1.3
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 74, height: 74)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) { scale = 1.0 }
            }
            .transition(.opacity)
    }
}

// MARK: - Rule-of-thirds grid

private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

// MARK: - Settings sheet

private struct SettingsSheet: View {
    @ObservedObject var camera: CameraController
    @Binding var showGrid: Bool
    @Binding var captureTimer: CaptureTimer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { presentationMode.wrappedValue.dismiss() }
                    .font(.body.weight(.semibold))
            }
            .padding()

            Form {
                Section("Video") {
                    Picker("Resolution", selection: $camera.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: camera.resolution) { _ in camera.applyCaptureFormat() }

                    Picker("Frame Rate", selection: $camera.frameRate) {
                        ForEach(FrameRate.allCases) { Text("\($0.rawValue) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: camera.frameRate) { _ in camera.applyCaptureFormat() }
                }

                Section("Portrait") {
                    Picker("Detect", selection: $camera.subjectMode) {
                        ForEach(SubjectMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: camera.subjectMode) { _ in camera.applySubjectMode() }

                    Toggle("Invert (blur subject, keep background sharp)", isOn: $camera.invertBlur)
                        .onChange(of: camera.invertBlur) { _ in camera.applyInvert() }

                    Text("“Any subject” isolates people, objects or animals (iOS 17+). “People” detects people only. If nothing is detected the scene stays sharp. Tap-to-focus controls the lens focus/exposure, not which part is blurred.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Camera") {
                    Picker("Flash", selection: $camera.torch) {
                        ForEach(TorchSetting.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: camera.torch) { _ in camera.applyTorch() }

                    VStack(alignment: .leading) {
                        Text(String(format: "Exposure  %+.1f EV", Double(camera.exposureBias)))
                            .font(.subheadline)
                        Slider(value: $camera.exposureBias, in: -2...2, step: 0.1)
                            .onChange(of: camera.exposureBias) { _ in camera.applyExposure() }
                    }

                    Toggle("Mirror Front Camera", isOn: $camera.mirrorFrontCamera)
                        .onChange(of: camera.mirrorFrontCamera) { _ in camera.applyMirror() }
                }

                Section("Composition") {
                    Toggle("Grid", isOn: $showGrid)
                    Picker("Timer", selection: $captureTimer) {
                        ForEach(CaptureTimer.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("Higher resolution and frame rate capture at full quality, but the live portrait effect is limited by how fast on-device segmentation runs. For the smoothest preview, use 1080p / 30 fps.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Permission prompt

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.85))
            Text("Camera Access Needed")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
            Text("PortraitCam needs camera access to show the live portrait preview. Enable it in Settings.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.headline)
                    .foregroundColor(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}
