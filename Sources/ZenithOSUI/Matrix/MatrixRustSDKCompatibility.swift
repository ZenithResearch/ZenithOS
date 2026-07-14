import MatrixRustSDK

/// Narrow compile-time boundary proving the exactly pinned Matrix Rust SDK is
/// available to ZenithOSUI without exposing SDK objects to SwiftUI views.
enum MatrixRustSDKCompatibility {
    static let packageRelease = "26.06.06"
    static let isLinked = true
}