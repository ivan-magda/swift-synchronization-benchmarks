import Darwin

/// Allocator-reported blocks and bytes in all zones. Xzone can include cache-local
/// free slots; these are neither exact live-object nor allocation-event counts.
enum MallocStatistics {
    static func read() -> (blocks: UInt64, bytes: UInt64) {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return (UInt64(statistics.blocks_in_use), UInt64(statistics.size_in_use))
    }
}

extension MallocStatistics {
    private struct LiveCount {
        var blocks: UInt64 = 0
        var failed = false
    }

    /// Enumerate allocated pointers, excluding xzone's cached free slots. Use the
    /// supported self-reader without manually locking zones: Nano enumeration may
    /// allocate and free a scratch bitmap through its helper zone. Our callbacks
    /// allocate nothing. Concurrent framework activity can still change the heap.
    static func liveBlocks() -> UInt64? {
        let task = mach_task_self_
        let reader: @convention(c) (task_t, vm_address_t, vm_size_t,
                                    UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t = { remoteTask, address, _, memory in
            guard remoteTask == mach_task_self_, let memory,
                  let pointer = UnsafeMutableRawPointer(bitPattern: address) else {
                return KERN_INVALID_ARGUMENT
            }
            memory.pointee = pointer
            return KERN_SUCCESS
        }
        let recorder: @convention(c) (task_t, UnsafeMutableRawPointer?, UInt32,
                                      UnsafeMutablePointer<vm_range_t>?, UInt32) -> Void = { _, context, type, ranges, count in
            guard type & UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE) != 0, let context else { return }
            let total = context.assumingMemoryBound(to: LiveCount.self)
            guard count == 0 || ranges != nil else {
                total.pointee.failed = true
                return
            }
            let (blocks, overflow) = total.pointee.blocks.addingReportingOverflow(UInt64(count))
            total.pointee.blocks = blocks
            total.pointee.failed = total.pointee.failed || overflow
        }
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        guard malloc_get_all_zones(task, reader, &addresses, &zoneCount) == KERN_SUCCESS,
              let addresses, zoneCount > 0 else { return nil }
        var total = LiveCount()
        let succeeded = withUnsafeMutablePointer(to: &total) { total in
            for index in 0..<Int(zoneCount) {
                let address = addresses[index]
                guard let zone = UnsafePointer<malloc_zone_t>(bitPattern: address),
                      let introspection = zone.pointee.introspect,
                      let enumerate = introspection.pointee.enumerator else { return false }
                guard enumerate(task, total, UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE), address,
                                reader, recorder) == KERN_SUCCESS else { return false }
            }
            return !total.pointee.failed
        }
        return succeeded ? total.blocks : nil
    }
}
