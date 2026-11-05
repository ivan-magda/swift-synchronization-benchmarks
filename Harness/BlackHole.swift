/// Prevents dead-code elimination using the underscored `@_optimize(none)` attribute.
@_optimize(none) @inline(never)
func blackHole<T>(_ value: T) {}

/// Hides a value from constant propagation using an underscored optimization attribute.
@_optimize(none) @inline(never)
func opaque<T>(_ value: T) -> T {
    value
}
