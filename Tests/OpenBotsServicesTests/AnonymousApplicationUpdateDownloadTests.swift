import Foundation
import Testing
@testable import OpenBotsServices

@Suite("Anonymous update download")
struct AnonymousApplicationUpdateDownloadTests {
    @Test func preflightRejectsHTTPAndEmbeddedCredentialsBeforeAnyRequest() async {
        for address in ["http://127.0.0.1/archive.zip", "https://user:password@example.test/archive.zip"] {
            do {
                _ = try await AnonymousApplicationUpdateDownload.bytes(from: URL(string: address)!, maximumBytes: 1024)
                Issue.record("Unsafe preflight URL was admitted")
            } catch {}
        }
    }
}
