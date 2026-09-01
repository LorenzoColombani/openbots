import Foundation
import XCTest
@testable import OpenBotsSecurity

final class CredentialPreflightTests: XCTestCase {
    func testDisclosureRequiresEveryPlainEnglishField() throws {
        XCTAssertThrowsError(
            try makeDisclosure(resource: "   ")
        ) { XCTAssertEqual($0 as? CredentialDisclosureError, .missingField("resource")) }
        XCTAssertThrowsError(
            try makeDisclosure(publicRouteFailure: "")
        ) { XCTAssertEqual($0 as? CredentialDisclosureError, .missingField("publicRouteFailure")) }
        XCTAssertThrowsError(
            try makeDisclosure(persistence: .untilRevoked(revocation: ""))
        ) { XCTAssertEqual($0 as? CredentialDisclosureError, .missingField("revocation")) }
    }

    func testPublicRouteAlwaysDisablesAmbientCredentialProviders() throws {
        let authorization = try CredentialPreflightGate().authorize(
            route: .publicUnauthenticated(resource: "public Swift package")
        )
        XCTAssertEqual(authorization.mode, .anonymousPublic)
        XCTAssertFalse(authorization.allowsAmbientCredentialProviders)
        XCTAssertNil(authorization.disclosureID)
    }

    func testAuthenticatedRouteStopsBeforeDisclosureAndApproval() throws {
        let disclosure = try makeDisclosure()
        let gate = CredentialPreflightGate()
        XCTAssertThrowsError(try gate.authorize(route: .authenticated(disclosure))) {
            XCTAssertEqual($0 as? CredentialPreflightError, .disclosureRequired)
        }

        let shown = CredentialDisclosureReceipt(
            disclosureID: disclosure.id,
            presentedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertThrowsError(
            try gate.authorize(
                route: .authenticated(disclosure),
                disclosureReceipt: shown
            )
        ) { XCTAssertEqual($0 as? CredentialPreflightError, .approvalRequired) }
    }

    func testReceiptsAreBoundToTheExactDisclosure() throws {
        let disclosure = try makeDisclosure()
        let wrongID = UUID()
        let gate = CredentialPreflightGate()
        XCTAssertThrowsError(
            try gate.authorize(
                route: .authenticated(disclosure),
                disclosureReceipt: CredentialDisclosureReceipt(
                    disclosureID: wrongID,
                    presentedAt: .distantPast
                ),
                approvalReceipt: CredentialApprovalReceipt(
                    disclosureID: wrongID,
                    decision: .approved,
                    decidedAt: .distantPast
                )
            )
        ) { XCTAssertEqual($0 as? CredentialPreflightError, .receiptMismatch) }
    }

    func testDeclineReturnsOnlyTheDeclaredSafeConsequence() throws {
        let disclosure = try makeDisclosure(safeDeclineConsequence: "The probe remains offline.")
        let shown = CredentialDisclosureReceipt(
            disclosureID: disclosure.id,
            presentedAt: Date(timeIntervalSince1970: 10)
        )
        let declined = CredentialApprovalReceipt(
            disclosureID: disclosure.id,
            decision: .declined,
            decidedAt: Date(timeIntervalSince1970: 11)
        )
        XCTAssertThrowsError(
            try CredentialPreflightGate().authorize(
                route: .authenticated(disclosure),
                disclosureReceipt: shown,
                approvalReceipt: declined
            )
        ) {
            XCTAssertEqual(
                $0 as? CredentialPreflightError,
                .declined(safeConsequence: "The probe remains offline.")
            )
        }
    }

    func testApprovalCannotPredateTheExactDisclosure() throws {
        let disclosure = try makeDisclosure()
        let shown = CredentialDisclosureReceipt(
            disclosureID: disclosure.id,
            presentedAt: Date(timeIntervalSince1970: 11)
        )
        let staleApproval = CredentialApprovalReceipt(
            disclosureID: disclosure.id,
            decision: .approved,
            decidedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertThrowsError(
            try CredentialPreflightGate().authorize(
                route: .authenticated(disclosure),
                disclosureReceipt: shown,
                approvalReceipt: staleApproval
            )
        ) { XCTAssertEqual($0 as? CredentialPreflightError, .approvalPredatesDisclosure) }
    }

    func testApprovalAuthorizesOnlyTheDisclosedCredentialClassWithoutAmbientReuse() throws {
        let disclosure = try makeDisclosure(credentialClass: .claudeSubscriptionOAuth)
        let shown = CredentialDisclosureReceipt(
            disclosureID: disclosure.id,
            presentedAt: Date(timeIntervalSince1970: 10)
        )
        let approved = CredentialApprovalReceipt(
            disclosureID: disclosure.id,
            decision: .approved,
            decidedAt: Date(timeIntervalSince1970: 11)
        )
        let authorization = try CredentialPreflightGate().authorize(
            route: .authenticated(disclosure),
            disclosureReceipt: shown,
            approvalReceipt: approved
        )
        XCTAssertEqual(authorization.mode, .exactAuthenticatedClass(.claudeSubscriptionOAuth))
        XCTAssertEqual(authorization.disclosureID, disclosure.id)
        XCTAssertFalse(authorization.allowsAmbientCredentialProviders)
    }

    private func makeDisclosure(
        resource: String = "Claude Code local runtime",
        provider: String = "Anthropic Claude.ai",
        credentialClass: CredentialClass = .claudeSubscriptionOAuth,
        leastScope: String = "Pro or Max subscription login",
        accessDirection: CredentialAccessDirection = .readWrite,
        publicRouteFailure: String = "The authenticated runtime cannot run anonymously.",
        promptOwner: String = "Official Claude Code and Claude.ai browser flow",
        persistence: CredentialPersistence = .untilRevoked(revocation: "Use official logout."),
        safeDeclineConsequence: String = "The authenticated probe does not run."
    ) throws -> CredentialAccessDisclosure {
        try CredentialAccessDisclosure(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            resource: resource,
            provider: provider,
            credentialClass: credentialClass,
            leastScope: leastScope,
            accessDirection: accessDirection,
            publicRouteFailure: publicRouteFailure,
            promptOwner: promptOwner,
            persistence: persistence,
            safeDeclineConsequence: safeDeclineConsequence
        )
    }
}
