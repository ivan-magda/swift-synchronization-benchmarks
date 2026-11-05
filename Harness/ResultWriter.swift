import CryptoKit
import Foundation

/// Encodes lines between blocks; only the run thread may append.
final class ResultLineBuffer: @unchecked Sendable {
    private(set) var data = Data()
    private(set) var lineCounts: [String: Int] = [:]

    /// Harness line types must encode as JSON objects with a string `type` key.
    func append<Line: Encodable>(_ line: Line) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        do {
            let encoded = try encoder.encode(line)
            let header = try JSONDecoder().decode(LineHeader.self, from: encoded)
            data.append(encoded)
            data.append(0x0A)
            lineCounts[header.type, default: 0] += 1
        } catch {
            preconditionFailure("Result line must be JSON encodable with a type: \(error)")
        }
    }

    private struct LineHeader: Decodable {
        let type: String
    }
}

struct DoneMarker: Codable, Equatable, Sendable {
    let attemptID: String
    let file: String
    let bytes: Int
    let sha256: String
}

enum ResultWriter {
    /// Publish the result atomically before publishing its completion marker.
    static func write(
        _ lines: ResultLineBuffer,
        attemptID: String,
        to directory: URL
    ) throws -> DoneMarker {
        guard RunRequest.isValidIdentifier(attemptID) else {
            throw RequestError(message: "attemptID cannot be used as a result filename")
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let filename = attemptID + ".jsonl"
        let markerURL = directory.appending(path: attemptID + ".done")

        // A retry with the same ID must never leave an older completion marker
        // describing a new file if publication is interrupted.
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }

        try lines.data.write(to: directory.appending(path: filename), options: .atomic)

        let checksum = SHA256.hash(data: lines.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let marker = DoneMarker(
            attemptID: attemptID,
            file: filename,
            bytes: lines.data.count,
            sha256: checksum
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)

        return marker
    }
}
