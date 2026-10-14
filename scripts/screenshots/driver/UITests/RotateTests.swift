import XCTest

/// Sets the simulated device orientation for capture.sh. The orientation
/// outlives the test run, so Dusk launched afterwards comes up rotated.
final class RotateTests: XCTestCase {
    func testLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
    }

    func testPortrait() {
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
    }
}
