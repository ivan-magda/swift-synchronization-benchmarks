@MainActor final class MainActorImageCache {
    private var images: [String: CachedImage] = [:]

    nonisolated init() {}

    func image(for key: String) -> CachedImage? {
        images[key]
    }

    func store(_ entry: CachedImage, for key: String) {
        images[key] = entry
    }
}
