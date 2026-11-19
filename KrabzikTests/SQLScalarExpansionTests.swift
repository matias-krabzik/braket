@testable import Krabzik
import XCTest

final class SQLScalarExpansionTests: XCTestCase {
    func testPNRAndNumericAirlineAreExpandedBeforePagination() throws {
        let sql = "SELECT * FROM ReservationsRequests WHERE pnr = @PNR and mor = @AIRLINE_ID"
        let expansion = try SQLScalarExpansion(sql)
        XCTAssertEqual(expansion.query, "SELECT @PNR, @AIRLINE_ID")
        var result = SQLResult(statement: 0, line: 1)
        result.rows = [["JJ7QYT", "3"]]
        result.origins = [origin(253), origin(8)]
        let expanded = try expansion.expand(result)
        XCTAssertEqual(expanded, "SELECT * FROM ReservationsRequests WHERE pnr = 'JJ7QYT' and mor = 3")
        XCTAssertTrue(try XCTUnwrap(SQLPagination(expanded, page: 0)).query.contains("LIMIT 101 OFFSET 0"))
    }

    func testStringsNullAndRepeatedNamesPreserveValues() throws {
        let expansion = try SQLScalarExpansion("SELECT @pnr, @pnr, @empty, @n")
        var result = SQLResult(statement: 0, line: 1)
        result.rows = [["001'\\test", "", nil]]
        result.origins = [origin(253), origin(253), origin(6)]
        XCTAssertEqual(try expansion.expand(result),
                       "SELECT \(SQLValue.literal("001'\\test")), \(SQLValue.literal("001'\\test")), '', NULL")
        result.truncated = true
        XCTAssertThrowsError(try expansion.expand(result))
    }

    func testDoesNotReplaceStringsCommentsIdentifiersOrAssignmentTargets() throws {
        let expansion = try SQLScalarExpansion("SELECT '@x', `@x`, @@SESSION.sql_mode, @x /* @y */ -- @z\n")
        XCTAssertEqual(expansion.names, ["@x"])
        for sql in ["SET @x = @y", "SELECT @x := @y", "SELECT a INTO @x FROM t", "EXECUTE stmt USING @x", "SELECT /*! @x */ 1"] {
            XCTAssertNil(try SQLScalarExpansion(sql).query)
        }
    }

    private func origin(_ type: UInt8) -> SQLColumnOrigin {
        .init(database: "", table: "", column: "", mysqlType: type)
    }
}
