import XCTest
@testable import ClassDumpDyld

final class ClassDumpDyldTests: XCTestCase {
    func testExample() throws {
        ClassDumpDyldManager.shared.allImages { allImages, error in
            if let allImages {
                print(allImages, allImages.count)
            }
            
            if let error {
                print(error)
            }
        }
    }
}
