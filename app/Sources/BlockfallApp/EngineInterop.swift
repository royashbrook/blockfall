import Foundation

/// Engine configuration retains these pointers for its lifetime. The strings
/// are intentionally process-scoped; both Apple app targets share this helper.
func persistentCString(_ value: String) -> UnsafePointer<CChar> {
    UnsafePointer(strdup(value))!
}
