import SwiftUI
import UIKit
import AVFoundation
import ImageIO

/// Grid of everything shot in the app. Tapping an item opens it full-screen.
struct GalleryView: View {
    @ObservedObject var store = GalleryStore.shared
    @Environment(\.presentationMode) private var presentationMode
    @State private var selected: GalleryItem?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationView {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 46)).foregroundColor(.secondary)
                        Text("No shots yet").foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(store.items) { item in
                                Button { selected = item } label: {
                                    GalleryThumbnail(item: item)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(3)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Gallery").font(.headline) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .fullScreenCover(item: $selected) { item in
            MediaDetailView(item: item)
        }
    }
}

/// A single thumbnail. Photos load from disk; videos show a poster frame + badge.
private struct GalleryThumbnail: View {
    let item: GalleryItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.12))
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            }
            if item.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 3)
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .onAppear(perform: load)
    }

    private func load() {
        if image != nil { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Thumbnailer.thumbnail(for: item, maxPixel: 300)
            DispatchQueue.main.async { image = result }
        }
    }
}

/// Builds thumbnails off the main thread.
enum Thumbnailer {
    static func thumbnail(for item: GalleryItem, maxPixel: CGFloat) -> UIImage? {
        switch item.kind {
        case .photo:
            return downsampled(url: item.url, maxPixel: maxPixel)
        case .video:
            let asset = AVURLAsset(url: item.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
            let time = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cg)
            }
            return nil
        }
    }

    static func downsampled(url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
