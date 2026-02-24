#if canImport(XCTest)
import XCTest
@testable import ProSSHMac

final class RemotePathTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeEmptyString() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
    }

    func testNormalizeWhitespaceOnly() {
        XCTAssertEqual(RemotePath.normalize("  "), "/")
    }

    func testNormalizeRoot() {
        XCTAssertEqual(RemotePath.normalize("/"), "/")
    }

    func testNormalizeSimplePath() {
        XCTAssertEqual(RemotePath.normalize("/foo/bar"), "/foo/bar")
    }

    func testNormalizeTrailingSlash() {
        XCTAssertEqual(RemotePath.normalize("/foo/bar/"), "/foo/bar")
    }

    func testNormalizeDotComponents() {
        XCTAssertEqual(RemotePath.normalize("/foo/./bar"), "/foo/bar")
    }

    func testNormalizeDoubleSlash() {
        XCTAssertEqual(RemotePath.normalize("/foo//bar"), "/foo/bar")
    }

    func testNormalizeRelativePath() {
        XCTAssertEqual(RemotePath.normalize("foo/bar"), "/foo/bar")
    }

    // MARK: - parent(of:)

    func testParentOfRoot() {
        XCTAssertNil(RemotePath.parent(of: "/"))
    }

    func testParentOfTopLevel() {
        XCTAssertEqual(RemotePath.parent(of: "/foo"), "/")
    }

    func testParentOfDeepPath() {
        XCTAssertEqual(RemotePath.parent(of: "/foo/bar/baz"), "/foo/bar")
    }

    func testParentNormalizesInput() {
        XCTAssertEqual(RemotePath.parent(of: "/foo/bar/"), "/foo")
    }

    // MARK: - join(_:_:)

    func testJoinRootWithName() {
        XCTAssertEqual(RemotePath.join("/", "foo"), "/foo")
    }

    func testJoinPathWithName() {
        XCTAssertEqual(RemotePath.join("/foo/bar", "baz"), "/foo/bar/baz")
    }

    func testJoinNormalizesBase() {
        XCTAssertEqual(RemotePath.join("/foo/bar/", "baz"), "/foo/bar/baz")
    }
}

#endif
