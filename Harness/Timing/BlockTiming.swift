extension BatchLayout {
    var operationsPerWorker: Int { totalBatches * operationsPerBatch }
}

extension Array where Element == ThreadLog {
    func checkValues(batches: Int) -> [[Int]] {
        map { log in
            (0..<batches).map { log.checkValue(ofBatch: $0) }
        }
    }
}
