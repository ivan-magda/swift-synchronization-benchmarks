import Foundation
import ObjectiveC

/// The stored object's Objective-C monitor guards every access to state.
final class ObjcSyncProtection<State: Sendable>: StateProtection, @unchecked Sendable {
    private let monitor = NSObject()
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    func withExclusiveAccess<Result: Sendable>(
        _ body: @Sendable (inout State) -> Result
    ) -> Result {
        let result = objc_sync_enter(monitor)
        assert(result == OBJC_SYNC_SUCCESS)
        defer {
            let result = objc_sync_exit(monitor)
            assert(result == OBJC_SYNC_SUCCESS)
        }
        return body(&state)
    }
}
