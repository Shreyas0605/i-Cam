import SwiftUI
import UIKit
import AVKit

/// Full-screen viewer for one gallery item, with Edit / Save / Delete.
struct MediaDetailView: View {
    let item: GalleryItem
    @Environment(\.presentationMode) private var presentationMode

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var showEditor = false
    @State private var confirmDelete = false
    @State private var status: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.kind == .photo {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                        .onAppear { player.play() }
                }
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let status = status {
                Text(status)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 70)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $showEditor) {
            if let master = item.masterURL {
                PortraitEditorView(item: item, masterURL: master)
            }
        }
        .alert(isPresented: $confirmDelete) {
            Alert(
                title: Text("Delete this shot?"),
                message: Text("This removes it from the app gallery."),
                primaryButton: .destructive(Text("Delete")) {
                    GalleryStore.shared.delete(item)
                    presentationMode.wrappedValue.dismiss()
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var topBar: some View {
        HStack {
            circle("xmark") { presentationMode.wrappedValue.dismiss() }
            Spacer()
            circle("trash") { confirmDelete = true }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if item.kind == .photo, item.masterURL != nil {
                actionButton("Edit", system: "slider.horizontal.3") { showEditor = true }
            }
            actionButton("Save to Photos", system: "square.and.arrow.down") { saveToPhotos() }
        }
    }

    private func circle(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func actionButton(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func load() {
        switch item.kind {
        case .photo:
            DispatchQueue.global(qos: .userInitiated).async {
                let img = Thumbnailer.downsampled(url: item.url, maxPixel: 2400)
                    ?? UIImage(contentsOfFile: item.url.path)
                DispatchQueue.main.async { image = img }
            }
        case .video:
            player = AVPlayer(url: item.url)
        }
    }

    private func saveToPhotos() {
        switch item.kind {
        case .photo:
            let img = image ?? UIImage(contentsOfFile: item.url.path)
            guard let img = img else { return }
            PhotoLibrary.save(image: img) { ok in flash(ok ? "Saved to Photos" : "Couldn't save") }
        case .video:
            PhotoLibrary.save(videoURL: item.url) { ok in flash(ok ? "Saved to Photos" : "Couldn't save") }
        }
    }

    private func flash(_ message: String) {
        withAnimation { status = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { status = nil } }
    }
}
