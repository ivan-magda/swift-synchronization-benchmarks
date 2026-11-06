import UIKit

struct CachedImage: Sendable {
    let image: UIImage
    let imageIndex: Int
}

protocol ImageCache: AnyObject, Sendable {
    func image(for key: String) -> CachedImage?
    func store(_ entry: CachedImage, for key: String)
    func waitForPendingWrites()
}

struct CacheImages: Sendable {
    let images: [UIImage]
    let keys: [String]

    @MainActor init() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        images = (0..<64).map { index in
            renderer.image { context in
                UIColor(hue: CGFloat(index) / 64, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        }
        keys = (0..<1_000).map { String(format: "https://images.example.com/photos/%04d.jpg", $0) }
    }

    func entry(_ index: Int) -> CachedImage {
        CachedImage(image: images[index], imageIndex: index)
    }
}

extension ImageCache {
    func waitForPendingWrites() {}
}
