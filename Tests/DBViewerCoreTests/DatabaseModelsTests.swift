#if canImport(XCTest)
import XCTest
@testable import DBViewerCore

final class DatabaseModelsTests: XCTestCase {
    func testEngineDisplayName() {
        XCTAssertEqual(DatabaseEngine.postgres.displayName, "PostgreSQL")
        XCTAssertEqual(DatabaseEngine.mysql.displayName, "MySQL")
        XCTAssertEqual(DatabaseEngine.sqlite.displayName, "SQLite")
    }
}
#endif
