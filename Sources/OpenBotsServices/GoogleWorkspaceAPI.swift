import Foundation
import OpenBotsSecurity

/// The exact authority requested from Google for the four rows.
///
/// Gmail has no draft-only scope. `gmail.compose` also authorizes the provider's
/// send endpoints, which the Gmail send row uses under its own
/// switch and capability; the read-and-draft row's smaller surface is enforced
/// by its closed command table and tested separately. Calendar uses the two
/// narrower read-only scopes rather than the broad `calendar.readonly` scope.
/// Drive uses `drive.readonly`: reading a file's contents needs it, and
/// `drive.file` would reach only files this app created, which is none.
///
/// One sign-in carries all five, checked for exact equality on every use: the
/// one grant is widened rather than a second sign-in added. So a connection saved
/// before a scope joined the set stops working until the account is connected
/// again, and says so in those words.
public enum GoogleWorkspaceOAuthScopes {
    public static let gmailReadOnly = "https://www.googleapis.com/auth/gmail.readonly"
    public static let gmailCompose = "https://www.googleapis.com/auth/gmail.compose"
    public static let calendarListReadOnly =
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    public static let calendarEventsReadOnly =
        "https://www.googleapis.com/auth/calendar.events.readonly"

    public static let driveReadOnly = "https://www.googleapis.com/auth/drive.readonly"

    public static let required: Set<String> = [
        gmailReadOnly, gmailCompose, calendarListReadOnly, calendarEventsReadOnly, driveReadOnly,
    ]

    /// What the permission lets OpenBots do, in the words the user would use. A
    /// refusal names this, never the URL Google identifies it by.
    public static func plainName(_ scope: String) -> String {
        switch scope {
        case gmailReadOnly: "read Gmail"
        case gmailCompose: "save Gmail drafts and send mail"
        case calendarListReadOnly: "list Google calendars"
        case calendarEventsReadOnly: "read Google Calendar events"
        case driveReadOnly: "read Google Drive"
        default: "use a Google permission this build does not ask for"
        }
    }

    /// The Google product a permission belongs to, for a sentence about a
    /// connection that predates it.
    static func productName(_ scope: String) -> String {
        switch scope {
        case gmailReadOnly, gmailCompose: "Gmail"
        case calendarListReadOnly, calendarEventsReadOnly: "Google Calendar"
        case driveReadOnly: "Google Drive"
        default: "a Google service"
        }
    }
}

public enum GoogleWorkspaceAPIError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case invalidCredential
    /// Google answered a refresh with `invalid_grant`: the saved sign-in was
    /// revoked in the account or has expired, and no retry can fix it.
    case authorizationRejected
    case missingScope(String)
    /// The saved connection holds fewer permissions than this build asks for:
    /// it was made before the named one joined the set.
    case connectionPredatesPermission(String)
    /// Google refused because the named API is switched off in the Cloud
    /// project that owns the OpenBots Desktop client. The page of its switch,
    /// when Google's answer named a project the app could build one for.
    case apiDisabled(String, enablePage: URL? = nil)
    case invalidInput(String)
    case responseTooLarge
    case provider(status: Int, message: String)
    case keychain(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "The OpenBots Google account is not connected. Connect it in Settings → Connectors & Skills."
        case .invalidCredential:
            "The saved Google authorization cannot be used. Disconnect it and connect the account again."
        case .authorizationRejected:
            "Google no longer accepts the OpenBots account's sign-in, so Google access is now off on this Mac. "
                + "In Settings → Connectors & Skills, finish the cleanup and connect the account again."
        case .missingScope(let scope):
            "Google was not given permission to \(GoogleWorkspaceOAuthScopes.plainName(scope)). "
                + "Connect the account again and leave every permission ticked on Google's page."
        case .connectionPredatesPermission(let scope):
            "The OpenBots Google account was connected before \(GoogleWorkspaceOAuthScopes.productName(scope)) "
                + "was added, so this Mac no longer uses that connection. In Settings → Connectors & Skills, "
                + "press Retry Google cleanup to remove it, then connect the account again."
        case .apiDisabled(let api, let page?):
            "The \(api) is switched off in the Google Cloud project that holds the OpenBots sign-in, "
                + "project \(Self.project(of: page) ?? "?"). Press Enable on its page, \(page.absoluteString), "
                + "then try again."
        case .apiDisabled(let api, nil):
            "The \(api) is switched off for the OpenBots sign-in in Google Cloud. In the Google Cloud "
                + "console, open the project that holds the OpenBots Desktop client, go to APIs & Services, "
                + "then Library, find the \(api) and press Enable. Then try again."
        case .invalidInput(let message): message
        case .responseTooLarge:
            "Google returned more data than one connector call can safely carry. Ask for a narrower result."
        case .provider(let status, let message):
            "Google returned HTTP \(status): \(message)"
        case .keychain:
            "The Google authorization could not be read from the OpenBots Next Keychain item."
        }
    }

    /// The services whose switch the app can point at, and the only ones.
    static let switchableServices: Set<String> = [
        "drive.googleapis.com", "gmail.googleapis.com", "calendar-json.googleapis.com",
    ]

    /// The page of one API's switch in one Cloud project, built by the app:
    /// a service it knows and a project number of digits only, or nothing.
    /// Google's answer carries its own address for the switch; that is never
    /// used, so nothing Google or a proxy says can choose where the link goes.
    static func switchPage(service: String, project: String) -> URL? {
        guard switchableServices.contains(service), (1...30).contains(project.count),
              project.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return URL(string: "https://console.cloud.google.com/apis/library/\(service)?project=\(project)")
    }

    /// A page handed back by the helper, accepted only if it is exactly one
    /// this build would have built (the app does not trust the helper's
    /// output to be the helper's).
    public static func switchPage(_ string: String) -> URL? {
        guard let components = URLComponents(string: string), components.scheme == "https",
              components.host == "console.cloud.google.com", components.user == nil,
              components.password == nil, components.port == nil, components.fragment == nil,
              components.path.hasPrefix("/apis/library/"),
              let items = components.queryItems, items.count == 1, items[0].name == "project",
              let project = items[0].value,
              let page = switchPage(service: String(components.path.dropFirst("/apis/library/".count)),
                                    project: project),
              page.absoluteString == string else { return nil }
        return page
    }

    static func project(of page: URL) -> String? {
        URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "project" }?.value
    }

    /// What the helper writes when a command fails: the sentence, and the
    /// switch's page as a field of its own when there is one.
    public static func helperFailure(_ error: Error) -> [String: String] {
        let message = (error as? LocalizedError)?.errorDescription
            ?? "The Google connector could not complete that request."
        var payload = ["error": String(message.prefix(600))]
        if case .apiDisabled(_, let page?)? = error as? GoogleWorkspaceAPIError {
            payload["enable_page"] = page.absoluteString
        }
        return payload
    }
}

/// The token envelope is encoded as one Keychain value. It is public only so
/// the bundled helper can use the Services module; callers must never print or
/// persist an instance outside `KeychainClient`.
public struct GoogleWorkspaceCredential: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, revocationPending }
    public let clientID: String
    public let accountEmail: String
    /// A fresh value for every successful authorization. Connector grants bind
    /// to this rather than to the email address, so even reconnecting the same
    /// account is a new authority decision.
    public let connectionID: UUID
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let grantedScopes: Set<String>
    public let state: State

    public init(clientID: String, accountEmail: String, accessToken: String,
                refreshToken: String, expiresAt: Date, grantedScopes: Set<String>,
                connectionID: UUID = UUID(), state: State = .active) {
        self.clientID = clientID
        self.accountEmail = accountEmail
        self.connectionID = connectionID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.grantedScopes = grantedScopes
        self.state = state
    }

    public func validated(for expectedClientID: String) throws -> GoogleWorkspaceCredential {
        guard Self.validClientID(clientID), clientID == expectedClientID,
              Self.plain(accountEmail, maximum: 320), accountEmail.contains("@"),
              Self.plain(accessToken, maximum: 8_192),
              Self.plain(refreshToken, maximum: 8_192), grantedScopes.count <= 16
        else { throw GoogleWorkspaceAPIError.invalidCredential }
        guard grantedScopes == GoogleWorkspaceOAuthScopes.required else {
            let unexpected = grantedScopes.subtracting(GoogleWorkspaceOAuthScopes.required).sorted().first
            let missing = GoogleWorkspaceOAuthScopes.required.subtracting(grantedScopes).sorted().first
            // A saved connection is written only after its scopes matched the
            // set exactly, so fewer and none extra means the set grew since.
            if unexpected == nil, let missing {
                throw GoogleWorkspaceAPIError.connectionPredatesPermission(missing)
            }
            throw GoogleWorkspaceAPIError.missingScope(missing ?? unexpected ?? "unexpected Google scope")
        }
        return self
    }

    /// Enough validation to revoke an old or newly rejected credential. This
    /// deliberately does not accept it for API use and does not require exact
    /// scopes: otherwise tightening the active policy could make the older,
    /// over-broad token impossible to remove through the UI.
    public func validatedForRevocation(clientID expectedClientID: String) throws
        -> GoogleWorkspaceCredential {
        guard Self.validClientID(clientID), clientID == expectedClientID,
              Self.plain(accountEmail, maximum: 320), accountEmail.contains("@"),
              Self.plain(refreshToken, maximum: 8_192), grantedScopes.count <= 16
        else { throw GoogleWorkspaceAPIError.invalidCredential }
        return self
    }

    public static func validClientID(_ value: String) -> Bool {
        plain(value, maximum: 512)
            && value.hasSuffix(".apps.googleusercontent.com")
            && value.utf8.allSatisfy { byte in
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
            }
    }

    private static func plain(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }
}

public struct GoogleWorkspaceConnectionStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case connected, disconnected, revocationPending, invalid
    }
    public let state: State
    public let accountEmail: String?
    public let connectionID: UUID?
    public let reason: String?

    public init(state: State, accountEmail: String? = nil, connectionID: UUID? = nil,
                reason: String? = nil) {
        self.state = state; self.accountEmail = accountEmail
        self.connectionID = connectionID; self.reason = reason
    }
}

public enum GoogleWorkspaceClientConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case fileTooLarge
    case malformed
    case wrongApplicationType
    case wrongClient
    case missingSecret
    case invalidSecret
    case keychain

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "The selected Google OAuth client JSON is too large to be a client configuration."
        case .malformed:
            "The selected file is not a valid Google Desktop OAuth client JSON."
        case .wrongApplicationType:
            "That file describes a Web OAuth client. Choose the original Desktop client JSON."
        case .wrongClient:
            "That JSON belongs to a different Google OAuth client than this OpenBots Next build."
        case .missingSecret:
            "That Desktop client JSON does not contain the client secret Google issued with it."
        case .invalidSecret:
            "The client secret in that Desktop JSON is malformed."
        case .keychain:
            "The Google OAuth client secret could not be stored in OpenBots Next’s local Keychain item."
        }
    }
}

public struct GoogleWorkspaceClientConfigurationStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ready, missing, invalid }
    public let state: State
    public let reason: String?

    public init(state: State, reason: String? = nil) {
        self.state = state
        self.reason = reason
    }

    public var isReady: Bool { state == .ready }
}

public struct GoogleWorkspaceCredentialStore: Sendable {
    private static let maximumBytes = 64 * 1024
    public static let maximumClientConfigurationBytes = 64 * 1024
    private static let maximumClientSecretBytes = 4 * 1024
    private let keychain: any KeychainClient

    public init(keychain: any KeychainClient) { self.keychain = keychain }

    public func load(clientID: String) async throws -> GoogleWorkspaceCredential? {
        guard let credential = try await loadForRevocation(clientID: clientID),
              credential.state == .active else { return nil }
        return try credential.validated(for: clientID)
    }

    public func loadForRevocation(clientID: String) async throws -> GoogleWorkspaceCredential? {
        let data: Data?
        do { data = try await keychain.read(.previewGoogleWorkspaceOAuthTokens) }
        catch { throw GoogleWorkspaceAPIError.keychain(String(describing: type(of: error))) }
        guard let data else { return nil }
        guard data.count <= Self.maximumBytes,
              let credential = try? JSONDecoder().decode(GoogleWorkspaceCredential.self, from: data)
        else { throw GoogleWorkspaceAPIError.invalidCredential }
        return try credential.validatedForRevocation(clientID: clientID)
    }

    public func save(_ credential: GoogleWorkspaceCredential) async throws {
        if credential.state == .active { _ = try credential.validated(for: credential.clientID) }
        else { _ = try credential.validatedForRevocation(clientID: credential.clientID) }
        let data = try JSONEncoder().encode(credential)
        guard data.count <= Self.maximumBytes else { throw GoogleWorkspaceAPIError.invalidCredential }
        do { try await keychain.store(data, at: .previewGoogleWorkspaceOAuthTokens) }
        catch { throw GoogleWorkspaceAPIError.keychain(String(describing: type(of: error))) }
    }

    /// With `connectionID`, only that connection is staged: a different one is
    /// a reconnect that must not be disabled by news about the old one.
    public func stageForRevocation(clientID: String, connectionID: UUID? = nil) async throws
        -> GoogleWorkspaceCredential? {
        guard let credential = try await loadForRevocation(clientID: clientID) else { return nil }
        if let connectionID, credential.connectionID != connectionID { return nil }
        guard credential.state != .revocationPending else { return credential }
        let pending = GoogleWorkspaceCredential(
            clientID: credential.clientID, accountEmail: credential.accountEmail,
            accessToken: credential.accessToken, refreshToken: credential.refreshToken,
            expiresAt: credential.expiresAt, grantedScopes: credential.grantedScopes,
            connectionID: credential.connectionID, state: .revocationPending)
        try await save(pending)
        return pending
    }

    public func delete() async throws {
        do { try await keychain.delete(.previewGoogleWorkspaceOAuthTokens) }
        catch { throw GoogleWorkspaceAPIError.keychain(String(describing: type(of: error))) }
    }

    /// Imports only Google's Desktop-client secret. The original JSON and its
    /// public metadata are never persisted, and all validation completes before
    /// an existing valid item can be replaced.
    public func importClientConfiguration(_ data: Data, clientID: String) async throws
        -> GoogleWorkspaceClientConfigurationStatus {
        guard !data.isEmpty else { throw GoogleWorkspaceClientConfigurationError.malformed }
        guard data.count <= Self.maximumClientConfigurationBytes else {
            throw GoogleWorkspaceClientConfigurationError.fileTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw GoogleWorkspaceClientConfigurationError.malformed }
        if object["web"] != nil {
            throw GoogleWorkspaceClientConfigurationError.wrongApplicationType
        }
        guard let installed = object["installed"] as? [String: Any],
              let importedClientID = installed["client_id"] as? String,
              GoogleWorkspaceCredential.validClientID(importedClientID) else {
            throw GoogleWorkspaceClientConfigurationError.malformed
        }
        guard importedClientID == clientID else {
            throw GoogleWorkspaceClientConfigurationError.wrongClient
        }
        guard let secret = installed["client_secret"] as? String else {
            throw GoogleWorkspaceClientConfigurationError.missingSecret
        }
        guard Self.validClientSecret(secret),
              let reference = KeychainItemReference.previewGoogleWorkspaceOAuthClientSecret(
                  clientID: clientID) else {
            throw GoogleWorkspaceClientConfigurationError.invalidSecret
        }
        do { try await keychain.store(Data(secret.utf8), at: reference) }
        catch { throw GoogleWorkspaceClientConfigurationError.keychain }
        return .init(state: .ready)
    }

    public func clientConfigurationStatus(clientID: String) async
        -> GoogleWorkspaceClientConfigurationStatus {
        do {
            _ = try await clientSecret(clientID: clientID)
            return .init(state: .ready)
        } catch GoogleWorkspaceClientConfigurationError.missingSecret {
            return .init(state: .missing,
                reason: "Import the original Google Desktop OAuth client JSON before connecting.")
        } catch {
            return .init(state: .invalid,
                reason: "The saved Google OAuth client configuration cannot be used. Import the original Desktop JSON again.")
        }
    }

    public func requireClientConfiguration(clientID: String) async throws {
        _ = try await clientSecret(clientID: clientID)
    }

    func clientSecret(clientID: String) async throws -> String {
        guard let reference = KeychainItemReference.previewGoogleWorkspaceOAuthClientSecret(
            clientID: clientID) else {
            throw GoogleWorkspaceClientConfigurationError.invalidSecret
        }
        let data: Data?
        do { data = try await keychain.read(reference) }
        catch { throw GoogleWorkspaceClientConfigurationError.keychain }
        guard let data else { throw GoogleWorkspaceClientConfigurationError.missingSecret }
        guard data.count <= Self.maximumClientSecretBytes,
              let secret = String(data: data, encoding: .utf8),
              Self.validClientSecret(secret) else {
            throw GoogleWorkspaceClientConfigurationError.invalidSecret
        }
        return secret
    }

    private static func validClientSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumClientSecretBytes
            && value.utf8.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

/// The one normalized proposal used by both the approval card and the MIME
/// writer. Any proposal too large to show exactly is rejected before either
/// boundary; the card can therefore display every To/Cc/Bcc address and the
/// complete subject that the helper will persist.
public struct GoogleGmailDraftProposal: Equatable {
    public static let maximumRecipients = 10
    public static let maximumAddressCharacters = 100
    public static let maximumRecipientDescriptionCharacters = 280
    public static let maximumSubjectCharacters = 120
    public static let maximumBodyBytes = 200_000
    /// The card shows the body whole, so it takes the Gmail
    /// send card's bound: with the longest heading it stays inside the
    /// approvals record's 2,000 characters.
    public static let maximumBodyScalars = GoogleGmailSendProposal.maximumBodyScalars

    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let body: String

    public init(input: [String: Any]) throws {
        to = try Self.addresses(input["to"], name: "to", required: true)
        cc = try Self.addresses(input["cc"], name: "cc", required: false)
        bcc = try Self.addresses(input["bcc"], name: "bcc", required: false)
        guard to.count + cc.count + bcc.count <= Self.maximumRecipients else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "A Gmail draft can name at most \(Self.maximumRecipients) recipients so the approval card can show every one.")
        }
        subject = Self.oneLine(try Self.text(input["subject"], name: "subject",
                                             maximumBytes: 480, allowNewlines: false))
        guard !subject.isEmpty, subject.count <= Self.maximumSubjectCharacters else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "The Gmail draft subject must be at most \(Self.maximumSubjectCharacters) characters so the approval card can show it in full.")
        }
        // Line ends as the draft saves them, so the card shows the same lines.
        body = try Self.text(input["body"], name: "body",
                             maximumBytes: Self.maximumBodyBytes, allowNewlines: true)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard body.unicodeScalars.count <= Self.maximumBodyScalars else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "The Gmail draft's words must be at most \(Self.maximumBodyScalars) characters so the approval card can show them in full.")
        }
        // A character that draws nothing or reorders the words would make the
        // card read differently from the draft; the send card's rule refuses
        // them, and keeps tabs, line breaks and the joiners words need.
        guard AppleMessagesSendProposal.firstRefused(in: Array(body.unicodeScalars)) == nil else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "The Gmail draft's words carry a character that draws nothing or reorders the text, so the approval card cannot show them as saved.")
        }
        guard recipientDescription.count <= Self.maximumRecipientDescriptionCharacters else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "The Gmail draft recipients are too long for the approval card to show exactly.")
        }
    }

    public var recipientDescription: String {
        var fields = ["To: \(to.joined(separator: ", "))"]
        if !cc.isEmpty { fields.append("Cc: \(cc.joined(separator: ", "))") }
        if !bcc.isEmpty { fields.append("Bcc: \(bcc.joined(separator: ", "))") }
        return fields.joined(separator: "; ")
    }

    public func rawMessageBase64URL() -> String {
        var headers = ["To: \(to.joined(separator: ", "))"]
        if !cc.isEmpty { headers.append("Cc: \(cc.joined(separator: ", "))") }
        if !bcc.isEmpty { headers.append("Bcc: \(bcc.joined(separator: ", "))") }
        headers += [
            "Subject: =?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?=",
            "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
        ]
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + normalizedBody
        return Data(message.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func addresses(_ value: Any?, name: String, required: Bool) throws -> [String] {
        guard let raw = value as? String else {
            if !required && (value == nil || value is NSNull) { return [] }
            throw GoogleWorkspaceAPIError.invalidInput("`\(name)` must be a comma-separated list of email addresses.")
        }
        let normalized = withoutHidden(raw)
        guard normalized.utf8.count <= 4_096, !normalized.contains("\r"), !normalized.contains("\n") else {
            throw GoogleWorkspaceAPIError.invalidInput("`\(name)` contains an invalid address.")
        }
        let values = normalized.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if required && values.isEmpty {
            throw GoogleWorkspaceAPIError.invalidInput("At least one `to` address is required.")
        }
        guard values.allSatisfy(validAddress) else {
            throw GoogleWorkspaceAPIError.invalidInput("`\(name)` contains an invalid address.")
        }
        return values
    }

    private static func validAddress(_ value: String) -> Bool {
        guard value.count <= maximumAddressCharacters, value.utf8.count <= 400,
              !value.contains("\r"), !value.contains("\n") else { return false }
        let candidate: String
        if let left = value.lastIndex(of: "<"), value.hasSuffix(">") {
            candidate = String(value[value.index(after: left)..<value.index(before: value.endIndex)])
        } else { candidate = value }
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && candidate.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value != 0x7f }
    }

    private static func text(_ value: Any?, name: String, maximumBytes: Int,
                             allowNewlines: Bool) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximumBytes,
              text.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 || scalar.value == 0x09
                      || (allowNewlines && (scalar.value == 0x0a || scalar.value == 0x0d))
              }), allowNewlines || (!text.contains("\r") && !text.contains("\n")) else {
            throw GoogleWorkspaceAPIError.invalidInput("`\(name)` is required and must be valid text.")
        }
        return text
    }

    private static func oneLine(_ value: String) -> String {
        withoutHidden(value).unicodeScalars.split(whereSeparator: { $0.properties.isWhitespace })
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    private static func withoutHidden(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200B, 0x200E, 0x200F, 0x061C, 0xFEFF: false
            case 0x202A...0x202E, 0x2060...0x2069: false
            default: true
            }
        }))
    }
}

public struct GoogleWorkspaceHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let data: Data
    public init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
}

public protocol GoogleWorkspaceHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> GoogleWorkspaceHTTPResponse
}

public struct URLSessionGoogleWorkspaceHTTPClient: GoogleWorkspaceHTTPClient {
    public init() {}
    public func send(_ request: URLRequest) async throws -> GoogleWorkspaceHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GoogleWorkspaceAPIError.provider(status: 0, message: "no HTTP response")
        }
        return .init(statusCode: response.statusCode, data: data)
    }
}

/// OAuth exchange, refresh, revocation and the exact Google REST calls the two
/// connectors expose. URLs are constructed here from closed operations; no
/// model input can supply a host, method, endpoint, or arbitrary request body.
public struct GoogleWorkspaceAPI: Sendable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    private static let gmailRoot = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    private static let calendarRoot = URL(string: "https://www.googleapis.com/calendar/v3")!
    private static let driveRoot = URL(string: "https://www.googleapis.com/drive/v3")!
    private static let maximumResponseBytes = 8 * 1024 * 1024
    private static let oauthErrorCodes: Set<String> = [
        "invalid_request", "invalid_client", "invalid_grant", "unauthorized_client",
        "unsupported_grant_type", "invalid_scope", "server_error", "temporarily_unavailable",
    ]

    private let store: GoogleWorkspaceCredentialStore
    private let http: any GoogleWorkspaceHTTPClient
    private let now: @Sendable () -> Date

    public init(store: GoogleWorkspaceCredentialStore,
                http: any GoogleWorkspaceHTTPClient = URLSessionGoogleWorkspaceHTTPClient(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store; self.http = http; self.now = now
    }

    public func status(clientID: String) async -> GoogleWorkspaceConnectionStatus {
        guard GoogleWorkspaceCredential.validClientID(clientID) else {
            return .init(state: .invalid, reason: "This build has no valid Google Desktop OAuth client ID.")
        }
        do {
            if let credential = try await store.load(clientID: clientID) {
                return .init(state: .connected, accountEmail: credential.accountEmail,
                             connectionID: credential.connectionID)
            }
            guard let cleanup = try await store.loadForRevocation(clientID: clientID) else {
                return .init(state: .disconnected)
            }
            return .init(state: .revocationPending, accountEmail: cleanup.accountEmail,
                reason: "Google access is disabled locally. Retry provider cleanup to finish disconnecting it.")
        } catch {
            // A credential rejected by a newly tightened active policy (for
            // example an old extra scope) must still be removable. The loose
            // cleanup loader never authorizes API use.
            if let cleanup = try? await store.loadForRevocation(clientID: clientID) {
                let reason = if case GoogleWorkspaceAPIError.connectionPredatesPermission = error {
                    publicMessage(error)
                } else {
                    "The saved Google authorization is disabled locally and needs cleanup."
                }
                return .init(state: .revocationPending, accountEmail: cleanup.accountEmail, reason: reason)
            }
            return .init(state: .invalid, reason: publicMessage(error))
        }
    }

    /// Exchanges the one-time browser result and verifies both APIs before the
    /// refresh token becomes durable authority.
    public func exchangeAuthorizationCode(_ code: String, verifier: String, redirectURI: String,
                                          clientID: String) async throws -> GoogleWorkspaceConnectionStatus {
        guard GoogleWorkspaceCredential.validClientID(clientID), plain(code, 8_192),
              validPKCEVerifier(verifier),
              let redirect = URL(string: redirectURI), redirect.scheme == "http",
              redirect.host == "127.0.0.1", redirect.port.map({ (1...65_535).contains($0) }) == true,
              redirect.user == nil, redirect.password == nil, redirect.query == nil,
              redirect.fragment == nil, redirect.path.isEmpty || redirect.path == "/"
        else { throw GoogleWorkspaceAPIError.invalidInput("The Google authorization response was malformed.") }
        let clientSecret = try await store.clientSecret(clientID: clientID)
        let response = try await formRequest(url: Self.tokenEndpoint, values: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ], redacting: [clientSecret])
        let object = try jsonObject(response.data)
        guard let access = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String,
              let seconds = number(object["expires_in"]), seconds > 0,
              let scopeText = object["scope"] as? String,
              let tokenType = object["token_type"] as? String else {
            throw GoogleWorkspaceAPIError.invalidCredential
        }
        let scopes = Set(scopeText.split(whereSeparator: \.isWhitespace).map(String.init))
        let connectionID = UUID()
        let provisional = GoogleWorkspaceCredential(
            clientID: clientID, accountEmail: "pending@invalid.local",
            accessToken: access, refreshToken: refresh,
            expiresAt: now().addingTimeInterval(seconds), grantedScopes: scopes,
            connectionID: connectionID, state: .revocationPending)
        // Once Google has issued a refresh token it is a resource that must be
        // either committed active or retained solely for cleanup. Saving the
        // non-authorizing state first also makes a crash between issuance and
        // verification recoverable from Settings.
        do { try await store.save(provisional) }
        catch {
            _ = try? await revokeProviderToken(refresh)
            throw error
        }
        do {
            guard tokenType.lowercased() == "bearer" else {
                throw GoogleWorkspaceAPIError.invalidCredential
            }
            guard scopes == GoogleWorkspaceOAuthScopes.required else {
                let unexpected = scopes.subtracting(GoogleWorkspaceOAuthScopes.required).sorted().first
                let missing = GoogleWorkspaceOAuthScopes.required.subtracting(scopes).sorted().first
                throw GoogleWorkspaceAPIError.missingScope(
                    missing ?? unexpected ?? "unexpected Google scope")
            }
            let profile = try await sendAuthorized(request: request(
                url: Self.gmailRoot.appendingPathComponent("profile"), method: "GET"),
                credential: provisional)
            let profileObject = try jsonObject(profile.data)
            guard let email = profileObject["emailAddress"] as? String,
                  email.contains("@"), email.utf8.count <= 320 else {
                throw GoogleWorkspaceAPIError.invalidCredential
            }

            // One bounded read proves the second API is enabled for this client.
            var check = URLComponents(url: Self.calendarRoot.appendingPathComponent("users/me/calendarList"),
                                      resolvingAgainstBaseURL: false)!
            check.queryItems = [URLQueryItem(name: "maxResults", value: "1")]
            _ = try await sendAuthorized(request: request(url: check.url!, method: "GET"),
                                         credential: provisional)

            // And one more the third. Drive switched off in the Cloud project
            // fails the connect here, in a sentence that says where to switch
            // it on, rather than at a bot's first read.
            var drive = URLComponents(url: Self.driveRoot.appendingPathComponent("about"),
                                      resolvingAgainstBaseURL: false)!
            drive.queryItems = [URLQueryItem(name: "fields", value: "user(emailAddress)")]
            _ = try await sendAuthorized(request: request(url: drive.url!, method: "GET"),
                                         credential: provisional)

            let credential = GoogleWorkspaceCredential(
                clientID: clientID, accountEmail: email, accessToken: access, refreshToken: refresh,
                expiresAt: provisional.expiresAt, grantedScopes: scopes,
                connectionID: connectionID, state: .active)
            try await store.save(credential)
            return .init(state: .connected, accountEmail: email, connectionID: connectionID)
        } catch {
            // Best-effort compensation. If Google cannot confirm revocation,
            // the pending Keychain envelope remains non-authorizing so the UI
            // can retry without leaving an invisible provider grant.
            do {
                _ = try await revokeProviderToken(provisional.refreshToken)
                try await store.delete()
            } catch { /* pending cleanup is the safe retained state */ }
            throw error
        }
    }

    /// First half of Disconnect: local authority goes dark before a fallible
    /// network request and remains dark if that request cannot finish.
    public func stageRevocation(clientID: String) async throws -> GoogleWorkspaceConnectionStatus {
        guard let credential = try await store.stageForRevocation(clientID: clientID) else {
            return .init(state: .disconnected)
        }
        return .init(state: .revocationPending, accountEmail: credential.accountEmail,
            reason: "Google access is disabled locally. Finishing provider cleanup…")
    }

    public func finishRevocation(clientID: String) async throws -> GoogleWorkspaceConnectionStatus {
        guard let credential = try await store.stageForRevocation(clientID: clientID) else {
            return .init(state: .disconnected)
        }
        do {
            _ = try await revokeProviderToken(credential.refreshToken)
            try await store.delete()
            return .init(state: .disconnected)
        } catch GoogleWorkspaceAPIError.provider(let status, _) where status == 400 {
            // Google's invalid-token response means no usable provider grant
            // remains; keeping the local cleanup envelope would only trap the
            // account in a retry state that can never succeed.
            try await store.delete()
            return .init(state: .disconnected)
        }
    }

    private func revokeProviderToken(_ token: String) async throws -> GoogleWorkspaceHTTPResponse {
        try await formRequest(url: Self.revocationEndpoint, values: ["token": token],
                              redacting: [token])
    }

    public func gmailProfile(clientID: String) async throws -> Data {
        try await authorized(request(url: Self.gmailRoot.appendingPathComponent("profile"), method: "GET"),
                             clientID: clientID)
    }

    public func gmailSearch(_ input: [String: Any], clientID: String) async throws -> Data {
        let query = try optionalString(input["query"], name: "query", maximum: 1_024)
        let pageToken = try optionalToken(input["page_token"], name: "page_token")
        let limit = boundedInteger(input["limit"], default: 25, maximum: 50)
        var components = URLComponents(url: Self.gmailRoot.appendingPathComponent("messages"),
                                       resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "maxResults", value: String(limit))]
        if let query { items.append(.init(name: "q", value: query)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        return try await authorized(request(url: Self.url(components), method: "GET"), clientID: clientID)
    }

    public func gmailReadMessage(_ input: [String: Any], clientID: String) async throws -> Data {
        let id = try requiredToken(input["id"], name: "id")
        var components = URLComponents(
            url: Self.gmailRoot.appendingPathComponent("messages").appendingPathComponent(id),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        return try await authorized(request(url: components.url!, method: "GET"), clientID: clientID)
    }

    public func gmailReadThread(_ input: [String: Any], clientID: String) async throws -> Data {
        let id = try requiredToken(input["id"], name: "id")
        var components = URLComponents(
            url: Self.gmailRoot.appendingPathComponent("threads").appendingPathComponent(id),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        return try await authorized(request(url: components.url!, method: "GET"), clientID: clientID)
    }

    /// The read-and-draft row's one Gmail mutation. Beside it this type spells
    /// only the send row's approved send (`gmailSendMessage`): no modify,
    /// trash, delete, or arbitrary-request operation.
    public func gmailCreateDraft(_ input: [String: Any], clientID: String) async throws -> Data {
        let raw = try GoogleGmailDraftProposal(input: input).rawMessageBase64URL()
        let body = try JSONSerialization.data(withJSONObject: ["message": ["raw": raw]],
                                               options: [.sortedKeys])
        return try await authorized(request(url: Self.gmailRoot.appendingPathComponent("drafts"),
                                            method: "POST", jsonBody: body), clientID: clientID)
    }

    /// The only send this helper can spell: the approved message,
    /// once. Nothing reaches Google without a waiting approval; the sender is
    /// checked against the connected account before the approval is used, so a
    /// wrong "from" costs no approval; and the approval is used before the send.
    public func gmailSendMessage(_ input: [String: Any], clientID: String,
                                 ledger: GoogleGmailSendApprovalLedger) async throws -> Data {
        let proposal: GoogleGmailSendProposal
        do { proposal = try GoogleGmailSendProposal(input: input) }
        catch let refusal as GoogleGmailSendProposal.Refusal {
            throw GoogleWorkspaceAPIError.invalidInput(refusal.sentence)
        }
        let unapproved = GoogleWorkspaceAPIError.invalidInput(
            "This message was not approved on its card, or the approval ran out. Nothing was sent.")
        guard ledger.holds(proposal.digest, now: now()) else { throw unapproved }
        let profile = try await gmailProfile(clientID: clientID)
        guard let object = try? JSONSerialization.jsonObject(with: profile) as? [String: Any],
              let address = object["emailAddress"] as? String,
              address.lowercased() == proposal.from.lowercased() else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "`from` is not the connected account's address; call gmail_send_account for it. Nothing was sent.")
        }
        guard ledger.consume(proposal.digest, now: now()) else { throw unapproved }
        let body = try JSONSerialization.data(withJSONObject: ["raw": proposal.rawMessageBase64URL],
                                               options: [.sortedKeys])
        return try await authorized(request(url: Self.gmailRoot.appendingPathComponent("messages")
                                                .appendingPathComponent("send"),
                                            method: "POST", jsonBody: body), clientID: clientID)
    }

    // MARK: - Google Drive, read-only

    /// The facts asked of Drive about a file, and nothing else: a fixed
    /// `fields` list, so no answer carries more than the renderer shows.
    public static let driveFileFields = "id,name,mimeType,modifiedTime,size,"
        + "owners(displayName,emailAddress),parents,shortcutDetails(targetId,targetMimeType),webViewLink"
    public static let driveListFields = "nextPageToken,incompleteSearch,files(\(driveFileFields))"
    /// The largest plain file read by download. A Google Doc has no size of its
    /// own; its export is bounded by the response cap instead.
    public static let maximumDriveDownloadBytes = 1_000_000

    /// Google's own formats, read through Drive's export as the text a model
    /// can use. Anything not here and not plain text is refused by name.
    static let driveExports: [String: String] = [
        "application/vnd.google-apps.document": "text/plain",
        "application/vnd.google-apps.spreadsheet": "text/csv",
        "application/vnd.google-apps.presentation": "text/plain",
    ]
    static let driveFolderType = "application/vnd.google-apps.folder"
    static let driveShortcutType = "application/vnd.google-apps.shortcut"

    /// Search the whole Drive of the OpenBots account, or list what changed
    /// last when no words are given. The bot's words reach Drive's query
    /// language only as one escaped string literal, never as a query.
    public func driveSearch(_ input: [String: Any], clientID: String) async throws -> Data {
        let words = try optionalString(input["query"], name: "query", maximum: 500)
        var query = "trashed = false"
        if let words { query += " and fullText contains '\(Self.driveLiteral(words))'" }
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: String(boundedInteger(input["limit"], default: 25, maximum: 50))),
            URLQueryItem(name: "fields", value: Self.driveListFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        // A full-text search comes back in relevance order, and Drive has been
        // reported to refuse a sort order on one ("Sorting is not supported for
        // queries with fullText terms"; not confirmed here). Sending none is
        // right either way.
        if words == nil { items.append(.init(name: "orderBy", value: "modifiedTime desc")) }
        if let token = try optionalPageToken(input["page_token"]) { items.append(.init(name: "pageToken", value: token)) }
        return try await driveGET(path: "files", items: items, clientID: clientID)
    }

    /// The files and folders directly inside one folder, folders first. With
    /// no folder named, the top of the account's Drive.
    public func driveListFolder(_ input: [String: Any], clientID: String) async throws -> Data {
        let folder = try isLeftOut(input["folder_id"]) ? "root" : requiredToken(input["folder_id"], name: "folder_id")
        var items = [
            URLQueryItem(name: "q", value: "'\(folder)' in parents and trashed = false"),
            URLQueryItem(name: "orderBy", value: "folder,name"),
            URLQueryItem(name: "pageSize", value: String(boundedInteger(input["limit"], default: 50, maximum: 100))),
            URLQueryItem(name: "fields", value: Self.driveListFields),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]
        if let token = try optionalPageToken(input["page_token"]) { items.append(.init(name: "pageToken", value: token)) }
        return try await driveGET(path: "files", items: items, clientID: clientID)
    }

    /// One file as text. A shortcut is followed once; Google's own formats are
    /// exported; a plain file is downloaded when it is small enough; anything
    /// else is refused by name before a byte of it is fetched.
    public func driveReadFile(_ input: [String: Any], clientID: String) async throws -> Data {
        var file = try await driveMetadata(requiredToken(input["id"], name: "id"), clientID: clientID)
        if file["mimeType"] as? String == Self.driveShortcutType {
            let details = file["shortcutDetails"] as? [String: Any]
            let target = try requiredToken(details?["targetId"], name: "shortcut target")
            file = try await driveMetadata(target, clientID: clientID)
            guard file["mimeType"] as? String != Self.driveShortcutType else {
                throw GoogleWorkspaceAPIError.invalidInput(
                    "\(driveName(file)) is a shortcut to another shortcut; open the file it finally points to.")
            }
        }
        let id = try requiredToken(file["id"], name: "id")
        let type = (file["mimeType"] as? String) ?? ""
        let readAs: String
        let data: Data
        if let export = Self.driveExports[type] {
            readAs = export
            data = try await driveGET(path: "files/\(id)/export", items: [.init(name: "mimeType", value: export)],
                                      clientID: clientID, media: true)
        } else if Self.isPlainText(type) {
            let size = (file["size"] as? String).flatMap(Int.init) ?? (file["size"] as? NSNumber)?.intValue ?? 0
            guard size <= Self.maximumDriveDownloadBytes else {
                throw GoogleWorkspaceAPIError.invalidInput(
                    "\(driveName(file)) is \(size) bytes, more than the 1 MB this connector reads from a plain file.")
            }
            readAs = type
            data = try await driveGET(path: "files/\(id)", items: [
                .init(name: "alt", value: "media"), .init(name: "supportsAllDrives", value: "true"),
            ], clientID: clientID, media: true)
            // Drive states a plain file's size, but a file that came without
            // one is held to the same cap once it has arrived.
            guard data.count <= Self.maximumDriveDownloadBytes else {
                throw GoogleWorkspaceAPIError.invalidInput(
                    "\(driveName(file)) is \(data.count) bytes, more than the 1 MB this connector reads from a plain file.")
            }
        } else if type == Self.driveFolderType {
            throw GoogleWorkspaceAPIError.invalidInput(
                "\(driveName(file)) is a folder; list it with list_google_drive_folder.")
        } else {
            throw GoogleWorkspaceAPIError.invalidInput(
                "\(driveName(file)) is \(Self.driveKind(type)); this connector reads Google Docs, Sheets "
                    + "and Slides, and plain-text files, and cannot read this one.")
        }
        // Drive's text export of a Doc begins with a byte-order mark; it is not
        // part of what anyone wrote.
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return try JSONSerialization.data(withJSONObject: [
            "file": file, "readAs": readAs, "text": text,
        ], options: [.sortedKeys])
    }

    private func driveMetadata(_ id: String, clientID: String) async throws -> [String: Any] {
        try await jsonObject(driveGET(path: "files/\(id)", items: [
            .init(name: "fields", value: Self.driveFileFields), .init(name: "supportsAllDrives", value: "true"),
        ], clientID: clientID))
    }

    /// Every Drive call is a GET under the one root; the path is built only
    /// from ids that passed `requiredToken`.
    private func driveGET(path: String, items: [URLQueryItem], clientID: String,
                          media: Bool = false) async throws -> Data {
        var components = URLComponents(url: Self.driveRoot.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = request(url: Self.url(components), method: "GET")
        if media { request.setValue("*/*", forHTTPHeaderField: "Accept") }
        return try await authorized(request, clientID: clientID)
    }

    /// A file's name as one safe line: it was written by whoever named the
    /// file, and it is about to sit inside the app's own sentence.
    private func driveName(_ file: [String: Any]) -> String {
        "“" + (safeProviderText((file["name"] as? String) ?? "", maximum: 120) ?? "This file") + "”"
    }

    static func isPlainText(_ type: String) -> Bool {
        type.hasPrefix("text/") || ["application/json", "application/xml", "application/x-yaml",
                                    "application/yaml", "application/x-sh"].contains(type)
    }

    static func driveKind(_ type: String) -> String {
        switch type {
        case "application/pdf": "a PDF"
        case let image where image.hasPrefix("image/"): "a picture"
        case let video where video.hasPrefix("video/"): "a video"
        case let audio where audio.hasPrefix("audio/"): "a sound file"
        case "application/vnd.google-apps.form": "a Google Form"
        case "application/vnd.google-apps.drawing": "a Google Drawing"
        case let google where google.hasPrefix("application/vnd.google-apps."): "a Google file of a kind it cannot export"
        case let office where office.contains("officedocument") || office.contains("msword")
            || office.contains("ms-excel") || office.contains("ms-powerpoint"): "an Office file"
        default: "a file of type \(type.isEmpty ? "unknown" : type)"
        }
    }

    /// Drive's query language quotes a string in single quotes and escapes a
    /// quote and a backslash with a backslash.
    static func driveLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    /// A page token is Google's own opaque string; Drive's carry `~` and `!`,
    /// so the id rule is too narrow for them. Printable ASCII, bounded.
    private func optionalPageToken(_ value: Any?) throws -> String? {
        guard !isLeftOut(value) else { return nil }
        let token = try requiredString(value, name: "page_token", maximum: 2_048)
        guard token.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw GoogleWorkspaceAPIError.invalidInput("`page_token` is malformed.")
        }
        return token
    }

    /// `URLComponents` leaves a `+` in a query value as it is, and Google reads
    /// a `+` in a query as a space: a search for `from:a+b@example.com` became
    /// one for `a b`. Every Google query is sent through here.
    static func url(_ components: URLComponents) -> URL {
        var components = components
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public func calendarList(clientID: String) async throws -> Data {
        var components = URLComponents(
            url: Self.calendarRoot.appendingPathComponent("users/me/calendarList"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "maxResults", value: "100"),
            .init(name: "minAccessRole", value: "reader"),
        ]
        return try await authorized(request(url: components.url!, method: "GET"), clientID: clientID)
    }

    public func calendarSearch(_ input: [String: Any], clientID: String) async throws -> Data {
        let from = try requiredRFC3339(input["from"], name: "from")
        let to = try requiredRFC3339(input["to"], name: "to")
        guard to > from, to.timeIntervalSince(from) <= 1_100 * 86_400 else {
            throw GoogleWorkspaceAPIError.invalidInput("The calendar window must end after it starts and be no longer than 1,100 days.")
        }
        let query = try optionalString(input["query"], name: "query", maximum: 500)
        let selectedCalendar = try optionalCalendarID(input["calendar_id"], name: "calendar_id")
        let limit = boundedInteger(input["limit"], default: 50, maximum: 100)

        let calendars: [[String: Any]]
        if let selectedCalendar {
            calendars = [["id": selectedCalendar, "summary": selectedCalendar]]
        } else {
            let list = try await calendarList(clientID: clientID)
            let object = try jsonObject(list)
            calendars = (object["items"] as? [[String: Any]] ?? []).prefix(100).map { $0 }
        }

        var events: [[String: Any]] = []
        var more = false
        for calendar in calendars {
            guard events.count < limit, calendar["id"] != nil else { break }
            let id = try requiredCalendarID(calendar["id"], name: "calendar_id")
            var components = URLComponents(
                url: Self.calendarRoot.appendingPathComponent("calendars")
                    .appendingPathComponent(id).appendingPathComponent("events"),
                resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = [
                .init(name: "timeMin", value: rfc3339String(from)),
                .init(name: "timeMax", value: rfc3339String(to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: String(limit - events.count)),
            ]
            if let query { items.append(.init(name: "q", value: query)) }
            components.queryItems = items
            let data = try await authorized(request(url: Self.url(components), method: "GET"), clientID: clientID)
            let object = try jsonObject(data)
            if object["nextPageToken"] != nil { more = true }
            for item in object["items"] as? [[String: Any]] ?? [] {
                var event = item
                event["openbotsCalendarID"] = id
                event["openbotsCalendar"] = calendar["summary"] as? String ?? id
                events.append(event)
                if events.count == limit { more = true; break }
            }
        }
        return try JSONSerialization.data(withJSONObject: [
            "events": events, "calendarsSearched": calendars.count,
            "returned": events.count, "truncated": more,
        ], options: [.sortedKeys])
    }

    public func calendarReadEvent(_ input: [String: Any], clientID: String) async throws -> Data {
        let calendarID = try requiredCalendarID(input["calendar_id"], name: "calendar_id")
        let eventID = try requiredToken(input["event_id"], name: "event_id")
        let url = Self.calendarRoot.appendingPathComponent("calendars")
            .appendingPathComponent(calendarID).appendingPathComponent("events")
            .appendingPathComponent(eventID)
        let data = try await authorized(request(url: url, method: "GET"), clientID: clientID)
        var event = try jsonObject(data)
        // The read response does not repeat which calendar was addressed. Keep
        // the caller's validated id beside the event so the renderer never
        // substitutes the organiser's email as though it were a calendar id.
        event["openbotsCalendarID"] = calendarID
        return try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    }

    // MARK: - Authorization and HTTP

    private func authorized(_ request: URLRequest, clientID: String) async throws -> Data {
        guard var credential = try await store.load(clientID: clientID) else {
            throw GoogleWorkspaceAPIError.notConnected
        }
        if credential.expiresAt <= now().addingTimeInterval(60) {
            credential = try await refreshWhileCurrent(credential, clientID: clientID)
        }
        try await requireCurrentConnection(credential, clientID: clientID)
        var response = try await sendAuthorized(request: request, credential: credential,
                                                acceptsErrorStatus: true)
        try await requireCurrentConnection(credential, clientID: clientID)
        if response.statusCode == 401 {
            credential = try await refreshWhileCurrent(credential, clientID: clientID)
            try await requireCurrentConnection(credential, clientID: clientID)
            response = try await sendAuthorized(request: request, credential: credential,
                                                acceptsErrorStatus: true)
            try await requireCurrentConnection(credential, clientID: clientID)
        }
        return try checked(response).data
    }

    /// Rechecks the Keychain envelope at every await boundary that can race a
    /// local-first disconnect or a reconnect. Google cannot roll back a request
    /// it already accepted, but a disabled/replaced connection may neither start
    /// the next request nor turn a late provider reply into local success.
    private func requireCurrentConnection(_ credential: GoogleWorkspaceCredential,
                                          clientID: String) async throws {
        guard let current = try await store.load(clientID: clientID),
              current.connectionID == credential.connectionID else {
            throw GoogleWorkspaceAPIError.notConnected
        }
    }

    private func refreshWhileCurrent(_ credential: GoogleWorkspaceCredential,
                                     clientID: String) async throws -> GoogleWorkspaceCredential {
        try await requireCurrentConnection(credential, clientID: clientID)
        let refreshed: GoogleWorkspaceCredential
        do {
            refreshed = try await refresh(credential)
        } catch GoogleWorkspaceAPIError.provider(let status, let code) where status == 400 && code == "invalid_grant" {
            // The sign-in was revoked in the Google account, or expired (a
            // consent screen still in Testing expires it after seven days).
            // Left as it was, Settings kept saying Connected while every call
            // failed. Only local authority is disabled, the same first step a
            // disconnect takes; nothing is sent to Google, and a reconnect that
            // landed meanwhile is left alone.
            try await requireCurrentConnection(credential, clientID: clientID)
            _ = try await store.stageForRevocation(clientID: clientID, connectionID: credential.connectionID)
            throw GoogleWorkspaceAPIError.authorizationRejected
        }
        try await requireCurrentConnection(credential, clientID: clientID)
        return refreshed
    }

    private func refresh(_ credential: GoogleWorkspaceCredential) async throws -> GoogleWorkspaceCredential {
        let clientSecret = try await store.clientSecret(clientID: credential.clientID)
        let response = try await formRequest(url: Self.tokenEndpoint, values: [
            "client_id": credential.clientID,
            "client_secret": clientSecret,
            "refresh_token": credential.refreshToken,
            "grant_type": "refresh_token",
        ], redacting: [clientSecret])
        let object = try jsonObject(response.data)
        guard let access = object["access_token"] as? String,
              let seconds = number(object["expires_in"]), seconds > 0 else {
            throw GoogleWorkspaceAPIError.invalidCredential
        }
        if let scopeText = object["scope"] as? String {
            let scopes = Set(scopeText.split(whereSeparator: \.isWhitespace).map(String.init))
            guard scopes == GoogleWorkspaceOAuthScopes.required else {
                throw GoogleWorkspaceAPIError.invalidCredential
            }
        }
        let refreshed = GoogleWorkspaceCredential(
            clientID: credential.clientID, accountEmail: credential.accountEmail,
            accessToken: access, refreshToken: credential.refreshToken,
            expiresAt: now().addingTimeInterval(seconds), grantedScopes: credential.grantedScopes,
            connectionID: credential.connectionID, state: .active)
        // Deliberately not persisted. Each helper invocation rechecks the
        // active Keychain envelope before it may use the refreshed token, so a
        // concurrent local-first disconnect cannot be overwritten by a late
        // refresh save that resurrects authority.
        return refreshed
    }

    private func sendAuthorized(request: URLRequest, credential: GoogleWorkspaceCredential,
                                acceptsErrorStatus: Bool = false) async throws -> GoogleWorkspaceHTTPResponse {
        var request = request
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await http.send(request)
        guard response.data.count <= Self.maximumResponseBytes else {
            throw GoogleWorkspaceAPIError.responseTooLarge
        }
        return acceptsErrorStatus ? response : try checked(response)
    }

    private func formRequest(url: URL, values: [String: String], redacting secrets: [String] = [])
        async throws -> GoogleWorkspaceHTTPResponse {
        let body = values.keys.sorted().map { key in
            formComponent(key) + "=" + formComponent(values[key] ?? "")
        }.joined(separator: "&")
        var request = request(url: url, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let response = try await http.send(request)
        guard response.data.count <= Self.maximumResponseBytes else {
            throw GoogleWorkspaceAPIError.responseTooLarge
        }
        return try checked(response, redacting: secrets + secrets.map(formComponent))
    }

    /// RFC 6749 form bodies are not URL query strings: a literal `+` in an
    /// opaque authorization code must become `%2B`, or a form decoder turns it
    /// into a space. Encode UTF-8 bytes directly so every input byte survives
    /// the public-client PKCE exchange unchanged.
    private func formComponent(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                encoded.append(byte)
            case 32:
                encoded.append(43)
            default:
                encoded.append(37)
                encoded.append(hex[Int(byte >> 4)])
                encoded.append(hex[Int(byte & 0x0f)])
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private func checked(_ response: GoogleWorkspaceHTTPResponse, redacting secrets: [String] = []) throws
        -> GoogleWorkspaceHTTPResponse {
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            if !secrets.isEmpty {
                let object = try? jsonObject(response.data)
                let code = object?["error"] as? String
                message = code.flatMap { Self.oauthErrorCodes.contains($0) ? $0 : nil }
                    ?? "request failed"
            } else if response.statusCode == 403, let (api, page) = disabledAPI(response.data) {
                throw GoogleWorkspaceAPIError.apiDisabled(api, enablePage: page)
            } else if let object = try? jsonObject(response.data),
               let error = object["error"] as? [String: Any],
               let providerMessage = error["message"] as? String,
               let safeMessage = safeProviderText(
                   redactingSecrets(in: providerMessage, secrets: secrets), maximum: 300) {
                message = safeMessage
            } else if let object = try? jsonObject(response.data),
                      let providerError = object["error"] as? String {
                let code = safeProviderText(
                    redactingSecrets(in: providerError, secrets: secrets), maximum: 64)
                    ?? "request failed"
                if let description = object["error_description"] as? String,
                   let safeDescription = safeProviderText(
                       redactingSecrets(in: description, secrets: secrets), maximum: 220) {
                    message = "\(code): \(safeDescription)"
                } else {
                    message = code
                }
            } else {
                message = "request failed"
            }
            let redacted = secrets.filter { !$0.isEmpty }.reduce(message) { partial, secret in
                partial.replacingOccurrences(of: secret, with: "[redacted]")
            }
            throw GoogleWorkspaceAPIError.provider(status: response.statusCode, message: redacted)
        }
        return response
    }

    /// Which API Google says is switched off, from its documented error model:
    /// an `ErrorInfo` detail with reason `SERVICE_DISABLED` naming the service
    /// and the project it is off in (`consumer`, "projects/<number>"), or the
    /// older `accessNotConfigured` reason with neither.
    private func disabledAPI(_ data: Data) -> (String, URL?)? {
        guard let object = try? jsonObject(data), let error = object["error"] as? [String: Any] else { return nil }
        let details = error["details"] as? [[String: Any]] ?? []
        if let info = details.first(where: { $0["reason"] as? String == "SERVICE_DISABLED" }) {
            let metadata = info["metadata"] as? [String: Any]
            let service = metadata?["service"] as? String
            let consumer = metadata?["consumer"] as? String ?? ""
            let page = consumer.hasPrefix("projects/")
                ? service.flatMap { GoogleWorkspaceAPIError.switchPage(
                    service: $0, project: String(consumer.dropFirst("projects/".count))) }
                : nil
            return (Self.apiName(service), page)
        }
        let reasons = (error["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        return reasons.contains("accessNotConfigured") ? (Self.apiName(nil), nil) : nil
    }

    static func apiName(_ service: String?) -> String {
        switch service {
        case "drive.googleapis.com": "Google Drive API"
        case "gmail.googleapis.com": "Gmail API"
        case "calendar-json.googleapis.com": "Google Calendar API"
        default: "Google API this connector needs"
        }
    }

    private func redactingSecrets(in value: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.reduce(value) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "[redacted]")
        }
    }

    /// OAuth error descriptions are useful diagnostics but remain provider
    /// material. Keep one bounded line and remove controls that could make the
    /// app display a different-looking reason than the string it received.
    private func safeProviderText(_ value: String, maximum: Int) -> String? {
        let words = value.unicodeScalars.split(whereSeparator: { scalar in
            if scalar.properties.isWhitespace || scalar.value < 0x20 || scalar.value == 0x7f {
                return true
            }
            switch scalar.value {
            case 0x200B, 0x200E, 0x200F, 0x061C, 0xFEFF: return true
            case 0x202A...0x202E, 0x2060...0x2069: return true
            default: return false
            }
        })
        let normalized = words.map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximum))
    }

    private func request(url: URL, method: String, jsonBody: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Inputs and MIME

    private func requiredToken(_ value: Any?, name: String) throws -> String {
        let string = try requiredString(value, name: name, maximum: 1_024)
        guard string.utf8.allSatisfy({ byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
        }) else { throw GoogleWorkspaceAPIError.invalidInput("`\(name)` is malformed.") }
        return string
    }

    /// Whether an optional field was left out. A model that means "none" often
    /// sends an empty string, and every optional field of these tools says it
    /// may be left out, so empty or blank text is read as absent rather than
    /// refused as "required".
    private func isLeftOut(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    private func optionalToken(_ value: Any?, name: String) throws -> String? {
        guard !isLeftOut(value) else { return nil }
        return try requiredToken(value, name: name)
    }

    private func requiredCalendarID(_ value: Any?, name: String) throws -> String {
        let string = try requiredString(value, name: name, maximum: 1_024)
        guard string != ".", string != "..", string.utf8.allSatisfy({ byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
                || byte == 35 || byte == 46 || byte == 64
        }) else { throw GoogleWorkspaceAPIError.invalidInput("`\(name)` is malformed.") }
        return string
    }

    private func optionalCalendarID(_ value: Any?, name: String) throws -> String? {
        guard !isLeftOut(value) else { return nil }
        return try requiredCalendarID(value, name: name)
    }

    private func requiredString(_ value: Any?, name: String, maximum: Int,
                                allowNewlines: Bool = false) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximum,
              text.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 || (allowNewlines && (scalar.value == 0x0a || scalar.value == 0x0d))
              }),
              allowNewlines || (!text.contains("\r") && !text.contains("\n")) else {
            throw GoogleWorkspaceAPIError.invalidInput("`\(name)` is required and must be valid text.")
        }
        return text
    }

    private func optionalString(_ value: Any?, name: String, maximum: Int) throws -> String? {
        guard !isLeftOut(value) else { return nil }
        return try requiredString(value, name: name, maximum: maximum)
    }

    private func boundedInteger(_ value: Any?, default fallback: Int, maximum: Int) -> Int {
        let parsed: Int?
        if let number = value as? NSNumber { parsed = number.intValue }
        else if let string = value as? String { parsed = Int(string) }
        else { parsed = nil }
        guard let parsed, parsed > 0 else { return fallback }
        return min(parsed, maximum)
    }

    private func requiredRFC3339(_ value: Any?, name: String) throws -> Date {
        let string = try requiredString(value, name: name, maximum: 64)
        guard let date = rfc3339Date(string) else {
            throw GoogleWorkspaceAPIError.invalidInput("`\(name)` must be a full RFC 3339 date and time.")
        }
        return date
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoogleWorkspaceAPIError.provider(status: 0, message: "invalid JSON response")
        }
        return object
    }

    private func number(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }

    private func plain(_ value: String, _ maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private func validPKCEVerifier(_ value: String) -> Bool {
        (43...128).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46
                || byte == 95 || byte == 126
        }
    }

    private func publicMessage(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "The saved Google authorization is not usable."
    }

    private func rfc3339Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func rfc3339String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
