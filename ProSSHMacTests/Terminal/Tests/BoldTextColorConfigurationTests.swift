import XCTest
@testable import ProSSHMac

final class BoldTextColorConfigurationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BoldTextColorConfigurationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadReturnsDefaultWhenUnset() {
        XCTAssertEqual(BoldTextColorConfiguration.load(from: defaults), .default)
    }

    func testSaveLoadRoundTrip() {
        let config = BoldTextColorConfiguration(
            isEnabled: true,
            customColor: GradientColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1.0)
        )

        config.save(to: defaults)

        XCTAssertEqual(BoldTextColorConfiguration.load(from: defaults), config)
    }
}
