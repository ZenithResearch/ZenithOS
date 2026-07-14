import Testing
@testable import ZenithOSUI

@Suite("Matrix Rust SDK compatibility")
struct MatrixRustSDKCompatibilityTests {
    @Test("pinned SDK is available behind the Zenith adapter boundary")
    func pinnedSDKIsAvailableBehindAdapter() {
        #expect(MatrixRustSDKCompatibility.packageRelease == "26.06.06")
        #expect(MatrixRustSDKCompatibility.isLinked)
    }
}
