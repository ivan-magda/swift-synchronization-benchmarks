/// Concrete specializations remain identifiable in Release disassembly.
enum BaseComparisonLoops {
    @inline(never)
    static func readLoop<Integer: SharedInteger>(
        _ integer: Integer,
        count: Int
    ) -> Int {
        var sum = 0
        for _ in 0..<count {
            sum += integer.read()
        }
        return sum
    }

    @inline(never)
    static func writeLoop<Integer: SharedInteger>(
        _ integer: Integer,
        count: Int,
        firstValue: Int
    ) {
        for operation in 0..<count {
            integer.write(firstValue + operation)
        }
    }

    @inline(never)
    static func incrementLoop<Integer: SharedInteger>(
        _ integer: Integer,
        count: Int
    ) {
        for _ in 0..<count {
            integer.increment()
        }
    }

    @inline(never)
    static func readLoopAsync<Integer: AsyncSharedInteger>(
        _ integer: Integer,
        count: Int
    ) async -> Int {
        var sum = 0
        for _ in 0..<count {
            sum += await integer.read()
        }
        return sum
    }

    @inline(never)
    static func writeLoopAsync<Integer: AsyncSharedInteger>(
        _ integer: Integer,
        count: Int,
        firstValue: Int
    ) async {
        for operation in 0..<count {
            await integer.write(firstValue + operation)
        }
    }

    @inline(never)
    static func incrementLoopAsync<Integer: AsyncSharedInteger>(
        _ integer: Integer,
        count: Int
    ) async {
        for _ in 0..<count {
            await integer.increment()
        }
    }
}
