struct Record: Sendable {
    var version: Int
    var value: Int
}

struct GroupRead: Sendable {
    let version: Int
    let sum: Int
    let versionsMatch: Bool
}

protocol RecordStore: AnyObject, Sendable {
    func readGroup(_ group: Int) -> GroupRead
    func writeGroup(_ group: Int, endTimes: CallTimes, slot: Int)
    func waitForPendingWrites()
}

extension RecordStore {
    func waitForPendingWrites() {}
}

extension Array where Element == Record {
    func readGroup(_ group: Int, size: Int) -> GroupRead {
        let first = group * size
        let version = self[first].version
        var sum = 0
        var versionsMatch = true
        for index in first..<(first + size) {
            let record = self[index]
            sum += record.value
            if record.version != version { versionsMatch = false }
        }
        return GroupRead(version: version, sum: sum, versionsMatch: versionsMatch)
    }

    mutating func writeGroup(_ group: Int, size: Int) {
        let first = group * size
        let version = self[first].version + 1
        for index in first..<(first + size) {
            self[index] = Record(version: version, value: version)
        }
    }
}
