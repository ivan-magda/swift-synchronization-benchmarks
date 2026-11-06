import UIKit

/// UIKit owns the view, display loop and buffers until completion publishes a snapshot.
@MainActor final class ScrollingScreen: NSObject, UICollectionViewDataSource {
    struct Observation: Sendable {
        let frames: Int
        let reads: Int
        let violations: Int
        let overflow: Bool
    }

    let collectionView: UICollectionView
    var recordingReads = false
    private let images: CacheImages
    private let tunables: MainThreadCacheTunables
    private let read: @MainActor (String) -> CachedImage?
    private let readTimes: CallTimes
    private let frameStarts: CallTimes
    private let frameIntervals: CallTimes
    private let readCapacity: Int
    private var reads = 0
    private var violations = 0
    private var overflow = false
    private var frames = 0
    private var loop: DisplayLinkLoop?
    private var maximumFramesPerSecond = 60

    init(
        images: CacheImages, tunables: MainThreadCacheTunables, readCapacity: Int,
        read: @escaping @MainActor (String) -> CachedImage?
    ) {
        self.images = images
        self.tunables = tunables
        self.readCapacity = readCapacity
        self.read = read
        readTimes = CallTimes(calls: readCapacity)
        frameStarts = CallTimes(calls: tunables.frames)
        frameIntervals = CallTimes(calls: tunables.frames)
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        collectionView.dataSource = self
        collectionView.register(ImageCell.self, forCellWithReuseIdentifier: "image")
    }

    /// The bound covers traversed rows, visible cells and a generous prefetch margin.
    static func readCapacity(tunables: MainThreadCacheTunables, size: CGSize) -> Int {
        let cellSide = max(1, size.width / 4)
        let distance = Double(tunables.warmupFrames + tunables.frames)
            * Double(tunables.scrollPointsPerSecond) / 60
        let traversedRows = Int(ceil(distance / Double(cellSide)))
        let visibleRows = Int(ceil(Double(size.height / cellSide)))
        return (traversedRows + visibleRows + 64) * 16
    }

    func install(in view: UIView, maximumFramesPerSecond: Int) {
        self.maximumFramesPerSecond = maximumFramesPerSecond
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let layout = collectionView.collectionViewLayout as! UICollectionViewFlowLayout
        let side = max(1, view.bounds.width / 4)
        layout.itemSize = CGSize(width: side, height: side)
        view.addSubview(collectionView)
        collectionView.layoutIfNeeded()
    }

    func start(finished: @escaping @Sendable () -> Void) {
        let loop = DisplayLinkLoop(frames: tunables.warmupFrames + tunables.frames) { [self] frame, link in
            recordingReads = frame >= tunables.warmupFrames
            if recordingReads {
                frameStarts.record(call: frames, ticks: Clock.now())
                frameIntervals.record(
                    call: frames,
                    ticks: UInt64(max(0, (link.targetTimestamp - link.timestamp) * 1_000_000_000))
                )
                frames += 1
            }
            let distance = CGFloat(tunables.scrollPointsPerSecond) / CGFloat(maximumFramesPerSecond)
            let maximum = max(0, collectionView.contentSize.height - collectionView.bounds.height)
            let offset = collectionView.contentOffset.y + distance
            collectionView.contentOffset.y = offset > maximum ? 0 : offset
            collectionView.layoutIfNeeded()
        }
        self.loop = loop
        loop.start(finished: finished)
    }

    func stopAndRemove() {
        recordingReads = false
        loop?.stop()
        loop = nil
        collectionView.removeFromSuperview()
    }

    var observation: Observation {
        Observation(frames: frames, reads: reads, violations: violations, overflow: overflow)
    }

    var samples: [(String, String, [UInt64])] {
        [
            ("readTime", "ticks", Array(readTimes.values.prefix(min(reads, readCapacity)))),
            ("frameStart", "ticks", frameStarts.values),
            ("frameInterval", "nanoseconds", frameIntervals.values),
        ]
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        10_000
    }

    @inline(never)
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "image", for: indexPath) as! ImageCell
        let key = images.keys[indexPath.item % images.keys.count]
        let start = Clock.now()
        let entry = read(key)
        let end = Clock.now()
        if recordingReads {
            if reads < readCapacity {
                readTimes.record(call: reads, ticks: end - start)
            } else {
                overflow = true
            }
            reads += 1
            if let entry, images.images.indices.contains(entry.imageIndex),
                entry.image === images.images[entry.imageIndex] {
                // The image identity validates the complete entry after the timed lookup.
            } else {
                violations += 1
            }
        }
        cell.imageView.image = entry?.image
        return cell
    }
}

@MainActor private final class ImageCell: UICollectionViewCell {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("No storyboard cells") }
}
