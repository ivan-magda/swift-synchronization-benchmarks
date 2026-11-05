import CryptoKit
import Foundation
import Testing

@testable import SyncBench

@Test func writerOutputMatchesGoldenFile() throws {
    #expect(
        GoldenAttempt.lines().data
            == (try Data(contentsOf: fixtureURL("golden-base-comparison.jsonl")))
    )
}

@Test func doneMarkerDescribesTheFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let lines = GoldenAttempt.lines()
    let marker = try ResultWriter.write(
        lines,
        attemptID: RunRequest.golden.attemptID,
        to: directory
    )
    let file = try Data(contentsOf: directory.appending(path: marker.file))
    let fileHash = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()

    #expect(file == lines.data)
    #expect(marker.attemptID == RunRequest.golden.attemptID)
    #expect(marker.file == "golden.one-thread.1.attempt1.20261105T000000Z.0000.jsonl")
    #expect(marker.bytes == file.count)
    #expect(marker.sha256 == fileHash)

    let done = try Data(
        contentsOf: directory.appending(path: RunRequest.golden.attemptID + ".done")
    )
    #expect(try JSONDecoder().decode(DoneMarker.self, from: done) == marker)
    #expect(lines.lineCounts == ["run": 1, "reference": 2, "block": 1, "batch": 3, "end": 1])
}

@Test(arguments: [
    "../escape", "/absolute", "a/b", "a\\b", "", String(repeating: "a", count: 129)
])
func writerRejectsUnsafeAttemptIDs(_ attemptID: String) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: RequestError.self) {
        try ResultWriter.write(
            GoldenAttempt.lines(),
            attemptID: attemptID,
            to: directory
        )
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
