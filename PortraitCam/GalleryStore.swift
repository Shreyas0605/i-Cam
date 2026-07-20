import UIKit
import Combine
import Photos

/// One item in the in-app gallery. `url` is the display file (JPEG photo or MP4
/// video). `masterURL` is the sharp, un-blurred original kept for re-editing
/// (photos only).
struct GalleryItem: Identifiable, Equatable {
    enum Kind { case photo, video }
    let id: String
    let kind: Kind
    let url: URL
    let masterURL: URL?
    let date: Date

    static func == (lhs: GalleryItem, rhs: GalleryItem) -> Bool { lhs.id == rhs.id }
}

/// Stores the app's own copies of everything shot in the app, in the sandbox
/// Documents directory. No photo-library permission needed to read these back.
final class GalleryStore: ObservableObject {
    static let shared = GalleryStore()

    @Published private(set) var items: [GalleryItem] = []

    private let root: URL
    private let ioQueue = DispatchQueue(label: "portraitcam.gallery")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("PortraitCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        ioQueue.async {
            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(at: self.root,
                                                    includingPropertiesForKeys: [.creationDateKey])) ?? []
            var result: [GalleryItem] = []
            for url in urls {
                let name = url.lastPathComponent
                if name.hasSuffix(".master.jpg") { continue }   // masters aren't shown directly
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if name.hasSuffix(".jpg") {
                    let id = String(name.dropLast(4))
                    let master = self.root.appendingPathComponent(id + ".master.jpg")
                    let masterURL = fm.fileExists(atPath: master.path) ? master : nil
                    result.append(GalleryItem(id: id, kind: .photo, url: url, masterURL: masterURL, date: date))
                } else if name.hasSuffix(".mp4") {
                    let id = String(name.dropLast(4))
                    result.append(GalleryItem(id: id, kind: .video, url: url, masterURL: nil, date: date))
                }
            }
            result.sort { $0.date > $1.date }
            DispatchQueue.main.async { self.items = result }
        }
    }

    /// Save a captured photo: `display` is the shot as seen; `master` is the
    /// sharp original for editing.
    func savePhoto(display: UIImage, master: UIImage?) {
        ioQueue.async {
            let id = self.newID()
            if let data = display.jpegData(compressionQuality: 0.95) {
                try? data.write(to: self.root.appendingPathComponent(id + ".jpg"))
            }
            if let master = master, let data = master.jpegData(compressionQuality: 0.95) {
                try? data.write(to: self.root.appendingPathComponent(id + ".master.jpg"))
            }
            self.reload()
        }
    }

    /// Move a freshly recorded temp video into the gallery. Returns the new
    /// permanent URL (so the caller can also copy it to Photos).
    @discardableResult
    func importVideo(from tempURL: URL) -> URL? {
        let id = newID()
        let dest = root.appendingPathComponent(id + ".mp4")
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            return nil
        }
        reload()
        return dest
    }

    /// Overwrite a photo's display file with an edited version (keeps the master).
    func updatePhoto(_ item: GalleryItem, with image: UIImage) {
        ioQueue.async {
            if let data = image.jpegData(compressionQuality: 0.95) {
                try? data.write(to: item.url)
            }
            self.reload()
        }
    }

    func delete(_ item: GalleryItem) {
        ioQueue.async {
            try? FileManager.default.removeItem(at: item.url)
            if let master = item.masterURL { try? FileManager.default.removeItem(at: master) }
            self.reload()
        }
    }

    private func newID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date()) + "-" + String(Int.random(in: 1000...9999))
    }
}

/// Small helper for exporting edited media to the system Photos library.
enum PhotoLibrary {
    static func save(image: UIImage, completion: @escaping (Bool) -> Void) {
        guard let data = image.jpegData(compressionQuality: 0.95) else { completion(false); return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }; return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { ok, _ in DispatchQueue.main.async { completion(ok) } })
        }
    }

    static func save(videoURL: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }; return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: videoURL, options: nil)
            }, completionHandler: { ok, _ in DispatchQueue.main.async { completion(ok) } })
        }
    }
}
