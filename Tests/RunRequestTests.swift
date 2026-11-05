import Foundation
import Testing

@testable import SyncBench

@Test func splitMix64GivesKnownValues() {
    var generator = SplitMix64(seed: 0)

    #expect(generator.next() == 0xE220_A839_7B1D_CDAF)
    #expect(generator.next() == 0x6E78_9E6A_A1B9_65F4)
    #expect(generator.next() == 0x06C4_5D18_8009_454F)
}

@Test func seededShuffleGivesFixedOrder() {
    #expect(seededShuffle(Array(0..<10), seed: 42) == [0, 9, 5, 8, 6, 4, 7, 2, 1, 3])
    #expect(seededShuffle(["a", "b", "c", "d", "e"], seed: 7) == ["e", "b", "d", "a", "c"])
    #expect(seededShuffle([Int](), seed: 7).isEmpty)
    #expect(seededShuffle([1], seed: 7) == [1])
}

@Test func requestRoundTripsThroughLaunchArguments() throws {
    let request = RunRequest.golden
    let argument = try JSONEncoder().encode(request).base64EncodedString()

    #expect(
        try RunRequest.decode(launchArguments: ["SyncBench", "--bench-request", argument])
            == request
    )
    #expect(try RunRequest.decode(launchArguments: ["SyncBench"]) == nil)
}

@Test(arguments: [
    ["--bench-request"],
    ["--bench-request", "!"],
    ["--bench-request", "e30="]
])
func malformedRequestArgumentsThrow(_ arguments: [String]) {
    #expect(throws: RequestError.self) {
        try RunRequest.decode(launchArguments: arguments)
    }
}

@Test(arguments: InvalidRequestCase.all)
func invalidRequestNamesTheField(_ invalidCase: InvalidRequestCase) {
    let error = #expect(throws: RequestError.self) {
        try invalidCase.request.validate()
    }

    #expect(error?.message.contains(invalidCase.field) == true)
}

@Test func decodePreservesInvalidRequestForFailureResult() throws {
    var request = RunRequest.golden
    request.schema = 2
    let argument = try JSONEncoder().encode(request).base64EncodedString()

    #expect(try RunRequest.decode(launchArguments: ["--bench-request", argument]) == request)
}

@Test func requestAcceptsSpecifiedBoundariesAndMechanismOverrides() throws {
    var request = RunRequest.golden
    request.runID = String(repeating: "a", count: 128)
    request.attemptID = "._-0Az"
    request.seed = (1 << 53) - 1
    request.tunables.threads = 64
    request.tunables.warmupBatches = 0
    request.tunables.operationsPerBatch = ["default": 8, "actor": 4]

    try request.validate()

    #expect(request.operationsPerBatch(for: "actor") == 4)
    #expect(request.operationsPerBatch(for: "mutex") == 8)
}
