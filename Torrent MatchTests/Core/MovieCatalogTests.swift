import XCTest
@testable import Torrent_Match

final class MovieCatalogTests: XCTestCase {
    func testNormalizationRemovesPunctuationAndAccents() {
        XCTAssertEqual(MovieCatalog.normalize("Amélie"), "amelie")
        XCTAssertEqual(MovieCatalog.normalize("Spider-Man: No Way Home"), "spider man no way home")
        XCTAssertEqual(MovieCatalog.normalize("Fast & Furious"), "fast and furious")
    }
}
