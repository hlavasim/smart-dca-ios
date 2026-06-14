import XCTest
@testable import AccBot

final class BankLoanUseCaseTests: XCTestCase {
    func test_create_setsRemaining() throws {
        let db = try DcaDatabase(path: nil)
        let id = try BankLoanUseCase(db: db).create(principalCzk: 1_000_000, annualRate: 0.07,
            durationMonths: 120, loanDate: Date(timeIntervalSince1970: 1_700_000_000))
        let l = try db.bankLoanDao.getActive().first!
        XCTAssertEqual(Double(l.remainingPrincipalCzk)!, 1_000_000, accuracy: 1)
        XCTAssertEqual(l.id, id)
    }

    func test_payment_splitsInterestPrincipal() throws {
        let db = try DcaDatabase(path: nil)
        let uc = BankLoanUseCase(db: db)
        let id = try uc.create(principalCzk: 1_000_000, annualRate: 0.07, durationMonths: 120, loanDate: Date())
        try uc.recordPayment(id: id, months: 1)
        let l = try db.bankLoanDao.getActive().first!
        // monthly ≈ 11611, interest 5833 → principal ≈ 5778 → remaining ≈ 994222
        XCTAssertEqual(Double(l.remainingPrincipalCzk)!, 994_222, accuracy: 100)
    }
}
