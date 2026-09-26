import AppKit
import CryptoKit
import Darwin
import Foundation
import OpenBotsSecurity
import OpenBotsServices

@main
struct OpenBotsGoogleHelper {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw Failure.usage }
            let clientID = try value(after: "--client-id", in: arguments)
            guard GoogleWorkspaceCredential.validClientID(clientID) else { throw Failure.clientID }

            let keychain = SystemKeychainClient()
            let store = GoogleWorkspaceCredentialStore(keychain: keychain)
            let api = GoogleWorkspaceAPI(store: store)
            switch command {
            case "status":
                _ = try requireDirectOwningApp()
                try writeJSON(api: await api.status(clientID: clientID))
            case "client_configuration_status":
                _ = try requireDirectOwningApp()
                try writeJSON(api: await store.clientConfigurationStatus(clientID: clientID))
            case "import_client_configuration":
                _ = try requireDirectOwningApp()
                let data = try boundedClientConfigurationInput()
                try writeJSON(api: try await store.importClientConfiguration(data, clientID: clientID))
            case "authorize":
                _ = try requireDirectOwningApp()
                try await store.requireClientConfiguration(clientID: clientID)
                try await authorize(api: api, clientID: clientID)
            case "stage_revocation":
                _ = try requireDirectOwningApp()
                try writeJSON(api: try await api.stageRevocation(clientID: clientID))
            case "finish_revocation":
                _ = try requireDirectOwningApp()
                try writeJSON(api: try await api.finishRevocation(clientID: clientID))
            case "authorize_connector":
                let issuerPID = try requireDirectOwningApp()
                try await store.requireClientConfiguration(clientID: clientID)
                guard let service = GoogleWorkspaceService(
                    rawValue: try value(after: "--service", in: arguments)) else {
                    throw Failure.usage
                }
                guard let credential = try await store.load(clientID: clientID) else {
                    throw GoogleWorkspaceAPIError.notConnected
                }
                let capability = try await GoogleWorkspaceHelperCapability(keychain: keychain).mint(
                    service: service, clientID: clientID, connectionID: credential.connectionID,
                    issuerPID: issuerPID)
                try writeJSON(api: ["capability": capability])
            case "gmail_profile":
                _ = try await authorizedInput(for: command, service: .gmail, clientID: clientID,
                                              store: store, keychain: keychain)
                try write(try await api.gmailProfile(clientID: clientID))
            case "gmail_search":
                try write(try await api.gmailSearch(try await authorizedInput(
                    for: command, service: .gmail, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "gmail_read_message":
                try write(try await api.gmailReadMessage(try await authorizedInput(
                    for: command, service: .gmail, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "gmail_read_thread":
                try write(try await api.gmailReadThread(try await authorizedInput(
                    for: command, service: .gmail, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "gmail_create_draft":
                try write(try await api.gmailCreateDraft(try await authorizedInput(
                    for: command, service: .gmail, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "gmail_send_profile":
                _ = try await authorizedInput(for: command, service: .gmailSend, clientID: clientID,
                                              store: store, keychain: keychain)
                try write(try await api.gmailProfile(clientID: clientID))
            case "gmail_send_message":
                // Sends only a message the user approved on its card, once: the
                // app wrote its digest when the user pressed Approve.
                try write(try await api.gmailSendMessage(try await authorizedInput(
                    for: command, service: .gmailSend, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID, ledger: .standard()))
            case "calendar_list":
                _ = try await authorizedInput(for: command, service: .calendar, clientID: clientID,
                                              store: store, keychain: keychain)
                try write(try await api.calendarList(clientID: clientID))
            case "calendar_search":
                try write(try await api.calendarSearch(try await authorizedInput(
                    for: command, service: .calendar, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "calendar_read_event":
                try write(try await api.calendarReadEvent(try await authorizedInput(
                    for: command, service: .calendar, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "drive_search":
                try write(try await api.driveSearch(try await authorizedInput(
                    for: command, service: .drive, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "drive_list_folder":
                try write(try await api.driveListFolder(try await authorizedInput(
                    for: command, service: .drive, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            case "drive_read_file":
                try write(try await api.driveReadFile(try await authorizedInput(
                    for: command, service: .drive, clientID: clientID, store: store, keychain: keychain),
                    clientID: clientID))
            default:
                throw Failure.usage
            }
        } catch {
            try? writeJSON(api: GoogleWorkspaceAPIError.helperFailure(error))
            Darwin.exit(1)
        }
    }

    private static func authorize(api: GoogleWorkspaceAPI, clientID: String) async throws {
        let listener = try LoopbackListener()
        let verifier = randomURLToken(byteCount: 64)
        let state = randomURLToken(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let redirectURI = "http://127.0.0.1:\(listener.port)"

        var components = URLComponents(url: GoogleWorkspaceAPI.authorizationEndpoint,
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "access_type", value: "offline"),
            .init(name: "client_id", value: clientID),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "include_granted_scopes", value: "false"),
            .init(name: "prompt", value: "consent"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleWorkspaceOAuthScopes.required.sorted().joined(separator: " ")),
            .init(name: "state", value: state),
        ]
        guard let authorizationURL = components.url, NSWorkspace.shared.open(authorizationURL) else {
            throw Failure.browser
        }

        let callback = try await Task.detached(priority: .userInitiated) {
            try listener.waitForCallback(expectedState: state, timeout: 300)
        }.value
        do {
            let status = try await api.exchangeAuthorizationCode(
                callback.code, verifier: verifier, redirectURI: redirectURI, clientID: clientID)
            callback.respond(success: true,
                message: "OpenBots Next is connected. You can close this page and return to the app.")
            try writeJSON(api: status)
        } catch {
            callback.respond(success: false,
                message: "OpenBots Next could not finish the connection. Return to the app for the reason.")
            throw error
        }
    }

    // `sending`: the input is built here and handed on whole. Swift 6.1 refuses a plain
    // non-Sendable result crossing from this nonisolated function into the main actor.
    private static func authorizedInput(for command: String, service: GoogleWorkspaceService,
                                        clientID: String, store: GoogleWorkspaceCredentialStore,
                                        keychain: any KeychainClient) async throws -> sending [String: Any] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 512 * 1024,
              let wrapper = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(wrapper.keys) == ["capability", "input"],
              let token = wrapper["capability"] as? String,
              let object = wrapper["input"] as? [String: Any] else {
            throw Failure.input
        }
        guard GoogleWorkspaceInstalledCallerPolicy.acceptsOperationalHelper(
            path: installedHelperPath()) else { throw Failure.caller }
        let proof = try await GoogleWorkspaceHelperCapability(keychain: keychain).validate(
            token, service: service, clientID: clientID, ancestorPIDs: ancestorPIDs())
        guard processPath(proof.issuerPID) == GoogleWorkspaceInstalledCallerPolicy.appPath else {
            throw Failure.caller
        }
        guard let credential = try await store.load(clientID: clientID),
              credential.connectionID == proof.connectionID else {
            throw GoogleWorkspaceCapabilityError.wrongConnection
        }
        _ = command // the service-bound closed switch above owns the verb set.
        return object
    }

    /// Lifecycle commands are accepted only when this exact installed helper
    /// was spawned directly by the exact app executable beside it. A copied
    /// helper and a process merely named OpenBots Next somewhere else both fail.
    private static func requireDirectOwningApp() throws -> Int32 {
        let parent = getppid()
        guard parent > 1, GoogleWorkspaceInstalledCallerPolicy.acceptsLifecycleCaller(
            helperPath: installedHelperPath(), parentPath: processPath(parent)) else {
            throw Failure.caller
        }
        return parent
    }

    private static func installedHelperPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    private static func ancestorPIDs() -> Set<Int32> {
        var result: Set<Int32> = []
        var pid = getppid()
        for _ in 0..<16 where pid > 1 && result.insert(pid).inserted {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            pid = Int32(info.pbi_ppid)
        }
        return result
    }

    private static func processPath(_ pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro Swift does not import; its
        // documented value is four MAXPATHLEN buffers.
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard count > 0 else { return nil }
        return String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func value(after flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw Failure.usage
        }
        return arguments[index + 1]
    }

    private static func boundedClientConfigurationInput() throws -> Data {
        let limit = GoogleWorkspaceCredentialStore.maximumClientConfigurationBytes
        var data = Data()
        while data.count <= limit {
            let remaining = limit + 1 - data.count
            guard let chunk = try FileHandle.standardInput.read(upToCount: min(8_192, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard !data.isEmpty, data.count <= limit else {
            throw GoogleWorkspaceClientConfigurationError.fileTooLarge
        }
        return data
    }

    private static func randomURLToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncoded
    }

    private static func writeJSON<T: Encodable>(api value: T) throws {
        try write(JSONEncoder().encode(value))
    }

    private static func writeJSON(api value: [String: String]) throws {
        try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }

    private static func write(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure.output }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private enum Failure: Error, LocalizedError {
        case usage, clientID, browser, input, output, caller
        var errorDescription: String? {
            switch self {
            case .usage: "Usage: openbots-google-helper <command> --client-id <desktop OAuth client id>"
            case .clientID: "This build has no valid Google Desktop OAuth client ID."
            case .browser: "The system browser could not be opened for Google authorization."
            case .input: "The Google connector received malformed input."
            case .output: "The Google connector result was too large."
            case .caller: "The Google credential helper was not launched by the installed OpenBots Next app."
            }
        }
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class LoopbackListener: @unchecked Sendable {
    let socketFD: Int32
    let port: UInt16

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ListenerFailure.socket }
        socketFD = descriptor
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var value: Int32 = 1
        _ = withUnsafePointer(to: &value) {
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, $0,
                       socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor); throw ListenerFailure.bind
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { close(descriptor); throw ListenerFailure.bind }
        port = UInt16(bigEndian: local.sin_port)
    }

    deinit { close(socketFD) }

    func waitForCallback(expectedState: String, timeout: TimeInterval) throws -> LoopbackCallback {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var poller = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(1_000, deadline.timeIntervalSinceNow * 1_000)))
            let ready = Darwin.poll(&poller, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw ListenerFailure.receive }
            if ready == 0 { continue }

            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { continue }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            do {
                let target = try Self.requestTarget(from: client, deadline: deadline)
                guard let components = URLComponents(string: "http://127.0.0.1" + target),
                      components.path.isEmpty || components.path == "/" else {
                    Self.respond(client, status: "404 Not Found", html: "Not found")
                    close(client); continue
                }
                var values: [String: String] = [:]
                for item in components.queryItems ?? [] {
                    guard let value = item.value, values.updateValue(value, forKey: item.name) == nil else {
                        throw ListenerFailure.receive
                    }
                }
                guard values["state"] == expectedState else {
                    Self.respond(client, status: "400 Bad Request", html: "This authorization response was not requested by OpenBots Next.")
                    close(client); continue
                }
                if let providerError = values["error"] {
                    Self.respond(client, status: "400 Bad Request", html: "Google authorization was declined.")
                    throw ListenerFailure.provider(providerError)
                }
                guard let code = values["code"], !code.isEmpty, code.utf8.count <= 8_192 else {
                    Self.respond(client, status: "400 Bad Request", html: "Google did not return an authorization code.")
                    throw ListenerFailure.receive
                }
                return LoopbackCallback(clientFD: client, code: code)
            } catch let error as ListenerFailure {
                close(client)
                if case .provider = error { throw error }
                // A local peer can connect to a loopback port, but without the
                // random state it can only waste this one bounded connection.
                // Malformed or stalled peers are dropped while the genuine
                // browser callback keeps its original five-minute deadline.
                continue
            } catch {
                close(client)
                continue
            }
        }
        throw ListenerFailure.timeout
    }

    private static func requestTarget(from descriptor: Int32, deadline: Date) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while data.count < 16_384 {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(1_000, deadline.timeIntervalSinceNow * 1_000)))
            guard milliseconds > 0, Darwin.poll(&poller, 1, milliseconds) > 0 else {
                throw ListenerFailure.receive
            }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { throw ListenerFailure.receive }
            data.append(buffer, count: count)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
            throw ListenerFailure.receive
        }
        guard let text = String(data: data, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else {
            throw ListenerFailure.receive
        }
        let pieces = line.split(separator: " ")
        guard pieces.count == 3, pieces[0] == "GET", pieces[2].hasPrefix("HTTP/1.") else {
            throw ListenerFailure.receive
        }
        return String(pieces[1])
    }

    fileprivate static func respond(_ descriptor: Int32, status: String, html: String) {
        let escaped = html.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let body = "<!doctype html><meta charset=\"utf-8\"><title>OpenBots Next</title>"
            + "<style>body{font:17px system-ui;max-width:42rem;margin:12vh auto;padding:2rem;line-height:1.5}</style>"
            + "<h1>OpenBots Next</h1><p>\(escaped)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
        response.withCString { pointer in
            _ = Darwin.send(descriptor, pointer, strlen(pointer), 0)
        }
    }

    enum ListenerFailure: Error, LocalizedError {
        case socket, bind, receive, timeout, provider(String)
        var errorDescription: String? {
            switch self {
            case .socket, .bind: "OpenBots Next could not open its private loopback callback for Google."
            case .receive: "The Google authorization response could not be read."
            case .timeout: "Google sign-in timed out. Nothing was connected."
            case .provider: "Google authorization was declined. Nothing was connected."
            }
        }
    }
}

private final class LoopbackCallback: @unchecked Sendable {
    let clientFD: Int32
    let code: String
    init(clientFD: Int32, code: String) { self.clientFD = clientFD; self.code = code }
    deinit { close(clientFD) }

    func respond(success: Bool, message: String) {
        LoopbackListener.respond(clientFD, status: success ? "200 OK" : "500 Internal Server Error",
                                 html: message)
    }
}
