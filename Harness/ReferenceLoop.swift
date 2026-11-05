/// Fixed CPU work used to observe frequency drift between the ends of a run.
@inline(never)
func referenceLoop(iterations: Int) -> UInt64 {
    var value: UInt64 = 0x9E37_79B9_7F4A_7C15

    for _ in 0..<iterations {
        value ^= value << 13
        value ^= value >> 7
        value ^= value << 17
    }

    return value
}
