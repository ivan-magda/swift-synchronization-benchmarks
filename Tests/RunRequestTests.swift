import Foundation
import Testing

@testable import SyncBench

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

@Test func requestWithNewTunablesRoundTrips() throws {
    var request = RunRequest.golden
    request.traced = true
    request.tunables.asyncCode = AsyncCodeTunables(callsPerTask: 20, warmupCallsPerTask: 2)
    request.tunables.priorityInversion = PriorityInversionTunables(
        holderWorkIterations: 10_000,
        loadQoS: .userInitiated,
        loadMilliseconds: 20,
        mainDelayMicroseconds: 1_000,
        pauseMilliseconds: 5,
        warmupTrials: 1,
        trials: 3
    )
    let encoded = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(RunRequest.self, from: encoded) == request)
}
