import XCTest
@testable import ClassDumpDyld

final class ClassDumpDyldTests: XCTestCase {
    func testExample() throws {
        let ex = XCTestExpectation()
        ClassDumpDyldManager.shared.dumpAllImageHeaders(toPath: "/Volumes/FrameworkLab/macOS/14.4/Headers") {
            ex.fulfill()
        }
        
        wait(for: [ex])
    }
    
    func testDyldSharedCachePath() {
        print(ClassDumpDyldManager.shared.dyldSharedCachePath(for: .arm64e))
    }
}
