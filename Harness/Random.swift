/// SplitMix64 gives a reproducible stream for a run's seeded block order.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Fisher–Yates, using one generator value for each position from the end.
func seededShuffle<Element>(_ items: [Element], seed: UInt64) -> [Element] {
    guard items.count > 1 else { return items }
    var shuffled = items
    var generator = SplitMix64(seed: seed)
    for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
        shuffled.swapAt(index, Int(generator.next() % UInt64(index + 1)))
    }
    return shuffled
}
