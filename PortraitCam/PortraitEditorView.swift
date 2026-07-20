import SwiftUI
import UIKit

/// Post-capture portrait editor: tap a subject to refocus, or tap an object to
/// remove it. Backed by `ImageEditor`.
struct PortraitEditorView: View {
    let item: GalleryItem
    let masterURL: URL
    @Environment(\.presentationMode) private var presentationMode

    @StateObject private var editor: ImageEditor
    @State private var tapRing: CGPoint?
    @State private var status: String?

    init(item: GalleryItem, masterURL: URL) {
        self.item = item
        self.masterURL = masterURL
        let master = UIImage(contentsOfFile: masterURL.path) ?? UIImage()
        _editor = StateObject(wrappedValue: ImageEditor(master: master))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                Image(uiImage: editor.displayImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleTap(value.location, translation: value.translation,
                                          container: geo.size)
                            }
                    )
            }
            .ignoresSafeArea()

            if let ring = tapRing {
                Circle().stroke(Color.yellow, lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .position(ring)
                    .allowsHitTesting(false)
            }

            if editor.isProcessing || !editor.isReady {
                ProgressView().tint(.white).scaleEffect(1.3)
            }

            VStack {
                topBar
                Spacer()
                if !editor.supportsSubjects { iosNote }
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)

            if let status = status {
                Text(status)
                    .font(.subheadline.weight(.medium)).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 70)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                .foregroundColor(.white)
            Spacer()
            Button("Reset") { editor.reset() }
                .foregroundColor(.white)
                .disabled(!editor.supportsSubjects)
        }
        .padding(.vertical, 8)
    }

    private var iosNote: some View {
        Text("Subject refocus and object removal need iOS 17 or later. You can still view and export this photo.")
            .font(.footnote)
            .foregroundColor(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: $editor.mode) {
                Text("Focus").tag(ImageEditor.Mode.focus)
                Text("Remove").tag(ImageEditor.Mode.remove)
            }
            .pickerStyle(.segmented)
            .disabled(!editor.supportsSubjects)

            Text(editor.mode == .focus
                 ? "Tap the subject you want in focus."
                 : "Tap an object to remove it (works best on clean backgrounds).")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.75))

            if editor.mode == .focus {
                HStack(spacing: 12) {
                    Image(systemName: "camera.aperture").foregroundColor(.white.opacity(0.9))
                    Slider(value: $editor.blur, in: 0...1).tint(.yellow)
                        .disabled(!editor.supportsSubjects)
                    Image(systemName: "camera.aperture").font(.system(size: 22)).foregroundColor(.white)
                }
            }

            HStack(spacing: 14) {
                actionButton("Save", system: "checkmark") { save() }
                actionButton("Export to Photos", system: "square.and.arrow.down") { exportToPhotos() }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func actionButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Actions

    private func handleTap(_ point: CGPoint, translation: CGSize, container: CGSize) {
        guard editor.supportsSubjects else { return }
        if hypot(translation.width, translation.height) > 12 { return }

        let imageSize = editor.displayImage.size
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return }

        // Map the tap into the aspect-fit image rect → normalized (top-left).
        let imgAspect = imageSize.width / imageSize.height
        let contAspect = container.width / container.height
        var dispW = container.width
        var dispH = container.height
        if imgAspect > contAspect { dispH = container.width / imgAspect }
        else { dispW = container.height * imgAspect }
        let offX = (container.width - dispW) / 2
        let offY = (container.height - dispH) / 2
        let lx = point.x - offX
        let ly = point.y - offY
        guard lx >= 0, ly >= 0, lx <= dispW, ly <= dispH else { return }

        tapRing = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if tapRing == point { withAnimation { tapRing = nil } }
        }
        editor.handleTap(atNormalized: CGPoint(x: lx / dispW, y: ly / dispH))
    }

    private func save() {
        GalleryStore.shared.updatePhoto(item, with: editor.currentImage())
        flash("Saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func exportToPhotos() {
        PhotoLibrary.save(image: editor.currentImage()) { ok in
            flash(ok ? "Exported to Photos" : "Couldn't export")
        }
    }

    private func flash(_ message: String) {
        withAnimation { status = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { status = nil } }
    }
}
