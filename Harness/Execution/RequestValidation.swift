extension RunRequest {
    /// Throws when a list is empty, has duplicates, or contains a value outside its allowlist.
    func requireUniqueSelection(
        mechanisms allowed: Set<String>?,
        operations allowedOperations: Set<String>?
    ) throws(RequestError) {
        guard !mechanisms.isEmpty,
            Set(mechanisms).count == mechanisms.count
        else {
            throw RequestError(message: "mechanisms must be nonempty and unique")
        }

        if let allowed, !mechanisms.allSatisfy(allowed.contains) {
            throw RequestError(message: "mechanisms contains an unknown value")
        }

        guard !operations.isEmpty,
            Set(operations).count == operations.count
        else {
            throw RequestError(message: "operations must be nonempty and unique")
        }

        if let allowedOperations, !operations.allSatisfy(allowedOperations.contains) {
            throw RequestError(message: "operations contains an unknown value")
        }
    }

    func validatedLayout(operationsPerBatch: Int, threads: Int) throws(RequestError) -> BatchLayout {
        let layout = BatchLayout(
            warmupBatches: tunables.warmupBatches,
            measuredBatches: tunables.measuredBatches,
            operationsPerBatch: operationsPerBatch,
            subBatches: tunables.subBatches
        )
        try layout.validate(threads: threads)
        return layout
    }
}
