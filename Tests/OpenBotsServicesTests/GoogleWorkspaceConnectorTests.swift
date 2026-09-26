import Foundation
import OpenBotsContent
import OpenBotsDomain
import OpenBotsRuntime
import OpenBotsSecurity
import Testing
@testable import OpenBotsServices

private let googleClientID = "openbots-test.apps.googleusercontent.com"
private let googleClientSecret = "GOCSPX-test+secret/value"
private let googleClientSecretReference = KeychainItemReference
    .previewGoogleWorkspaceOAuthClientSecret(clientID: googleClientID)!
private let googleConnectionID = UUID(uuidString: "74895a76-b9e7-4f5e-9b9d-5632d25644a6")!

private func googleKeychainSeed(_ additional: [KeychainItemReference: Data] = [:])
    -> [KeychainItemReference: Data] {
    var result = additional
    result[googleClientSecretReference] = Data(googleClientSecret.utf8)
    return result
}

private func googleClientConfiguration(clientID: String = googleClientID,
                                       secret: String? = googleClientSecret,
                                       applicationType: String = "installed") throws -> Data {
    var client: [String: Any] = ["client_id": clientID]
    if let secret { client["client_secret"] = secret }
    return try JSONSerialization.data(withJSONObject: [applicationType: client], options: [.sortedKeys])
}

private actor GoogleHTTPStub: GoogleWorkspaceHTTPClient {
    private var answers: [GoogleWorkspaceHTTPResponse]
    private var seen: [URLRequest] = []

    init(_ answers: [GoogleWorkspaceHTTPResponse]) { self.answers = answers }

    func send(_ request: URLRequest) async throws -> GoogleWorkspaceHTTPResponse {
        seen.append(request)
        guard !answers.isEmpty else {
            throw GoogleWorkspaceAPIError.provider(status: 0, message: "test response missing")
        }
        return answers.removeFirst()
    }

    func requests() -> [URLRequest] { seen }
}

private actor GoogleHTTPGate: GoogleWorkspaceHTTPClient {
    private let response: GoogleWorkspaceHTTPResponse
    private var seen: [URLRequest] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseWaiter: CheckedContinuation<GoogleWorkspaceHTTPResponse, Never>?

    init(_ response: GoogleWorkspaceHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> GoogleWorkspaceHTTPResponse {
        seen.append(request)
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { responseWaiter = $0 }
    }

    func waitUntilRequestArrives() async {
        if !seen.isEmpty { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        responseWaiter?.resume(returning: response)
        responseWaiter = nil
    }

    func requests() -> [URLRequest] { seen }
}

private actor GoogleKeychainReadGate: KeychainClient {
    private var items: [KeychainItemReference: Data]
    private var googleTokenReads = 0
    private var secondReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondReadRelease: CheckedContinuation<Void, Never>?

    init(seed: [KeychainItemReference: Data]) { items = seed }

    func read(_ reference: KeychainItemReference) async throws -> Data? {
        if reference == .previewGoogleWorkspaceOAuthTokens {
            googleTokenReads += 1
            if googleTokenReads == 2 {
                let waiters = secondReadWaiters
                secondReadWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { secondReadRelease = $0 }
            }
        }
        return items[reference]
    }

    func store(_ secret: Data, at reference: KeychainItemReference) async throws {
        items[reference] = secret
    }

    func delete(_ reference: KeychainItemReference) async throws {
        items.removeValue(forKey: reference)
    }

    func waitUntilSecondGoogleTokenRead() async {
        if googleTokenReads >= 2 { return }
        await withCheckedContinuation { secondReadWaiters.append($0) }
    }

    func releaseSecondGoogleTokenRead() {
        secondReadRelease?.resume()
        secondReadRelease = nil
    }
}

private func googleCredential(expiresAt: Date = Date(timeIntervalSince1970: 99_999))
    -> GoogleWorkspaceCredential {
    GoogleWorkspaceCredential(clientID: googleClientID, accountEmail: "openbots@example.com",
        accessToken: "access-token", refreshToken: "refresh-token", expiresAt: expiresAt,
        grantedScopes: GoogleWorkspaceOAuthScopes.required, connectionID: googleConnectionID)
}

/// A `Data` answer is sent as it is: Drive's export and download return the
/// file's own bytes, not JSON.
private func googleResponses(_ objects: [(Int, Any)]) throws -> [GoogleWorkspaceHTTPResponse] {
    try objects.map { status, object in
        GoogleWorkspaceHTTPResponse(statusCode: status, data: try (object as? Data)
            ?? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}

/// A request's query as Google will read it: each name once, `+` decoded as a
/// space the way Google's servers decode it, which is why a literal plus must
/// arrive as `%2B`.
private func googleQuery(_ request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    else { return [:] }
    var result: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        let decode = { (text: String) in
            text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
        }
        let name = decode(parts[0])
        if result[name] != nil { Issue.record("\(name) appears twice in \(query)") }
        result[name] = parts.count == 2 ? decode(parts[1]) : ""
    }
    return result
}

/// What Google answers when an API is switched off in the Cloud project, as
/// its error model documents it: the old `accessNotConfigured` reason and the
/// newer `ErrorInfo` detail naming the service, the project it is off in, and
/// Google's own address for the switch (which the app never shows).
private func googleServiceDisabled(_ service: String, consumer: String = "projects/123456",
                                   activationURL: String? = nil) -> [String: Any] {
    let project = consumer.hasPrefix("projects/") ? String(consumer.dropFirst("projects/".count)) : consumer
    return ["error": [
        "code": 403,
        "message": "\(service) has not been used in project \(project) before or it is disabled. "
            + "Enable it by visiting https://console.developers.google.com/apis/api/\(service)/overview?project=\(project) then retry.",
        "errors": [["message": "disabled", "domain": "usageLimits", "reason": "accessNotConfigured",
                    "extendedHelp": "https://console.developers.google.com"]],
        "status": "PERMISSION_DENIED",
        "details": [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED",
                     "domain": "googleapis.com",
                     "metadata": ["service": service, "consumer": consumer, "containerInfo": project,
                                  "serviceTitle": "Google Drive API",
                                  "activationUrl": activationURL
                                      ?? "https://console.developers.google.com/apis/api/\(service)/overview?project=\(project)"]]],
    ] as [String: Any]]
}

/// The page the app itself builds for the Drive API's switch in project 123456.
private let driveSwitchPage = URL(string: "https://console.cloud.google.com/apis/library/drive.googleapis.com?project=123456")!

private func googleAPI(_ responses: [(Int, Any)], now: Date = Date(timeIntervalSince1970: 10_000)) async throws
    -> (GoogleWorkspaceAPI, GoogleHTTPStub, InMemoryKeychainClient) {
    let credential = googleCredential()
    let data = try JSONEncoder().encode(credential)
    let keychain = InMemoryKeychainClient(seed: googleKeychainSeed([
        .previewGoogleWorkspaceOAuthTokens: data,
    ]))
    let http = GoogleHTTPStub(try googleResponses(responses))
    let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                 http: http, now: { now })
    return (api, http, keychain)
}

@Suite("Google's provider authority and OpenBots' smaller surface")
struct GoogleWorkspaceAPITests {
    @Test("The requested scopes are the two Gmail needs, the two narrow Calendar reads and Drive read-only")
    func scopesAreExact() {
        #expect(GoogleWorkspaceOAuthScopes.required == [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.compose",
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events.readonly",
            "https://www.googleapis.com/auth/drive.readonly",
        ])
        #expect(!GoogleWorkspaceOAuthScopes.required.contains("https://www.googleapis.com/auth/calendar.readonly"))
        #expect(!GoogleWorkspaceOAuthScopes.required.contains("https://www.googleapis.com/auth/gmail.modify"))
        #expect(!GoogleWorkspaceOAuthScopes.required.contains("https://www.googleapis.com/auth/gmail.send"))
        #expect(!GoogleWorkspaceOAuthScopes.required.contains("https://www.googleapis.com/auth/drive"))
        #expect(!GoogleWorkspaceOAuthScopes.required.contains("https://www.googleapis.com/auth/drive.file"))
        // Every permission has words the user can read on a refusal.
        for scope in GoogleWorkspaceOAuthScopes.required {
            #expect(GoogleWorkspaceOAuthScopes.plainName(scope) != scope, "\(scope) has no plain name")
        }
    }

    @Test("Desktop JSON import matches this build and stores only secret bytes")
    func clientConfigurationImportIsBoundAndMinimal() async throws {
        let keychain = InMemoryKeychainClient()
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        #expect(await store.clientConfigurationStatus(clientID: googleClientID).state == .missing)

        let source = try googleClientConfiguration()
        #expect(try await store.importClientConfiguration(source, clientID: googleClientID).isReady)
        let stored = try #require(try await keychain.read(googleClientSecretReference))
        #expect(stored == Data(googleClientSecret.utf8))
        #expect(stored != source)
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
        #expect(!(await keychain.contains(.previewGoogleWorkspaceCapabilityKey)))
        #expect(await store.clientConfigurationStatus(clientID: googleClientID).isReady)
        let operations = await keychain.recordedOperations()
        #expect(!String(describing: operations).contains(googleClientSecret))
    }

    @Test("Wrong, Web, missing, malformed and oversized JSON cannot replace a valid secret")
    func invalidClientConfigurationNeverReplacesAuthority() async throws {
        let earlier = "GOCSPX-earlier-valid-secret"
        let keychain = InMemoryKeychainClient(seed: [
            googleClientSecretReference: Data(earlier.utf8),
        ])
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)

        await #expect(throws: GoogleWorkspaceClientConfigurationError.wrongClient) {
            _ = try await store.importClientConfiguration(try googleClientConfiguration(
                clientID: "other.apps.googleusercontent.com"), clientID: googleClientID)
        }
        await #expect(throws: GoogleWorkspaceClientConfigurationError.wrongApplicationType) {
            _ = try await store.importClientConfiguration(try googleClientConfiguration(
                applicationType: "web"), clientID: googleClientID)
        }
        await #expect(throws: GoogleWorkspaceClientConfigurationError.missingSecret) {
            _ = try await store.importClientConfiguration(try googleClientConfiguration(
                secret: nil), clientID: googleClientID)
        }
        await #expect(throws: GoogleWorkspaceClientConfigurationError.malformed) {
            _ = try await store.importClientConfiguration(Data("not-json".utf8),
                                                           clientID: googleClientID)
        }
        await #expect(throws: GoogleWorkspaceClientConfigurationError.fileTooLarge) {
            _ = try await store.importClientConfiguration(
                Data(repeating: 0x41,
                     count: GoogleWorkspaceCredentialStore.maximumClientConfigurationBytes + 1),
                clientID: googleClientID)
        }
        #expect(try await keychain.read(googleClientSecretReference) == Data(earlier.utf8))
    }

    @Test("Authorization refuses before HTTP when the matching client secret is absent")
    func missingClientConfigurationNeverReachesGoogle() async throws {
        let keychain = InMemoryKeychainClient()
        let http = GoogleHTTPStub(try googleResponses([(200, [:])]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                     http: http)
        await #expect(throws: GoogleWorkspaceClientConfigurationError.missingSecret) {
            _ = try await api.exchangeAuthorizationCode(
                "code", verifier: String(repeating: "v", count: 64),
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        }
        #expect(await http.requests().isEmpty)
    }

    @Test("Draft creation can only POST to drafts, never either provider send endpoint")
    func draftEndpointIsClosed() async throws {
        let (api, http, _) = try await googleAPI([(200, ["id": "draft-1", "message": ["id": "m-1"]])])
        _ = try await api.gmailCreateDraft([
            "to": "person@example.com", "cc": "copy@example.com",
            "subject": "A subject", "body": "A body",
        ], clientID: googleClientID)
        let request = try #require(await http.requests().only)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == "gmail.googleapis.com")
        #expect(request.url?.path == "/gmail/v1/users/me/drafts")
        #expect(!request.url!.absoluteString.contains("/send"))
        let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let message = try #require(object["message"] as? [String: Any])
        #expect(Set(message.keys) == ["raw"])
    }

    @Test("Reading Gmail is GET-only and model input cannot choose the host")
    func gmailReadIsFixed() async throws {
        let (api, http, _) = try await googleAPI([(200, ["messages": []])])
        _ = try await api.gmailSearch(["query": "from:person@example.com", "limit": 12],
                                      clientID: googleClientID)
        let request = try #require(await http.requests().only)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "gmail.googleapis.com")
        #expect(request.url?.path == "/gmail/v1/users/me/messages")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(.init(name: "maxResults", value: "12")) == true)
    }

    @Test("Calendar search lists and reads with GET, and rejects a path-shaped calendar id")
    func calendarIsReadOnlyAndPathClosed() async throws {
        let (api, http, _) = try await googleAPI([
            (200, ["items": [["id": "primary@example.com", "summary": "Primary"]]]),
            (200, ["items": [["id": "event_1", "summary": "Review"]]]),
        ])
        _ = try await api.calendarSearch([
            "from": "2026-09-12T00:00:00Z", "to": "2026-09-19T00:00:00Z",
        ], clientID: googleClientID)
        let requests = await http.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.url?.host == "www.googleapis.com" })
        #expect(requests[1].url?.path.contains("/calendars/primary@example.com/events") == true)

        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.calendarReadEvent(
                ["calendar_id": "../../oauth2", "event_id": "event_1"], clientID: googleClientID)
        }
    }

    @Test("Provider calendar ids containing a hash stay one percent-encoded path component")
    func holidayCalendarIDsAreAcceptedAndEncoded() async throws {
        let calendarID = "en.german#holiday@group.v.calendar.google.com"
        let (api, http, _) = try await googleAPI([
            (200, ["items": [["id": calendarID, "summary": "Holidays in Germany"]]]),
            (200, ["items": [["id": "event_1", "summary": "Unity Day"]]]),
            (200, ["id": "event_1", "summary": "Unity Day"]),
        ])
        _ = try await api.calendarSearch([
            "from": "2026-09-12T00:00:00Z", "to": "2026-10-12T00:00:00Z",
        ], clientID: googleClientID)
        _ = try await api.calendarReadEvent(
            ["calendar_id": calendarID, "event_id": "event_1"], clientID: googleClientID)

        let requests = await http.requests()
        #expect(requests.count == 3)
        for request in requests.dropFirst() {
            #expect(request.url?.absoluteString.contains(
                "en.german%23holiday@group.v.calendar.google.com") == true)
            #expect(request.url?.fragment == nil)
        }
    }

    @Test("OAuth is not saved until every exact scope and both APIs answer")
    func exchangeValidatesBeforeSaving() async throws {
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed())
        let scope = GoogleWorkspaceOAuthScopes.required.sorted().joined(separator: " ")
        let http = GoogleHTTPStub(try googleResponses([
            (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600,
                   "scope": scope, "token_type": "Bearer"]),
            (200, ["emailAddress": "openbots@example.com"]),
            (200, ["items": []]),
            (200, ["user": ["emailAddress": "openbots@example.com"]]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                     http: http, now: { Date(timeIntervalSince1970: 1_000) })
        let status = try await api.exchangeAuthorizationCode(
            "code", verifier: String(repeating: "v", count: 64),
            redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        #expect(status.state == .connected)
        #expect(status.accountEmail == "openbots@example.com")
        #expect(status.connectionID != nil)
        #expect(await keychain.contains(.previewGoogleWorkspaceOAuthTokens))
        #expect(await http.requests().map { "\($0.httpMethod ?? "") \($0.url?.absoluteString ?? "")" } == [
            "POST https://oauth2.googleapis.com/token",
            "GET https://gmail.googleapis.com/gmail/v1/users/me/profile",
            "GET https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=1",
            "GET https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)",
        ])
    }

    @Test("Connecting with the Drive API switched off says where to switch it on and keeps nothing")
    func exchangeWithDriveOffIsPlainAndLeavesNoCredential() async throws {
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed())
        let scope = GoogleWorkspaceOAuthScopes.required.sorted().joined(separator: " ")
        let http = GoogleHTTPStub(try googleResponses([
            (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600,
                   "scope": scope, "token_type": "Bearer"]),
            (200, ["emailAddress": "openbots@example.com"]),
            (200, ["items": []]),
            (403, googleServiceDisabled("drive.googleapis.com")),
            (200, [:]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain), http: http)
        do {
            _ = try await api.exchangeAuthorizationCode(
                "code", verifier: String(repeating: "v", count: 64),
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
            Issue.record("a connection was made with the Drive API switched off")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            #expect(error as? GoogleWorkspaceAPIError == .apiDisabled("Google Drive API", enablePage: driveSwitchPage))
            #expect(text.contains("Google Drive API"))
            // Google named the project, so the sentence points at its switch
            // instead of the steps through the console.
            #expect(text.contains(driveSwitchPage.absoluteString))
            #expect(text.contains("Enable"))
            #expect(!text.contains("HTTP 403"))
        }
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
        #expect(await http.requests().last?.url == GoogleWorkspaceAPI.revocationEndpoint)
    }

    @Test("Token failures keep only a safe OAuth code once a client secret was sent")
    func oauthFailureDropsProviderProse() async throws {
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed())
        let http = GoogleHTTPStub(try googleResponses([
            (400, ["error": "invalid_request",
                   "error_description": "Rejected \(googleClientSecret).\nRetry\u{202E} only after checking it."]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                     http: http)

        await #expect(throws: GoogleWorkspaceAPIError.provider(
            status: 400,
            message: "invalid_request"
        )) {
            _ = try await api.exchangeAuthorizationCode(
                "code", verifier: String(repeating: "v", count: 64),
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        }
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
    }

    @Test("A provider echo of only a client-secret prefix is never surfaced")
    func partialClientSecretEchoIsDiscarded() async throws {
        let secret = "GOCSPX-" + String(repeating: "s", count: 300)
        let keychain = InMemoryKeychainClient(seed: [
            googleClientSecretReference: Data(secret.utf8),
        ])
        let http = GoogleHTTPStub(try googleResponses([
            (400, ["error": "invalid_client",
                   "error_description": "Rejected \(secret.prefix(12))"]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                     http: http)
        await #expect(throws: GoogleWorkspaceAPIError.provider(
            status: 400, message: "invalid_client"
        )) {
            _ = try await api.exchangeAuthorizationCode(
                "code", verifier: String(repeating: "v", count: 64),
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        }
    }

    @Test("Token exchange canonically carries the matching Keychain client secret")
    func tokenExchangeFormUsesTheImportedSecret() async throws {
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed())
        let http = GoogleHTTPStub(try googleResponses([
            (400, ["error": "invalid_grant"]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                     http: http)
        let verifier = String(repeating: "v", count: 64)

        await #expect(throws: GoogleWorkspaceAPIError.provider(
            status: 400, message: "invalid_grant"
        )) {
            _ = try await api.exchangeAuthorizationCode(
                "code+with/slash=and&separator", verifier: verifier,
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        }

        let request = try #require(await http.requests().only)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "client_id=openbots-test.apps.googleusercontent.com"
            + "&client_secret=GOCSPX-test%2Bsecret%2Fvalue"
            + "&code=code%2Bwith%2Fslash%3Dand%26separator"
            + "&code_verifier=\(verifier)"
            + "&grant_type=authorization_code"
            + "&redirect_uri=http%3A%2F%2F127.0.0.1%3A49152")
        #expect(!body.contains(googleClientSecret))
    }

    @Test("A partial granular grant leaves no durable credential")
    func partialGrantIsNotSaved() async throws {
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed())
        let partial = GoogleWorkspaceOAuthScopes.required
            .subtracting([GoogleWorkspaceOAuthScopes.calendarEventsReadOnly]).sorted().joined(separator: " ")
        let http = GoogleHTTPStub(try googleResponses([
            (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600,
                   "scope": partial, "token_type": "Bearer"]),
            (200, [:]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain), http: http)
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.exchangeAuthorizationCode(
                "code", verifier: String(repeating: "v", count: 64),
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        }
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
    }

    @Test("An extra returned or stored scope is rejected but remains removable")
    func extraScopesFailClosedAndCanBeCleanedUp() async throws {
        let extra = GoogleWorkspaceOAuthScopes.required.union(["https://www.googleapis.com/auth/drive"])
        let credential = GoogleWorkspaceCredential(clientID: googleClientID,
            accountEmail: "openbots@example.com", accessToken: "a", refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 9_999), grantedScopes: extra,
            connectionID: googleConnectionID)
        let keychain = InMemoryKeychainClient(seed: [
            .previewGoogleWorkspaceOAuthTokens: try JSONEncoder().encode(credential),
        ])
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await store.load(clientID: googleClientID)
        }
        #expect(try await store.loadForRevocation(clientID: googleClientID)?.refreshToken == "r")
        #expect(await GoogleWorkspaceAPI(store: store).status(clientID: googleClientID).state
            == .revocationPending)

        let http = GoogleHTTPStub(try googleResponses([(200, [:])]))
        let api = GoogleWorkspaceAPI(store: store, http: http)
        #expect(try await api.finishRevocation(clientID: googleClientID).state == .disconnected)
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
    }

    @Test("A connection made before Drive says so in plain words and can still be removed")
    func connectionMadeBeforeDriveIsNamed() async throws {
        let old = GoogleWorkspaceOAuthScopes.required.subtracting([GoogleWorkspaceOAuthScopes.driveReadOnly])
        let credential = GoogleWorkspaceCredential(clientID: googleClientID,
            accountEmail: "openbots@example.com", accessToken: "a", refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 9_999), grantedScopes: old,
            connectionID: googleConnectionID)
        let keychain = InMemoryKeychainClient(seed: [
            .previewGoogleWorkspaceOAuthTokens: try JSONEncoder().encode(credential),
        ])
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        await #expect(throws: GoogleWorkspaceAPIError.connectionPredatesPermission(
            GoogleWorkspaceOAuthScopes.driveReadOnly)) {
            _ = try await store.load(clientID: googleClientID)
        }
        let status = await GoogleWorkspaceAPI(store: store).status(clientID: googleClientID)
        #expect(status.state == .revocationPending)
        let reason = try #require(status.reason)
        #expect(reason.contains("before"))
        #expect(reason.contains("Google Drive"))
        #expect(reason.contains("connect the account again"))
        #expect(!reason.contains("did not grant"))

        let http = GoogleHTTPStub(try googleResponses([(200, [:])]))
        let api = GoogleWorkspaceAPI(store: store, http: http)
        #expect(try await api.finishRevocation(clientID: googleClientID).state == .disconnected)
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
    }

    @Test("A permission left unticked on Google's page is named in plain words")
    func uncheckedPermissionIsPlain() {
        let text = GoogleWorkspaceAPIError.missingScope(GoogleWorkspaceOAuthScopes.driveReadOnly)
            .errorDescription ?? ""
        #expect(text.contains("read Google Drive"))
        #expect(text.contains("every permission"))
        #expect(!text.contains("https://"))
    }

    @Test("A failure after token issuance compensates at Google before forgetting the token")
    func failedVerificationRevokesTheIssuedGrant() async throws {
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed())
        let scope = GoogleWorkspaceOAuthScopes.required.sorted().joined(separator: " ")
        let http = GoogleHTTPStub(try googleResponses([
            (200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600,
                   "scope": scope, "token_type": "Bearer"]),
            (503, ["error": ["message": "Gmail unavailable"]]),
            (200, [:]),
        ]))
        let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain), http: http)
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.exchangeAuthorizationCode("code",
                verifier: String(repeating: "v", count: 64),
                redirectURI: "http://127.0.0.1:49152", clientID: googleClientID)
        }
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))
        #expect(await http.requests().last?.url?.absoluteString
            == "https://oauth2.googleapis.com/revoke")
    }

    @Test("Failed provider cleanup leaves only non-authorizing retry state")
    func failedCleanupStaysLocallyDisabled() async throws {
        let credential = googleCredential()
        let keychain = InMemoryKeychainClient(seed: [
            .previewGoogleWorkspaceOAuthTokens: try JSONEncoder().encode(credential),
        ])
        let http = GoogleHTTPStub(try googleResponses([
            (503, ["error": ["message": "offline"]]),
        ]))
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        let api = GoogleWorkspaceAPI(store: store, http: http,
                                     now: { Date(timeIntervalSince1970: 10_000) })
        #expect(try await api.stageRevocation(clientID: googleClientID).state == .revocationPending)
        #expect(try await store.load(clientID: googleClientID) == nil)
        await #expect(throws: GoogleWorkspaceAPIError.notConnected) {
            _ = try await api.gmailProfile(clientID: googleClientID)
        }
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.finishRevocation(clientID: googleClientID)
        }
        let cleanup = try #require(try await store.loadForRevocation(clientID: googleClientID))
        #expect(cleanup.state == .revocationPending)
        #expect(try await store.load(clientID: googleClientID) == nil)
        let request = try #require(await http.requests().only)
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self)
            == "token=refresh-token")
    }

    @Test("Reading one Calendar event keeps the validated calendar id")
    func eventReadKeepsItsCalendar() async throws {
        let (api, _, _) = try await googleAPI([(200, ["id": "event_1", "summary": "Review"])])
        let data = try await api.calendarReadEvent(
            ["calendar_id": "primary@example.com", "event_id": "event_1"],
            clientID: googleClientID)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["openbotsCalendarID"] as? String == "primary@example.com")
    }

    @Test("A refresh is used in memory and cannot overwrite a concurrent local disconnect")
    func refreshedAccessTokenIsNotPersisted() async throws {
        let expired = googleCredential(expiresAt: Date(timeIntervalSince1970: 9_000))
        let original = try JSONEncoder().encode(expired)
        let keychain = InMemoryKeychainClient(seed: googleKeychainSeed([
            .previewGoogleWorkspaceOAuthTokens: original,
        ]))
        let http = GoogleHTTPStub(try googleResponses([
            (200, ["access_token": "fresh", "expires_in": 3600,
                   "scope": GoogleWorkspaceOAuthScopes.required.sorted().joined(separator: " ")]),
            (200, ["emailAddress": "openbots@example.com"]),
        ]))
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        let api = GoogleWorkspaceAPI(store: store, http: http,
                                     now: { Date(timeIntervalSince1970: 10_000) })
        _ = try await api.gmailProfile(clientID: googleClientID)
        let refreshBody = String(decoding: try #require(await http.requests().first?.httpBody),
                                 as: UTF8.self)
        #expect(refreshBody.contains("client_secret=GOCSPX-test%2Bsecret%2Fvalue"))
        #expect(!refreshBody.contains(googleClientSecret))
        let saved = try #require(try await keychain.read(.previewGoogleWorkspaceOAuthTokens))
        #expect(saved == original)
        #expect(try await store.stageForRevocation(clientID: googleClientID)?.state
            == .revocationPending)
        #expect(try await store.load(clientID: googleClientID) == nil)
    }

    @Test("Google refusing the saved sign-in turns Google off on this Mac, says so, and calls nothing else")
    func aRejectedRefreshDisablesLocally() async throws {
        // Expired before the call, and a live token Google answers 401 to: both reach the refresh.
        for (expiresAt, answers) in [
            (Date(timeIntervalSince1970: 9_000), [(400, ["error": "invalid_grant"] as [String: Any])]),
            (Date(timeIntervalSince1970: 99_999), [(401, ["error": ["message": "Invalid Credentials"]] as [String: Any]),
                                                   (400, ["error": "invalid_grant"])]),
        ] {
            let keychain = InMemoryKeychainClient(seed: googleKeychainSeed([
                .previewGoogleWorkspaceOAuthTokens: try JSONEncoder().encode(googleCredential(expiresAt: expiresAt)),
            ]))
            let http = GoogleHTTPStub(try googleResponses(answers))
            let store = GoogleWorkspaceCredentialStore(keychain: keychain)
            let api = GoogleWorkspaceAPI(store: store, http: http, now: { Date(timeIntervalSince1970: 10_000) })
            await #expect(throws: GoogleWorkspaceAPIError.authorizationRejected) {
                _ = try await api.gmailProfile(clientID: googleClientID)
            }
            #expect(await api.status(clientID: googleClientID).state == .revocationPending)
            #expect(try await store.load(clientID: googleClientID) == nil)
            #expect(await http.requests().count == answers.count, "No revoke or retry was sent")
            let message = try #require(GoogleWorkspaceAPIError.authorizationRejected.errorDescription)
            #expect(message.contains("connect the account again"))
        }
    }

    @Test("Any other refresh failure leaves the connection as it was")
    func anotherRefreshFailureChangesNothing() async throws {
        for answer in [(400, ["error": "invalid_client"] as [String: Any]), (500, ["error": "server_error"])] {
            let keychain = InMemoryKeychainClient(seed: googleKeychainSeed([
                .previewGoogleWorkspaceOAuthTokens:
                    try JSONEncoder().encode(googleCredential(expiresAt: Date(timeIntervalSince1970: 9_000))),
            ]))
            let api = GoogleWorkspaceAPI(store: GoogleWorkspaceCredentialStore(keychain: keychain),
                                         http: GoogleHTTPStub(try googleResponses([answer])),
                                         now: { Date(timeIntervalSince1970: 10_000) })
            await #expect(throws: (any Error).self) { _ = try await api.gmailProfile(clientID: googleClientID) }
            #expect(await api.status(clientID: googleClientID).state == .connected)
        }
    }

    @Test("A rejection that lands after a reconnect never disables the new connection")
    func aLateRejectionSparesTheReconnect() async throws {
        let store = GoogleWorkspaceCredentialStore(keychain: InMemoryKeychainClient(seed: googleKeychainSeed([
            .previewGoogleWorkspaceOAuthTokens:
                try JSONEncoder().encode(googleCredential(expiresAt: Date(timeIntervalSince1970: 9_000))),
        ])))
        let http = GoogleHTTPGate(try #require(try googleResponses([(400, ["error": "invalid_grant"])]).first))
        let api = GoogleWorkspaceAPI(store: store, http: http, now: { Date(timeIntervalSince1970: 10_000) })
        let call = Task { try await api.gmailProfile(clientID: googleClientID) }
        await http.waitUntilRequestArrives()
        let reconnected = GoogleWorkspaceCredential(clientID: googleClientID, accountEmail: "openbots@example.com",
            accessToken: "new-access", refreshToken: "new-refresh", expiresAt: Date(timeIntervalSince1970: 99_999),
            grantedScopes: GoogleWorkspaceOAuthScopes.required)
        try await store.save(reconnected)
        await http.release()
        await #expect(throws: GoogleWorkspaceAPIError.notConnected) { _ = try await call.value }
        #expect(try await store.load(clientID: googleClientID)?.connectionID == reconnected.connectionID)
    }

    @Test("A disconnect staged before the final credential check prevents the provider request")
    func stagedDisconnectPreventsTheNextRequest() async throws {
        let credential = googleCredential()
        let keychain = GoogleKeychainReadGate(seed: [
            .previewGoogleWorkspaceOAuthTokens: try JSONEncoder().encode(credential),
        ])
        let http = GoogleHTTPStub(try googleResponses([(200, ["emailAddress": "openbots@example.com"])]))
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        let api = GoogleWorkspaceAPI(store: store, http: http,
                                     now: { Date(timeIntervalSince1970: 10_000) })
        let operation = Task { try await api.gmailProfile(clientID: googleClientID) }

        await keychain.waitUntilSecondGoogleTokenRead()
        #expect(try await store.stageForRevocation(clientID: googleClientID)?.state
            == .revocationPending)
        await keychain.releaseSecondGoogleTokenRead()

        await #expect(throws: GoogleWorkspaceAPIError.notConnected) {
            _ = try await operation.value
        }
        #expect(await http.requests().isEmpty)
    }

    @Test("A provider reply arriving after local disconnect is not returned as success")
    func lateReplyAfterDisconnectIsRejected() async throws {
        let credential = googleCredential()
        let keychain = InMemoryKeychainClient(seed: [
            .previewGoogleWorkspaceOAuthTokens: try JSONEncoder().encode(credential),
        ])
        let response = try #require(try googleResponses([
            (200, ["id": "draft-1", "message": ["id": "m-1"]]),
        ]).only)
        let http = GoogleHTTPGate(response)
        let store = GoogleWorkspaceCredentialStore(keychain: keychain)
        let api = GoogleWorkspaceAPI(store: store, http: http,
                                     now: { Date(timeIntervalSince1970: 10_000) })
        let operation = Task {
            try await api.gmailCreateDraft([
                "to": "person@example.com", "subject": "Review", "body": "Body",
            ], clientID: googleClientID)
        }

        await http.waitUntilRequestArrives()
        #expect(try await store.stageForRevocation(clientID: googleClientID)?.state
            == .revocationPending)
        await http.release()

        await #expect(throws: GoogleWorkspaceAPIError.notConnected) {
            _ = try await operation.value
        }
        #expect(await http.requests().count == 1)
    }
}

extension GoogleWorkspaceAPITests {
    @Test("Drive search is GET-only, keeps the bin out, and the search words stay one quoted string")
    func driveSearchIsClosedAndEscaped() async throws {
        let (api, http, _) = try await googleAPI([(200, ["files": [], "incompleteSearch": false])])
        _ = try await api.driveSearch(["query": "O'Brien \\ notes", "limit": 80], clientID: googleClientID)
        let request = try #require(await http.requests().only)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "www.googleapis.com")
        #expect(request.url?.path == "/drive/v3/files")
        let query = googleQuery(request)
        #expect(query["q"] == "trashed = false and fullText contains 'O\\'Brien \\\\ notes'")
        #expect(query["pageSize"] == "50")
        // No sort order on a full-text search: its results come by relevance.
        #expect(query["orderBy"] == nil)
        #expect(query["fields"] == GoogleWorkspaceAPI.driveListFields)
        #expect(query["supportsAllDrives"] == "true")
        #expect(query["includeItemsFromAllDrives"] == "true")

        // With no words, the newest files come first.
        let (recent, recentHTTP, _) = try await googleAPI([(200, ["files": []])])
        _ = try await recent.driveSearch([:], clientID: googleClientID)
        let listed = googleQuery(try #require(await recentHTTP.requests().only))
        #expect(listed["q"] == "trashed = false")
        #expect(listed["orderBy"] == "modifiedTime desc")
        #expect(listed["pageSize"] == "25")
    }

    @Test("A plus sign in a Gmail or Drive search reaches Google as a plus, not a space")
    func plusSignsSurviveTheQuery() async throws {
        let (api, http, _) = try await googleAPI([(200, ["messages": []]), (200, ["files": []])])
        _ = try await api.gmailSearch(["query": "from:a+b@example.com"], clientID: googleClientID)
        _ = try await api.driveSearch(["query": "C++"], clientID: googleClientID)
        let requests = await http.requests()
        #expect(googleQuery(requests[0])["q"] == "from:a+b@example.com")
        #expect(googleQuery(requests[1])["q"] == "trashed = false and fullText contains 'C++'")
    }

    /// Every one of these fields is optional in its tool's schema, and a model
    /// that means "none" often sends an empty string. The helper refused `""`
    /// as "required": the tool said the words could be
    /// left out, and the helper said they could not.
    /// A refusal that told the user to find "the
    /// project that holds the OpenBots Desktop client" would be no help when
    /// Google's answer already names it. The page is built by the app from a service it knows
    /// and a project number of digits only; Google's own address is never used,
    /// so nothing in the answer can choose where the link goes.
    @Test("An API switched off names its Cloud project and the page of its switch, built by the app")
    func apiOffNamesTheProjectAndTheSwitch() async throws {
        let (api, _, _) = try await googleAPI([(403, googleServiceDisabled("drive.googleapis.com"))])
        do {
            _ = try await api.driveSearch([:], clientID: googleClientID)
            Issue.record("a switched-off API answered")
        } catch {
            #expect(error as? GoogleWorkspaceAPIError == .apiDisabled("Google Drive API", enablePage: driveSwitchPage))
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            #expect(text.contains("project 123456"))
            #expect(text.contains("Enable"))
            #expect(!text.contains("console.developers.google.com"))
        }
        // A project that is not a number, a service this build does not know,
        // or Google's own address pointing somewhere else: no page, and the
        // sentence falls back to the steps.
        let odd: [[String: Any]] = [
            googleServiceDisabled("drive.googleapis.com", consumer: "projects/evil.example/x"),
            googleServiceDisabled("drive.googleapis.com", consumer: "folders/123456"),
            googleServiceDisabled("storage.googleapis.com"),
        ]
        for answer in odd {
            let (other, _, _) = try await googleAPI([(403, answer)])
            do {
                _ = try await other.driveSearch([:], clientID: googleClientID)
                Issue.record("a switched-off API answered")
            } catch {
                guard case .apiDisabled(_, let page)? = error as? GoogleWorkspaceAPIError else {
                    Issue.record("not read as switched off: \(error)"); continue
                }
                #expect(page == nil)
                #expect((error as? LocalizedError)?.errorDescription?.contains("APIs & Services") == true)
            }
        }
        let (moved, _, _) = try await googleAPI([(403, googleServiceDisabled(
            "drive.googleapis.com", activationURL: "https://evil.example/enable"))])
        do {
            _ = try await moved.driveSearch([:], clientID: googleClientID)
        } catch {
            #expect(error as? GoogleWorkspaceAPIError == .apiDisabled("Google Drive API", enablePage: driveSwitchPage))
        }
    }

    /// The helper hands its failure to the app as one JSON object; the page
    /// goes as its own field, so the app never has to find it inside words.
    @Test("The helper's failure carries the switch's page beside the sentence, and nothing else does")
    func helperFailureCarriesThePage() throws {
        let off = GoogleWorkspaceAPIError.apiDisabled("Google Drive API", enablePage: driveSwitchPage)
        let payload = GoogleWorkspaceAPIError.helperFailure(off)
        #expect(payload["error"] == off.errorDescription)
        #expect(payload["enable_page"] == driveSwitchPage.absoluteString)
        #expect(Set(payload.keys) == ["error", "enable_page"])
        let plain = GoogleWorkspaceAPIError.helperFailure(GoogleWorkspaceAPIError.notConnected)
        #expect(Set(plain.keys) == ["error"])
        let long = GoogleWorkspaceAPIError.helperFailure(GoogleWorkspaceAPIError.invalidInput(
            String(repeating: "x", count: 900)))
        #expect(long["error"]?.count == 600)
        // What the app accepts back: only a page this build would have built.
        #expect(GoogleWorkspaceAPIError.switchPage(driveSwitchPage.absoluteString) == driveSwitchPage)
        for hostile in [
            "https://evil.example/apis/library/drive.googleapis.com?project=123456",
            "http://console.cloud.google.com/apis/library/drive.googleapis.com?project=123456",
            "https://console.cloud.google.com/apis/library/drive.googleapis.com?project=12a",
            "https://console.cloud.google.com/apis/library/storage.googleapis.com?project=123456",
            "https://console.cloud.google.com/apis/library/drive.googleapis.com?project=123456&next=x",
            "https://user@console.cloud.google.com/apis/library/drive.googleapis.com?project=123456",
            "https://console.cloud.google.com/apis/library/drive.googleapis.com?project=123456#x",
            "not a url",
        ] {
            #expect(GoogleWorkspaceAPIError.switchPage(hostile) == nil, "\(hostile)")
        }
    }

    @Test("An empty or blank optional field reads as left out, in every Google read that has one")
    func emptyOptionalFieldsAreLeftOut() async throws {
        for blank in ["", "   "] {
            let (api, http, _) = try await googleAPI([
                (200, ["messages": []]),
                (200, ["items": [["id": "primary@example.com", "summary": "Primary"]]]),
                (200, ["items": []]),
                (200, ["files": []]),
                (200, ["files": []]),
            ])
            _ = try await api.gmailSearch(["query": blank, "page_token": blank], clientID: googleClientID)
            _ = try await api.calendarSearch([
                "from": "2026-09-12T00:00:00Z", "to": "2026-09-19T00:00:00Z",
                "query": blank, "calendar_id": blank,
            ], clientID: googleClientID)
            _ = try await api.driveSearch(["query": blank, "page_token": blank], clientID: googleClientID)
            _ = try await api.driveListFolder(["folder_id": blank, "page_token": blank], clientID: googleClientID)
            let requests = await http.requests()
            #expect(requests.count == 5)
            guard requests.count == 5 else { continue }
            #expect(googleQuery(requests[0])["q"] == nil && googleQuery(requests[0])["pageToken"] == nil)
            // A blank calendar id lists the user's calendars first, as none named does.
            #expect(requests[1].url?.path.hasSuffix("/users/me/calendarList") == true)
            #expect(googleQuery(requests[2])["q"] == nil)
            #expect(googleQuery(requests[3])["q"] == "trashed = false")
            #expect(googleQuery(requests[3])["orderBy"] == "modifiedTime desc")
            #expect(googleQuery(requests[3])["pageToken"] == nil)
            #expect(googleQuery(requests[4])["q"] == "'root' in parents and trashed = false")
            #expect(googleQuery(requests[4])["pageToken"] == nil)
        }
    }

    @Test("Listing a folder reads its children, the top of Drive by default, and refuses a quote in an id")
    func driveFolderIsClosed() async throws {
        let (api, http, _) = try await googleAPI([(200, ["files": []]), (200, ["files": []])])
        _ = try await api.driveListFolder([:], clientID: googleClientID)
        _ = try await api.driveListFolder(["folder_id": "1AbC-d_E", "limit": 500], clientID: googleClientID)
        let requests = await http.requests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/drive/v3/files" })
        #expect(googleQuery(requests[0])["q"] == "'root' in parents and trashed = false")
        #expect(googleQuery(requests[0])["orderBy"] == "folder,name")
        #expect(googleQuery(requests[1])["q"] == "'1AbC-d_E' in parents and trashed = false")
        #expect(googleQuery(requests[1])["pageSize"] == "100")
        // An empty id is the top of Drive, as a missing one is
        // (emptyOptionalFieldsAreLeftOut); a malformed one is still refused.
        for bad in ["x' or 'y", "../files", "a b"] {
            await #expect(throws: GoogleWorkspaceAPIError.self) {
                _ = try await api.driveListFolder(["folder_id": bad], clientID: googleClientID)
            }
        }
        #expect(await http.requests().count == 2)
    }

    @Test("Docs, Sheets and Slides are read through Drive's export as text, CSV and text")
    func driveReadsGoogleFilesByExport() async throws {
        let kinds: [(String, String)] = [
            ("application/vnd.google-apps.document", "text/plain"),
            ("application/vnd.google-apps.spreadsheet", "text/csv"),
            ("application/vnd.google-apps.presentation", "text/plain"),
        ]
        for (mime, export) in kinds {
            let (api, http, _) = try await googleAPI([
                (200, ["id": "file1", "name": "Plan", "mimeType": mime,
                       "modifiedTime": "2026-09-20T10:11:12.345Z",
                       "owners": [["displayName": "OpenBots", "emailAddress": "openbots@example.com"]]]),
                // Drive's text export starts with a byte-order mark.
                (200, Data("\u{FEFF}Line one\nLine two, é".utf8)),
            ])
            let data = try await api.driveReadFile(["id": "file1"], clientID: googleClientID)
            // Checked in the bytes: Foundation's JSON reader drops a leading
            // mark on the way back in, and the node server's does not.
            #expect(data.range(of: Data([0xEF, 0xBB, 0xBF])) == nil)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["text"] as? String == "Line one\nLine two, é")
            #expect(object["readAs"] as? String == export)
            #expect((object["file"] as? [String: Any])?["name"] as? String == "Plan")
            let requests = await http.requests()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "www.googleapis.com" })
            #expect(requests[0].url?.path == "/drive/v3/files/file1")
            #expect(googleQuery(requests[0])["fields"] == GoogleWorkspaceAPI.driveFileFields)
            #expect(requests[1].url?.path == "/drive/v3/files/file1/export")
            #expect(googleQuery(requests[1])["mimeType"] == export)
        }
    }

    @Test("A shortcut is followed once to its file, and a plain file downloads only under the cap")
    func driveFollowsShortcutsAndCapsDownloads() async throws {
        let (api, http, _) = try await googleAPI([
            (200, ["id": "s1", "name": "Link to Notes", "mimeType": "application/vnd.google-apps.shortcut",
                   "shortcutDetails": ["targetId": "t1", "targetMimeType": "text/markdown"]]),
            (200, ["id": "t1", "name": "Notes.md", "mimeType": "text/markdown", "size": "12"]),
            (200, Data("# Notes\nhi".utf8)),
        ])
        let data = try await api.driveReadFile(["id": "s1"], clientID: googleClientID)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["text"] as? String == "# Notes\nhi")
        #expect((object["file"] as? [String: Any])?["name"] as? String == "Notes.md")
        let requests = await http.requests()
        #expect(requests.map { $0.url?.path } == ["/drive/v3/files/s1", "/drive/v3/files/t1", "/drive/v3/files/t1"])
        #expect(googleQuery(requests[2])["alt"] == "media")

        // A plain file whose size Drive did not state is held to the same cap
        // once it arrives.
        let (unsized, _, _) = try await googleAPI([
            (200, ["id": "u1", "name": "No size.txt", "mimeType": "text/plain"]),
            (200, Data(repeating: 0x61, count: GoogleWorkspaceAPI.maximumDriveDownloadBytes + 1)),
        ])
        do {
            _ = try await unsized.driveReadFile(["id": "u1"], clientID: googleClientID)
            Issue.record("a plain file with no size was read past the cap")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription?.contains("No size.txt") == true)
        }

        let big = GoogleWorkspaceAPI.maximumDriveDownloadBytes + 1
        let (capped, cappedHTTP, _) = try await googleAPI([
            (200, ["id": "b1", "name": "Huge log.txt", "mimeType": "text/plain", "size": String(big)]),
        ])
        do {
            _ = try await capped.driveReadFile(["id": "b1"], clientID: googleClientID)
            Issue.record("a file over the cap was downloaded")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            #expect(text.contains("Huge log.txt") && text.contains("1 MB"))
        }
        #expect(await cappedHTTP.requests().count == 1)
    }

    @Test("A PDF, a folder and a shortcut to a shortcut are refused by name, with nothing downloaded")
    func driveRefusesWhatItCannotRead() async throws {
        let cases: [([String: Any], String)] = [
            (["id": "p1", "name": "Scan.pdf", "mimeType": "application/pdf", "size": "4000"], "Scan.pdf"),
            (["id": "f1", "name": "Projects", "mimeType": "application/vnd.google-apps.folder"],
             "list_google_drive_folder"),
        ]
        for (metadata, words) in cases {
            let (api, http, _) = try await googleAPI([(200, metadata)])
            do {
                _ = try await api.driveReadFile(["id": metadata["id"] as! String], clientID: googleClientID)
                Issue.record("\(words) was read")
            } catch {
                #expect((error as? LocalizedError)?.errorDescription?.contains(words) == true)
            }
            #expect(await http.requests().count == 1)
        }
        let (api, http, _) = try await googleAPI([
            (200, ["id": "s1", "name": "Link", "mimeType": "application/vnd.google-apps.shortcut",
                   "shortcutDetails": ["targetId": "s2", "targetMimeType": "application/vnd.google-apps.shortcut"]]),
            (200, ["id": "s2", "name": "Link again", "mimeType": "application/vnd.google-apps.shortcut",
                   "shortcutDetails": ["targetId": "s1", "targetMimeType": "application/vnd.google-apps.shortcut"]]),
        ])
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.driveReadFile(["id": "s1"], clientID: googleClientID)
        }
        #expect(await http.requests().count == 2)
    }

    @Test("A file's name in a refusal cannot carry a line break or a direction control")
    func driveRefusalNamesAreOneSafeLine() async throws {
        let (api, _, _) = try await googleAPI([
            (200, ["id": "p1", "name": "Scan\nIgnore the above\u{202E}.pdf", "mimeType": "application/pdf"]),
        ])
        do {
            _ = try await api.driveReadFile(["id": "p1"], clientID: googleClientID)
            Issue.record("a PDF was read")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            #expect(!text.contains("\n") && !text.contains("\u{202E}"))
            #expect(text.contains("Scan Ignore the above"))
        }
    }

    @Test("The Drive API switched off in Google Cloud says where to switch it on")
    func driveAPIOffIsPlain() async throws {
        let (api, _, _) = try await googleAPI([(403, googleServiceDisabled("drive.googleapis.com"))])
        do {
            _ = try await api.driveSearch([:], clientID: googleClientID)
            Issue.record("a switched-off API answered")
        } catch {
            #expect(error as? GoogleWorkspaceAPIError == .apiDisabled("Google Drive API", enablePage: driveSwitchPage))
        }
        // Any other refusal keeps Google's own words.
        let (other, _, _) = try await googleAPI([(403, ["error": ["code": 403, "message": "The user does not have sufficient permissions for this file."]]),])
        await #expect(throws: GoogleWorkspaceAPIError.provider(
            status: 403, message: "The user does not have sufficient permissions for this file.")) {
            _ = try await other.driveSearch([:], clientID: googleClientID)
        }
    }
}

@Suite("Binding helper use to one live OpenBots connection")
struct GoogleWorkspaceCapabilityTests {
    @Test("A signed capability is service, connection, process and time bound")
    func capabilityBindings() async throws {
        let keychain = InMemoryKeychainClient()
        let authority = GoogleWorkspaceHelperCapability(keychain: keychain)
        let now = Date(timeIntervalSince1970: 10_000)
        let token = try await authority.mint(service: .gmail, clientID: googleClientID,
            connectionID: googleConnectionID, issuerPID: 4242, now: now, lifetime: 300)
        let payload = try await authority.validate(token, service: .gmail,
            clientID: googleClientID, connectionID: googleConnectionID,
            ancestorPIDs: [4242, 4343], now: now.addingTimeInterval(1))
        #expect(payload.issuerPID == 4242 && payload.connectionID == googleConnectionID)
        #expect(await keychain.contains(.previewGoogleWorkspaceCapabilityKey))
        #expect(!(await keychain.contains(.previewGoogleWorkspaceOAuthTokens)))

        await #expect(throws: GoogleWorkspaceCapabilityError.wrongService) {
            _ = try await authority.validate(token, service: .calendar,
                clientID: googleClientID, connectionID: googleConnectionID,
                ancestorPIDs: [4242], now: now)
        }
        await #expect(throws: GoogleWorkspaceCapabilityError.wrongConnection) {
            _ = try await authority.validate(token, service: .gmail,
                clientID: googleClientID, connectionID: UUID(),
                ancestorPIDs: [4242], now: now)
        }
        await #expect(throws: GoogleWorkspaceCapabilityError.wrongProcess) {
            _ = try await authority.validate(token, service: .gmail,
                clientID: googleClientID, connectionID: googleConnectionID,
                ancestorPIDs: [9999], now: now)
        }
        await #expect(throws: GoogleWorkspaceCapabilityError.expired) {
            _ = try await authority.validate(token, service: .gmail,
                clientID: googleClientID, connectionID: googleConnectionID,
                ancestorPIDs: [4242], now: now.addingTimeInterval(301))
        }
        let pieces = token.split(separator: ".")
        let signature = try #require(pieces.last)
        let replacement = signature.first == "a" ? "b" : "a"
        let tampered = String(pieces[0]) + "." + replacement + String(signature.dropFirst())
        await #expect(throws: GoogleWorkspaceCapabilityError.self) {
            _ = try await authority.validate(tampered, service: .gmail,
                clientID: googleClientID, connectionID: googleConnectionID,
                ancestorPIDs: [4242], now: now)
        }
    }

    @Test("A Drive capability opens Drive and nothing else")
    func driveCapabilityIsItsOwnService() async throws {
        #expect(GoogleWorkspaceService(rawValue: "drive") == .drive)
        let authority = GoogleWorkspaceHelperCapability(keychain: InMemoryKeychainClient())
        let now = Date(timeIntervalSince1970: 10_000)
        let token = try await authority.mint(service: .drive, clientID: googleClientID,
            connectionID: googleConnectionID, issuerPID: 4242, now: now, lifetime: 300)
        _ = try await authority.validate(token, service: .drive, clientID: googleClientID,
            connectionID: googleConnectionID, ancestorPIDs: [4242], now: now)
        for other in [GoogleWorkspaceService.gmail, .calendar] {
            await #expect(throws: GoogleWorkspaceCapabilityError.wrongService) {
                _ = try await authority.validate(token, service: other, clientID: googleClientID,
                    connectionID: googleConnectionID, ancestorPIDs: [4242], now: now)
            }
        }
    }

    @Test("Lifecycle actions require the exact installed helper and exact app parent")
    func directHelperInvocationIsNotAnAuthorizationPath() throws {
        #expect(GoogleWorkspaceInstalledCallerPolicy.acceptsLifecycleCaller(
            helperPath: GoogleWorkspaceInstalledCallerPolicy.helperPath,
            parentPath: GoogleWorkspaceInstalledCallerPolicy.appPath))
        #expect(!GoogleWorkspaceInstalledCallerPolicy.acceptsLifecycleCaller(
            helperPath: "/private/tmp/openbots-google-helper",
            parentPath: GoogleWorkspaceInstalledCallerPolicy.appPath))
        #expect(!GoogleWorkspaceInstalledCallerPolicy.acceptsLifecycleCaller(
            helperPath: GoogleWorkspaceInstalledCallerPolicy.helperPath,
            parentPath: "/private/tmp/OpenBots Next"))
        #expect(!GoogleWorkspaceInstalledCallerPolicy.acceptsOperationalHelper(
            path: "/private/tmp/openbots-google-helper"))
    }
}

private struct GooglePreparationFixture {
    let root: URL
    let helper: URL

    init(status: GoogleWorkspaceConnectionStatus = .init(state: .connected,
         accountEmail: "openbots@example.com", connectionID: googleConnectionID),
         clientConfiguration: GoogleWorkspaceClientConfigurationStatus = .init(state: .ready)) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-google-preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appendingPathComponent(GoogleWorkspaceConnectorPreparation.helperName)
        let data = try JSONEncoder().encode(status)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
        let configurationData = try JSONEncoder().encode(clientConfiguration)
        let configurationJSON = String(decoding: configurationData, as: UTF8.self)
            .replacingOccurrences(of: "'", with: "'\\''")
        let body = "#!/bin/sh\ncase \"$1\" in\n"
            + "  status) printf '%s\\n' '\(json)' ;;\n"
            + "  client_configuration_status) printf '%s\\n' '\(configurationJSON)' ;;\n"
            + "  import_client_configuration) /bin/cat >/dev/null; printf '%s\\n' '\(configurationJSON)' ;;\n"
            + "  authorize_connector) printf '%s\\n' '{\"capability\":\"test-capability\"}' ;;\n"
            + "  *) exit 2 ;;\nesac\n"
        try Data(body.utf8).write(to: helper)
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                        ofItemAtPath: helper.path)
    }

    func remove() { try? FileManager().removeItem(at: root) }
}

private func googleLaunch(_ command: String,
                          clientID: String = googleClientID) -> ConnectorLaunchConfiguration {
    .init(serverKey: "openbots_" + String(repeating: "a", count: 64), transport: .stdio,
          command: command, arguments: ["--client-id", clientID])
}

@Suite("Preparing the app-owned Google servers")
struct GoogleWorkspacePreparationTests {
    @Test("All three rows launch fenced with one helper, one client, and separate roles")
    func bothRowsAreSeparateAndFenced() throws {
        let fixture = try GooglePreparationFixture(); defer { fixture.remove() }
        let preparation = GoogleWorkspaceConnectorPreparation(
            helperCandidateURLs: [fixture.helper], interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let gmail = try preparation.server(for: googleLaunch(GoogleWorkspaceConnectorPreparation.gmailCommand),
            profileURL: nil, temporaryDirectoryURL: fixture.root, fence: fence)
        let calendar = try preparation.server(for: googleLaunch(GoogleWorkspaceConnectorPreparation.calendarCommand),
            profileURL: nil, temporaryDirectoryURL: fixture.root, fence: fence)
        let drive = try preparation.server(for: googleLaunch(GoogleWorkspaceConnectorPreparation.driveCommand),
            profileURL: nil, temporaryDirectoryURL: fixture.root, fence: fence)
        #expect(gmail.role == .googleGmailReadDraft)
        #expect(calendar.role == .googleCalendarRead)
        #expect(drive.role == .googleDriveRead)
        #expect(gmail.program.isFenced && calendar.program.isFenced && drive.program.isFenced)
        #expect(gmail.environment["OPENBOTS_GOOGLE_SERVICE"] == "gmail")
        #expect(calendar.environment["OPENBOTS_GOOGLE_SERVICE"] == "calendar")
        #expect(drive.environment["OPENBOTS_GOOGLE_SERVICE"] == "drive")
        #expect(preparation.prepares(googleLaunch(GoogleWorkspaceConnectorPreparation.driveCommand)))
        #expect(gmail.environment["OPENBOTS_GOOGLE_HELPER"] == fixture.helper.resolvingSymlinksInPath().path)
        #expect(gmail.environment["OPENBOTS_GOOGLE_CLIENT_ID"] == googleClientID)
        #expect(gmail.environment["OPENBOTS_GOOGLE_CAPABILITY"] == "test-capability")
        #expect(gmail.environment.keys.allSatisfy { !$0.localizedCaseInsensitiveContains("secret") })
        #expect(gmail.options.isEmpty)
        #expect(!preparation.needsOwnedProfile)
    }

    @Test("No client id and no account are setup states, never a half launch")
    func setupFailsClosed() throws {
        let fixture = try GooglePreparationFixture(status: .init(state: .disconnected)); defer { fixture.remove() }
        let preparation = GoogleWorkspaceConnectorPreparation(
            helperCandidateURLs: [fixture.helper], interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        #expect(preparation.availability(for: googleLaunch(
            GoogleWorkspaceConnectorPreparation.gmailCommand, clientID: "not-configured"))?.badge == "needs setup")
        #expect(preparation.availability(for: googleLaunch(
            GoogleWorkspaceConnectorPreparation.calendarCommand))?.badge == "needs setup")
        #expect(throws: GoogleWorkspaceConnectorPreparation.Failure.notConnected) {
            _ = try preparation.server(for: googleLaunch(GoogleWorkspaceConnectorPreparation.calendarCommand),
                profileURL: nil, temporaryDirectoryURL: fixture.root, fence: FenceProxyResource())
        }
    }

    @Test("A missing Desktop client configuration blocks launch before capability minting")
    func clientConfigurationFailsClosed() throws {
        let reason = "Import the original Google Desktop OAuth client JSON before connecting."
        let fixture = try GooglePreparationFixture(
            clientConfiguration: .init(state: .missing, reason: reason))
        defer { fixture.remove() }
        let preparation = GoogleWorkspaceConnectorPreparation(
            helperCandidateURLs: [fixture.helper],
            interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        #expect(preparation.availability(for: googleLaunch(
            GoogleWorkspaceConnectorPreparation.gmailCommand))?.reason == reason)
        #expect(throws: GoogleWorkspaceConnectorPreparation.Failure.clientConfigurationMissing) {
            _ = try preparation.server(for: googleLaunch(
                GoogleWorkspaceConnectorPreparation.gmailCommand), profileURL: nil,
                temporaryDirectoryURL: fixture.root, fence: FenceProxyResource())
        }
    }
}

@Suite("What Google connector actions say")
struct GoogleWorkspaceApprovalPolicyTests {
    private func request(_ tool: String, _ input: [String: Any] = [:]) throws -> ClaudeTextPermissionRequest {
        ClaudeTextPermissionRequest(requestID: "request", toolUseID: "tool",
            toolName: "mcp__google__\(tool)",
            inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
    }

    @Test("Every advertised read is quiet and nothing else becomes one")
    func quietSetsAreExact() throws {
        #expect(ClaudeTextGoogleGmailApprovalPolicy.quietReads
            == ["gmail_account", "search_gmail", "read_gmail_message", "read_gmail_thread"])
        #expect(ClaudeTextGoogleCalendarApprovalPolicy.quietReads
            == ["list_google_calendars", "search_google_events", "read_google_event"])
        #expect(ClaudeTextGoogleDriveApprovalPolicy.quietReads
            == ["search_google_drive", "list_google_drive_folder", "read_google_drive_file"])
        for tool in ClaudeTextGoogleGmailApprovalPolicy.quietReads {
            guard case .allowQuietly = ClaudeTextConnectorApprovalPolicy.decide(
                try request(tool), botName: "Kite", role: .googleGmailReadDraft) else {
                Issue.record("\(tool) was not a quiet Gmail read"); continue
            }
        }
        guard case .ask = ClaudeTextConnectorApprovalPolicy.decide(
            try request("send_gmail"), botName: "Kite", role: .googleGmailReadDraft) else {
            Issue.record("an unshipped send-like verb became quiet"); return
        }
    }

    @Test("Drive's reads are quiet and say what was asked; anything else asks")
    func driveReadsAreQuietAndNamed() throws {
        let expected = [
            "search_google_drive": "Searched the OpenBots Google Drive",
            "list_google_drive_folder": "Listed a folder in the OpenBots Google Drive",
            "read_google_drive_file": "Read a file in the OpenBots Google Drive",
        ]
        for (tool, line) in expected {
            guard case .allowQuietly(let activity) = ClaudeTextConnectorApprovalPolicy.decide(
                try request(tool), botName: "Kite", role: .googleDriveRead) else {
                Issue.record("\(tool) was not a quiet Drive read"); continue
            }
            #expect(activity == line)
        }
        guard case .ask(let card) = ClaudeTextConnectorApprovalPolicy.decide(
            try request("delete_google_drive_file"), botName: "Kite", role: .googleDriveRead) else {
            Issue.record("an unshipped Drive verb became quiet"); return
        }
        #expect(card.title == "Do something in Google Drive")
        #expect(card.activity.hasPrefix("Asked to"))
    }

    @Test("A draft asks, names every recipient, and says nothing is sent")
    func draftCardIsHonest() throws {
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try request("create_gmail_draft", ["to": "a@example.com", "bcc": "b@example.com",
                                                "subject": "Hello", "body": "Body"]),
            botName: "Kite", role: .googleGmailReadDraft)
        guard case .ask(let card) = decision else { Issue.record("a draft did not ask"); return }
        #expect(card.title == "Save a draft in Gmail")
        #expect(card.detail.contains("Nothing is sent"))
        #expect(card.detail.contains("a@example.com") && card.detail.contains("b@example.com"))
        #expect(card.kind == .metadataMutation)
    }

    /// The draft card shows the words as the Gmail send card does, not only
    /// recipients and subject: the subject
    /// on its own labelled line, then the body whole after a blank line, under
    /// the send card's bound, and a body past it is refused.
    @Test("A draft card shows the words whole, with the send card's bound and layout")
    func draftCardShowsTheBody() throws {
        func decide(_ body: String) throws -> ClaudeTextWorkDecision {
            ClaudeTextConnectorApprovalPolicy.decide(
                try request("create_gmail_draft", ["to": "a@example.com", "subject": "Hello", "body": body]),
                botName: "Kite", role: .googleGmailReadDraft)
        }
        guard case .ask(let card) = try decide("Hi Anna,\r\n\r\nThe numbers\tare in.\rAlex") else {
            Issue.record("a draft did not ask"); return
        }
        // Line ends are shown as the draft saves them.
        #expect(card.detail.hasSuffix("\nSubject: Hello\n\nHi Anna,\n\nThe numbers\tare in.\nAlex"), "\(card.detail)")
        let proposal = try GoogleGmailDraftProposal(input: ["to": "a@example.com", "subject": "Hello",
                                                            "body": "Hi\r\nthere"])
        #expect(proposal.body == "Hi\nthere")

        let longest = String(repeating: "w", count: GoogleGmailSendProposal.maximumBodyScalars)
        guard case .ask(let whole) = try decide(longest) else { Issue.record("the longest body did not ask"); return }
        #expect(whole.detail.hasSuffix("\n\n" + longest))
        // With the longest heading it still fits the approvals record.
        let address = String(repeating: "a", count: 88) + "@example.com"
        let worstInput: [String: Any] = [
            "to": [address, address, String(repeating: "b", count: 48) + "@example.com"].joined(separator: ", "),
            "subject": String(repeating: "S", count: GoogleGmailDraftProposal.maximumSubjectCharacters),
            "body": longest]
        let worstProposal = try GoogleGmailDraftProposal(input: worstInput)
        #expect(worstProposal.recipientDescription.count > 260)
        guard case .ask(let worst) = ClaudeTextConnectorApprovalPolicy.decide(
            try request("create_gmail_draft", worstInput), botName: String(repeating: "K", count: 200),
            role: .googleGmailReadDraft) else { Issue.record("the worst draft did not ask"); return }
        #expect(worst.detail.hasSuffix("\n\n" + longest))
        #expect(worst.detail.count < 2_000, "\(worst.detail.count)")

        for refused in [longest + "w", "Pay \u{202E}evil\u{202C} now", "Hidden\u{200B}code"] {
            #expect(throws: GoogleWorkspaceAPIError.self) {
                _ = try GoogleGmailDraftProposal(input: ["to": "a@example.com", "subject": "Hello", "body": refused])
            }
            guard case .ask(let fix) = try decide(refused) else { Issue.record("a refused body did not ask"); continue }
            #expect(fix.title == "Fix the Gmail draft details")
            #expect(fix.detail.contains("\(GoogleGmailSendProposal.maximumBodyScalars) characters"), "\(fix.detail)")
            #expect(!fix.detail.contains("evil") && !fix.detail.contains("Hidden"))
        }
    }

    @Test("The card and MIME share one exact bounded proposal")
    func draftProposalIsOneBoundary() throws {
        let subject = String(repeating: "S", count: GoogleGmailDraftProposal.maximumSubjectCharacters)
        let input: [String: Any] = [
            "to": "Alice <a@example.com>", "cc": "c@example.com",
            "bcc": "hidden@example.com", "subject": subject, "body": "Line one\r\nLine two",
        ]
        let proposal = try GoogleGmailDraftProposal(input: input)
        #expect(proposal.recipientDescription
            == "To: Alice <a@example.com>; Cc: c@example.com; Bcc: hidden@example.com")
        let decision = ClaudeTextConnectorApprovalPolicy.decide(
            try request("create_gmail_draft", input), botName: "Kite", role: .googleGmailReadDraft)
        guard case .ask(let card) = decision else { Issue.record("the valid draft did not ask"); return }
        #expect(card.detail.contains(proposal.recipientDescription))
        #expect(card.detail.contains(subject))

        var tooLong = input
        tooLong["subject"] = subject + "X"
        #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try GoogleGmailDraftProposal(input: tooLong)
        }
        let refused = ClaudeTextConnectorApprovalPolicy.decide(
            try request("create_gmail_draft", tooLong), botName: "Kite", role: .googleGmailReadDraft)
        guard case .ask(let invalid) = refused else { Issue.record("the invalid proposal did not ask"); return }
        #expect(invalid.title == "Fix the Gmail draft details")
        #expect(invalid.detail.contains("will refuse to save it"))
    }

    @Test("Hidden direction controls are removed before both display and MIME")
    func hiddenCharactersCannotSplitDisplayFromDraft() throws {
        let proposal = try GoogleGmailDraftProposal(input: [
            "to": "a@exam\u{202E}ple.com", "subject": "Invo\u{202E}ice", "body": "Body",
        ])
        #expect(proposal.to == ["a@example.com"])
        #expect(proposal.subject == "Invoice")
        let decoded = try #require(Data(base64Encoded: proposal.rawMessageBase64URL()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .paddingBase64))
        let mime = String(decoding: decoded, as: UTF8.self)
        #expect(!mime.contains("\u{202E}"))
    }
}

@Suite("The Google MCP tool surface")
struct GoogleWorkspaceScriptTests {
    @Test("Gmail advertises reads and one draft verb, with no send or arbitrary request")
    func gmailToolsAreClosed() throws {
        let names = try toolNames(service: "gmail")
        #expect(names == ["gmail_account", "search_gmail", "read_gmail_message",
                          "read_gmail_thread", "create_gmail_draft"])
        #expect(names.allSatisfy { !$0.contains("send") && !$0.contains("delete")
                                  && !$0.contains("request") })
        let script = try String(contentsOf: #require(GoogleWorkspaceConnectorPreparation.scriptURL),
                                encoding: .utf8)
        #expect(!script.contains("drafts/send"))
        #expect(!script.contains("messages/send"))
    }

    @Test("Gmail send advertises the account check and one send verb, nothing else")
    func gmailSendToolsAreClosed() throws {
        #expect(try toolNames(service: "gmail_send") == ["gmail_send_account", "send_gmail_message"])
    }

    @Test("A send that times out says it may have gone, so nobody sends it twice")
    func sendTimeoutSaysItMayHaveGone() throws {
        let script = try String(contentsOf: #require(GoogleWorkspaceConnectorPreparation.scriptURL), encoding: .utf8)
        #expect(script.contains("command === COMMANDS.send_gmail_message"))
        #expect(script.contains("the message may already have been sent. Do not send it again"))
    }

    @Test("Calendar advertises exactly three reads")
    func calendarToolsAreClosed() throws {
        #expect(try toolNames(service: "calendar")
            == ["list_google_calendars", "search_google_events", "read_google_event"])
    }

    @Test("Drive advertises exactly three reads and no verb that writes")
    func driveToolsAreClosed() throws {
        let names = try toolNames(service: "drive")
        #expect(names == ["search_google_drive", "list_google_drive_folder", "read_google_drive_file"])
        for word in ["create", "update", "delete", "share", "move", "copy", "upload", "trash", "request"] {
            #expect(names.allSatisfy { !$0.contains(word) })
        }
        #expect(try toolNames(service: "nonsense").isEmpty)
    }

    @Test("Drive answers render each file's name, id and kind, and a long file says where to go on")
    func driveAnswersRender() throws {
        let long = String(repeating: "a", count: 45_000) + "END"
        let helper = try stubHelper([
            "drive_search": ["files": [
                ["id": "1AbC", "name": "Budget 2026", "mimeType": "application/vnd.google-apps.spreadsheet",
                 "modifiedTime": "2026-09-20T10:11:12.345Z",
                 "owners": [["displayName": "OpenBots", "emailAddress": "openbots@example.com"]]],
                ["id": "2DeF", "name": "Link to Notes", "mimeType": "application/vnd.google-apps.shortcut",
                 "shortcutDetails": ["targetId": "3GhI", "targetMimeType": "text/plain"]],
            ], "nextPageToken": "~!!~token"],
            "drive_read_file": ["file": ["id": "1AbC", "name": "Budget 2026",
                                         "mimeType": "application/vnd.google-apps.document"],
                                "text": long, "readAs": "text/plain"],
        ])
        defer { try? FileManager().removeItem(at: helper.deletingLastPathComponent()) }

        let search = try toolText(toolCall(service: "drive", name: "search_google_drive",
                                           arguments: ["query": "budget"], helper: helper))
        #expect(search.contains("Budget 2026"))
        #expect(search.contains("id: 1AbC"))
        #expect(search.contains("Google Sheet"))
        #expect(search.contains("shortcut to: 3GhI"))
        #expect(search.contains("~!!~token"))

        let first = try toolText(toolCall(service: "drive", name: "read_google_drive_file",
                                          arguments: ["id": "1AbC"], helper: helper))
        #expect(first.contains("Budget 2026"))
        #expect(!first.contains("END"))
        #expect(first.contains("start: 40000"))
        let rest = try toolText(toolCall(service: "drive", name: "read_google_drive_file",
                                         arguments: ["id": "1AbC", "start": 40_000], helper: helper))
        #expect(rest.contains("END"))
        #expect(!rest.contains("start: 80000"))
    }

    @Test("A tool named like a built-in of JavaScript is an unknown tool, not a call")
    func builtInNamesAreUnknownTools() throws {
        for name in ["constructor", "toString", "__proto__", "hasOwnProperty"] {
            let result = try toolCall(service: "drive", name: name, arguments: [:])
            #expect(result["isError"] as? Bool == true, "\(name) was not refused")
            let content = try #require(result["content"] as? [[String: Any]])
            #expect((content.first?["text"] as? String)?.contains("unknown tool") == true)
        }
    }

    @Test("An empty Drive file says so, from any starting point")
    func emptyDriveFileIsPlain() throws {
        let helper = try stubHelper(["drive_read_file": [
            "file": ["id": "e1", "name": "Empty.txt", "mimeType": "text/plain"], "text": "", "readAs": "text/plain",
        ]])
        defer { try? FileManager().removeItem(at: helper.deletingLastPathComponent()) }
        for start in [0, 10] {
            let text = try toolText(toolCall(service: "drive", name: "read_google_drive_file",
                                             arguments: ["id": "e1", "start": start], helper: helper))
            #expect(text.contains("The file is empty."))
            #expect(!text.contains("of 0"))
        }
    }

    @Test("An invalid supplied calendar date errors instead of silently reading this week")
    func invalidDateDoesNotBecomeADefault() throws {
        let result = try toolCall(service: "calendar", name: "search_google_events",
                                  arguments: ["from": "not-a-date"])
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect((content.first?["text"] as? String)?.contains("date is invalid") == true)
    }

    private func toolNames(service: String) throws -> [String] {
        let node = try #require(InstalledToolResolution()
            .firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs))
        let script = try #require(GoogleWorkspaceConnectorPreparation.scriptURL)
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = node; process.arguments = [script.path]
        process.environment = [
            "OPENBOTS_GOOGLE_HELPER": "/usr/bin/false",
            "OPENBOTS_GOOGLE_CLIENT_ID": googleClientID,
            "OPENBOTS_GOOGLE_SERVICE": service,
            "OPENBOTS_GOOGLE_CAPABILITY": "test-capability",
        ]
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:],
        ], options: [.sortedKeys])
        input.fileHandleForWriting.write(request + Data("\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    /// A helper that answers each command with a canned JSON object, as the
    /// real one answers with Google's.
    private func stubHelper(_ answers: [String: Any]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-google-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
        var body = "#!/bin/sh\n/bin/cat >/dev/null\ncase \"$1\" in\n"
        for (command, answer) in answers {
            let file = root.appendingPathComponent(command + ".json")
            try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys]).write(to: file)
            body += "  \(command)) /bin/cat '\(file.path)' ;;\n"
        }
        body += "  *) exit 2 ;;\nesac\n"
        let helper = root.appendingPathComponent("helper")
        try Data(body.utf8).write(to: helper)
        try FileManager().setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))],
                                        ofItemAtPath: helper.path)
        return helper
    }

    private func toolText(_ result: [String: Any]) throws -> String {
        #expect(result["isError"] as? Bool != true)
        let content = try #require(result["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }

    private func toolCall(service: String, name: String,
                          arguments: [String: Any], helper: URL? = nil) throws -> [String: Any] {
        let node = try #require(InstalledToolResolution()
            .firstResolved(of: BrowserConnectorPreparation.defaultInterpreterURLs))
        let script = try #require(GoogleWorkspaceConnectorPreparation.scriptURL)
        let process = Process(); let input = Pipe(); let output = Pipe()
        process.executableURL = node; process.arguments = [script.path]
        process.environment = [
            "OPENBOTS_GOOGLE_HELPER": helper?.path ?? "/usr/bin/false",
            "OPENBOTS_GOOGLE_CLIENT_ID": googleClientID,
            "OPENBOTS_GOOGLE_SERVICE": service,
            "OPENBOTS_GOOGLE_CAPABILITY": "test-capability",
        ]
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ], options: [.sortedKeys])
        input.fileHandleForWriting.write(request + Data("\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["result"] as? [String: Any])
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private extension String {
    var paddingBase64: String {
        self + String(repeating: "=", count: (4 - count % 4) % 4)
    }
}

// MARK: - Gmail send

private func sendInput(_ changes: [String: Any?] = [:]) -> [String: Any] {
    var input: [String: Any] = [
        "from": "openbots@example.com", "to": "alex@example.com",
        "subject": "Hello from Kite", "body": "First line.\n\nSecond paragraph, café ☕.",
    ]
    for (key, value) in changes { input[key] = value }
    return input
}

private func sendRequest(_ tool: String, _ input: [String: Any]) throws -> ClaudeTextPermissionRequest {
    ClaudeTextPermissionRequest(requestID: "request", toolUseID: "tool", toolName: "mcp__google_send__\(tool)",
        inputJSON: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
}

private func temporaryLedger() -> GoogleGmailSendApprovalLedger {
    GoogleGmailSendApprovalLedger(directory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("openbots-gmail-send-\(UUID().uuidString)", isDirectory: true))
}

@Suite("Gmail send: one exact card for every message")
struct GoogleGmailSendTests {
    @Test("A plain message is accepted field for field, and nothing about it is changed")
    func acceptsAPlainMessage() throws {
        let proposal = try GoogleGmailSendProposal(input: sendInput(["to": "a@example.com, b@example.org"]))
        #expect(proposal.from == "openbots@example.com")
        #expect(proposal.to == ["a@example.com", "b@example.org"])
        #expect(proposal.subject == "Hello from Kite")
        #expect(proposal.body == "First line.\n\nSecond paragraph, café ☕.")
    }

    @Test("Everything the card could not show exactly is refused, never stripped or cut")
    func refusesWhatTheCardCannotShow() {
        let cases: [([String: Any?], String)] = [
            (["extra": "x"], "an unexpected field"),
            (["\u{FEFF}body": "x"], "a BOM-prefixed key"),
            (["to": nil], "no recipient"),
            (["subject": 7], "a subject that is not text"),
            (["to": "Alex <alex@example.com>"], "a display name"),
            (["to": "alex\u{200B}@example.com"], "a hidden character in an address"),
            (["to": "a@example.com, b@example.com, c@example.com, d@example.com"], "four recipients"),
            (["to": "a@example.com,,b@example.com"], "an empty recipient"),
            (["to": "zoë@example.com"], "a non-ASCII address"),
            (["from": "OpenBots"], "a sender that is not an address"),
            (["subject": "Two\nlines"], "a subject on two lines"),
            (["subject": " padded"], "a subject starting with a space"),
            (["subject": String(repeating: "s", count: 121)], "a subject over 120"),
            (["subject": "OK\u{E0041}"], "a tag character in the subject"),
            (["body": ""], "an empty body"),
            (["body": String(repeating: "b", count: 1_301)], "a body over the card's room"),
            (["body": "OK\u{2060}"], "a hidden character in the body"),
            (["body": "Line\r\nline"], "a carriage return"),
            (["body": "Ends with a space "], "a trailing space"),
            (["body": "\nStarts blank"], "a blank first line"),
            (["body": "One\n\n\nTwo"], "two blank lines in a row"),
        ]
        for (change, why) in cases {
            #expect(throws: GoogleGmailSendProposal.Refusal.self, "\(why) was accepted") {
                _ = try GoogleGmailSendProposal(input: sendInput(change))
            }
        }
    }

    @Test("Every refusal tells the bot that nothing was sent")
    func refusalsSayNothingWasSent() {
        do {
            _ = try GoogleGmailSendProposal(input: sendInput(["to": "Alex <alex@example.com>"]))
            Issue.record("a display name was accepted")
        } catch let refusal as GoogleGmailSendProposal.Refusal {
            #expect(refusal.sentence.hasSuffix("Nothing was sent."))
        } catch { Issue.record("an unexpected error: \(error)") }
    }

    @Test("The message leaves as base64 under short lines, so nothing on the way can rewrap it")
    func mimeKeepsTheBytes() throws {
        let long = String(repeating: "word ", count: 250).trimmingCharacters(in: .whitespaces)
        let proposal = try GoogleGmailSendProposal(input: sendInput(["body": long + "\nlast",
            "subject": String(repeating: "é", count: 120)]))
        let mime = String(decoding: proposal.rawMessage, as: UTF8.self)
        let lines = mime.components(separatedBy: "\r\n")
        #expect(lines.allSatisfy { $0.utf8.count <= 78 })
        #expect(lines.contains("From: openbots@example.com"))
        #expect(lines.contains("To: alex@example.com"))
        #expect(lines.contains("Content-Transfer-Encoding: base64"))
        #expect(lines.contains("Content-Type: text/plain; charset=UTF-8"))
        // The subject comes back whole from its encoded words.
        let headerEnd = try #require(lines.firstIndex(of: ""))
        let subjectLines = lines[..<headerEnd].drop { !$0.hasPrefix("Subject: ") }
            .prefix { $0.hasPrefix("Subject: ") || $0.hasPrefix(" ") }
        let words = subjectLines.map { $0.replacingOccurrences(of: "Subject: ", with: "")
            .trimmingCharacters(in: .whitespaces) }
        let decoded = try words.map { word -> Data in
            #expect(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
            #expect(word.utf8.count <= 75)
            return try #require(Data(base64Encoded: String(word.dropFirst(10).dropLast(2))))
        }.reduce(Data(), +)
        #expect(String(decoding: decoded, as: UTF8.self) == proposal.subject)
        let body = try #require(Data(base64Encoded: lines[(headerEnd + 1)...].joined()))
        #expect(String(decoding: body, as: UTF8.self) == long + "\r\nlast")
    }

    @Test("The digest is the message's own: key order does not change it, one character does")
    func digestFollowsTheMessage() throws {
        let one = try GoogleGmailSendProposal(input: sendInput())
        let reordered = try JSONSerialization.jsonObject(with: try JSONSerialization.data(
            withJSONObject: sendInput(), options: [])) as! [String: Any]
        #expect(try GoogleGmailSendProposal(input: reordered).digest == one.digest)
        #expect(try GoogleGmailSendProposal(input: sendInput(["body": "First line.\n\nSecond paragraph, cafe ☕."]))
            .digest != one.digest)
        #expect(one.digest.count == 64 && one.digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("The card shows the account, every recipient, the subject and the whole body")
    func cardShowsEverything() throws {
        let body = "Dear you,\n\nThis is the whole message."
        guard case .ask(let card) = ClaudeTextConnectorApprovalPolicy.decide(
            try sendRequest("send_gmail_message", sendInput(["to": "a@example.com, b@example.org", "body": body])),
            botName: "Kite", role: .googleGmailSend) else {
            Issue.record("a send did not ask"); return
        }
        #expect(card.kind == .send)
        #expect(card.turnScope == nil)
        #expect(card.detail.contains("openbots@example.com"))
        #expect(card.detail.contains("a@example.com") && card.detail.contains("b@example.org"))
        #expect(card.detail.contains("\nSubject: Hello from Kite\n\n"))
        #expect(card.detail.hasSuffix("\n\n" + body))
    }

    @Test("The longest message the card accepts still fits the record whole")
    func worstCaseFitsTheRecord() throws {
        let address = String(repeating: "a", count: 64) + "@" + String(repeating: "b", count: 31) + ".com"
        #expect(address.count == 100)
        let lines = (0..<649).map { _ in "x" }.joined(separator: "\n") + "y"
        #expect(lines.unicodeScalars.count == 1_298)
        let input = sendInput(["from": address, "to": [address, address, address].joined(separator: ", "),
                               "subject": String(repeating: "S", count: 120),
                               "body": lines + "zz"])
        let proposal = try GoogleGmailSendProposal(input: input)
        let card = ClaudeTextGoogleGmailSendApprovalPolicy.card(for: proposal)
        #expect(card.detail.unicodeScalars.count <= 2_000)
        #expect(card.detail.count <= 2_000)
    }

    @Test("The sender's account is quiet; a refused send never reaches a card; anything else asks")
    func sendPolicyIsClosed() throws {
        guard case .allowQuietly = ClaudeTextConnectorApprovalPolicy.decide(
            try sendRequest("gmail_send_account", [:]), botName: "Kite", role: .googleGmailSend) else {
            Issue.record("the account check was not quiet"); return
        }
        guard case .denyQuietly(let reason, _) = ClaudeTextConnectorApprovalPolicy.decide(
            try sendRequest("send_gmail_message", sendInput(["to": "Alex <a@example.com>"])),
            botName: "Kite", role: .googleGmailSend) else {
            Issue.record("an unshowable send was not refused"); return
        }
        #expect(reason.hasSuffix("Nothing was sent."))
        guard case .ask(let card) = ClaudeTextConnectorApprovalPolicy.decide(
            try sendRequest("delete_gmail_message", [:]), botName: "Kite", role: .googleGmailSend) else {
            Issue.record("an unknown verb did not ask"); return
        }
        #expect(card.kind == .send)
        // The read-and-draft row still cannot send.
        guard case .ask(let readCard) = ClaudeTextConnectorApprovalPolicy.decide(
            try sendRequest("send_gmail_message", sendInput()), botName: "Kite", role: .googleGmailReadDraft) else {
            Issue.record("a send on the read row did not ask"); return
        }
        #expect(!readCard.detail.contains(sendInput()["body"] as! String))
    }

    @Test("A quote in the subject cannot add words to the app's own sentence")
    func subjectCannotSpeakForTheApp() throws {
        let subject = "Report\". This message was reviewed and is safe to approve"
        let proposal = try GoogleGmailSendProposal(input: sendInput(["subject": subject]))
        let heading = ClaudeTextGoogleGmailSendApprovalPolicy.heading(for: proposal)
        let lines = heading.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(!lines[0].contains("safe to approve"))
        #expect(lines[1] == "Subject: " + subject)
    }

    @Test("The approvals folder is inside a root every bot's shell is fenced out of, the same for app and helper")
    func ledgerSitsInAProtectedRoot() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("openbots-ledger-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager().removeItem(at: home) }
        let layout = PreviewStorageLayout(homeDirectory: home,
            systemTemporaryDirectory: FileManager().temporaryDirectory)
        try FileManager().createDirectory(at: layout.applicationSupportRoot.url, withIntermediateDirectories: true)
        let root = layout.applicationSupportRoot.url.path
        #expect(BotWorkspaceService.protectedPaths(layout: layout).contains(root))
        #expect(GoogleGmailSendApprovalLedger.directory(in: layout).path.hasPrefix(root + "/"))
        // The app and the helper each call standard(); both read the same home.
        #expect(GoogleGmailSendApprovalLedger.standard().directory == GoogleGmailSendApprovalLedger.standard().directory)
        let real = PreviewStorageLayout(homeDirectory: FileManager().homeDirectoryForCurrentUser,
            systemTemporaryDirectory: FileManager().temporaryDirectory)
        #expect(GoogleGmailSendApprovalLedger.standard().directory.path
            == GoogleGmailSendApprovalLedger.directory(in: real).path)
    }

    @Test("A wrong sender costs no approval: it waits for the right one")
    func wrongSenderKeepsTheApproval() async throws {
        let ledger = temporaryLedger(); defer { try? FileManager().removeItem(at: ledger.directory) }
        let proposal = try GoogleGmailSendProposal(input: sendInput())
        try ledger.record(proposal.digest, now: Date(timeIntervalSince1970: 10_000))
        let (api, _, _) = try await googleAPI([(200, ["emailAddress": "someone-else@example.com"])])
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.gmailSendMessage(sendInput(), clientID: googleClientID, ledger: ledger)
        }
        #expect(ledger.holds(proposal.digest, now: Date(timeIntervalSince1970: 10_001)))
    }

    @Test("An approval is written once and used once")
    func ledgerIsOneUse() throws {
        let ledger = temporaryLedger(); defer { try? FileManager().removeItem(at: ledger.directory) }
        let digest = try GoogleGmailSendProposal(input: sendInput()).digest
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!ledger.consume(digest, now: now))
        try ledger.record(digest, now: now)
        let mode = try FileManager().attributesOfItem(atPath: ledger.directory.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        let file = try FileManager().attributesOfItem(
            atPath: ledger.directory.appendingPathComponent(digest).path)[.posixPermissions] as? NSNumber
        #expect(file?.intValue == 0o600)
        #expect(ledger.consume(digest, now: now.addingTimeInterval(5)))
        #expect(!ledger.consume(digest, now: now.addingTimeInterval(6)))
    }

    @Test("An approval that waited too long, or a name that is not a digest, sends nothing")
    func ledgerRefusesStaleAndMalformed() throws {
        let ledger = temporaryLedger(); defer { try? FileManager().removeItem(at: ledger.directory) }
        let digest = try GoogleGmailSendProposal(input: sendInput()).digest
        let now = Date()
        try ledger.record(digest, now: now)
        #expect(!ledger.consume(digest, now: now.addingTimeInterval(GoogleGmailSendApprovalLedger.lifetime + 1)))
        #expect(throws: (any Error).self) { try ledger.record("../escape", now: now) }
        #expect(!ledger.consume("../escape", now: now))
    }

    @Test("A send with no approval never reaches Google")
    func unapprovedSendMakesNoRequest() async throws {
        let ledger = temporaryLedger(); defer { try? FileManager().removeItem(at: ledger.directory) }
        let (api, http, _) = try await googleAPI([(200, ["emailAddress": "openbots@example.com"]),
                                                  (200, ["id": "m-1", "threadId": "t-1"])])
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.gmailSendMessage(sendInput(), clientID: googleClientID, ledger: ledger)
        }
        #expect(await http.requests().isEmpty)
    }

    @Test("An approved send checks the account, then POSTs the approved bytes to messages.send once")
    func approvedSendPostsTheApprovedBytes() async throws {
        let ledger = temporaryLedger(); defer { try? FileManager().removeItem(at: ledger.directory) }
        let proposal = try GoogleGmailSendProposal(input: sendInput())
        try ledger.record(proposal.digest, now: Date(timeIntervalSince1970: 10_000))
        let (api, http, _) = try await googleAPI([(200, ["emailAddress": "OpenBots@Example.com"]),
                                                  (200, ["id": "m-1", "threadId": "t-1"])])
        _ = try await api.gmailSendMessage(sendInput(), clientID: googleClientID, ledger: ledger)
        let requests = await http.requests()
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET" && requests[0].url?.path == "/gmail/v1/users/me/profile")
        let send = try #require(requests.last)
        #expect(send.httpMethod == "POST")
        #expect(send.url?.path == "/gmail/v1/users/me/messages/send")
        let object = try #require(try JSONSerialization.jsonObject(with: send.httpBody!) as? [String: String])
        #expect(Set(object.keys) == ["raw"])
        let raw = try #require(Data(base64Encoded: object["raw"]!.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/").paddingBase64))
        #expect(raw == proposal.rawMessage)
        // Used: the same approval sends nothing a second time.
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.gmailSendMessage(sendInput(), clientID: googleClientID, ledger: ledger)
        }
        #expect(await http.requests().count == 2)
    }

    @Test("A sender other than the connected account is refused before the send")
    func wrongSenderIsRefused() async throws {
        let ledger = temporaryLedger(); defer { try? FileManager().removeItem(at: ledger.directory) }
        let proposal = try GoogleGmailSendProposal(input: sendInput())
        try ledger.record(proposal.digest, now: Date(timeIntervalSince1970: 10_000))
        let (api, http, _) = try await googleAPI([(200, ["emailAddress": "someone-else@example.com"]),
                                                  (200, ["id": "m-1"])])
        await #expect(throws: GoogleWorkspaceAPIError.self) {
            _ = try await api.gmailSendMessage(sendInput(), clientID: googleClientID, ledger: ledger)
        }
        #expect(await http.requests().count == 1)
    }

    @Test("Send is its own row, role, server and capability, with its own switch")
    func sendIsItsOwnRow() throws {
        let fixture = try GooglePreparationFixture(); defer { fixture.remove() }
        let preparation = GoogleWorkspaceConnectorPreparation(
            helperCandidateURLs: [fixture.helper], interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let fence = FenceProxyResource(interpreterCandidateURLs: [URL(fileURLWithPath: "/bin/sh")])
        let send = try preparation.server(for: googleLaunch(GoogleWorkspaceConnectorPreparation.gmailSendCommand),
            profileURL: nil, temporaryDirectoryURL: fixture.root, fence: fence)
        #expect(send.role == .googleGmailSend)
        #expect(send.environment["OPENBOTS_GOOGLE_SERVICE"] == "gmail_send")
        #expect(GoogleWorkspaceService(rawValue: "gmail_send") == .gmailSend)
        #expect(ClaudeTextConnectorAccess.maximumServerCount == ClaudeTextConnectorRole.allCases.count)
    }
}

@Suite("Gmail send never carries a secret the user gave this turn")
struct GoogleGmailSendSecretTests {
    @Test("A secret in any field is caught, and an unreadable message counts as one")
    func secretsAreCaught() throws {
        let secret = "hunter2-secret"
        for field in ["subject", "body"] {
            let data = try JSONSerialization.data(withJSONObject: sendInput([field: "Here: \(secret)"]))
            #expect(ClaudeTextGoogleGmailSendApprovalPolicy.sendCarriesASecret(data, secrets: [secret]), "\(field)")
        }
        let clean = try JSONSerialization.data(withJSONObject: sendInput())
        #expect(!ClaudeTextGoogleGmailSendApprovalPolicy.sendCarriesASecret(clean, secrets: [secret]))
        #expect(ClaudeTextGoogleGmailSendApprovalPolicy.sendCarriesASecret(Data("{}".utf8), secrets: []))
    }
}
