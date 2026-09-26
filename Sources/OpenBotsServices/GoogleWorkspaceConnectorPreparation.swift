import Darwin
import Foundation
import OpenBotsDomain
import OpenBotsRuntime

public enum GoogleWorkspaceClientConfiguration {
    public static let infoDictionaryKey = "OpenBotsGoogleOAuthClientID"

    public static func clientID(bundle: Bundle = .main,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let candidate = environment["OPENBOTS_GOOGLE_OAUTH_CLIENT_ID"]
            ?? (bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String)
        guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              GoogleWorkspaceCredential.validClientID(value) else { return nil }
        return value
    }
}

/// Resolves the app-owned Google MCP server and its same-bundle credential
/// helper. The node server never receives a token; the helper is the only
/// executable that reads the app's Google Keychain item and calls Google.
public struct GoogleWorkspaceConnectorPreparation: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notGoogle
        case unsupportedTransport
        case malformedClientID
        case scriptMissing
        case helperMissing
        case interpreterMissing
        case clientConfigurationMissing
        case notConnected
        case fenceUnavailable(FenceProxyResource.Failure)
    }

    public static let gmailCommand = "google-gmail"
    public static let gmailSendCommand = "google-gmail-send"
    public static let calendarCommand = "google-calendar"
    public static let driveCommand = "google-drive"
    public static let helperName = "openbots-google-helper"

    public static var scriptURL: URL? {
        ServicesResourceBundle.url(forResource: "google-workspace", withExtension: "js")
    }

    public static var helperURLs: [URL] {
        var candidates: [URL] = []
        if let helpers = Bundle.main.builtInPlugInsURL?
            .deletingLastPathComponent().appendingPathComponent("Helpers") {
            candidates.append(helpers.appendingPathComponent(helperName))
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executable.appendingPathComponent(helperName))
        }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent(helperName))
        return candidates
    }

    private let script: URL?
    private let helperCandidates: [URL]
    private let interpreterCandidates: [URL]
    private let tools: InstalledToolResolution
    private let appName: String
    private let fence: FenceProxyResource

    public init(scriptURL: URL? = GoogleWorkspaceConnectorPreparation.scriptURL,
                helperCandidateURLs: [URL] = GoogleWorkspaceConnectorPreparation.helperURLs,
                interpreterCandidateURLs: [URL] = BrowserConnectorPreparation.defaultInterpreterURLs,
                appName: String = "OpenBots Next", ownerUID: uid_t = getuid(),
                fence: FenceProxyResource = FenceProxyResource()) {
        script = scriptURL; helperCandidates = helperCandidateURLs
        interpreterCandidates = interpreterCandidateURLs
        tools = InstalledToolResolution(ownerUID: ownerUID)
        self.appName = appName; self.fence = fence
    }

    public func resolve(_ launch: ConnectorLaunchConfiguration) throws
        -> (service: GoogleWorkspaceService, clientID: String, script: URL, helper: URL, interpreter: URL) {
        let service: GoogleWorkspaceService
        switch launch.command {
        case Self.gmailCommand: service = .gmail
        case Self.gmailSendCommand: service = .gmailSend
        case Self.calendarCommand: service = .calendar
        case Self.driveCommand: service = .drive
        default: throw Failure.notGoogle
        }
        guard launch.transport == .stdio else { throw Failure.unsupportedTransport }
        guard launch.arguments.count == 2, launch.arguments[0] == "--client-id",
              GoogleWorkspaceCredential.validClientID(launch.arguments[1]) else {
            throw Failure.malformedClientID
        }
        guard let script, FileManager().isReadableFile(atPath: script.path) else {
            throw Failure.scriptMissing
        }
        guard let helper = tools.firstResolved(of: helperCandidates) else { throw Failure.helperMissing }
        guard let interpreter = tools.firstResolved(of: interpreterCandidates) else {
            throw Failure.interpreterMissing
        }
        return (service, launch.arguments[1], script.standardizedFileURL, helper, interpreter)
    }

    public func connectionStatus(clientID: String, helperURL: URL) -> GoogleWorkspaceConnectionStatus {
        (try? GoogleWorkspaceHelperRunner(helperURL: helperURL, clientID: clientID,
                                          appName: appName).status())
            ?? .init(state: .invalid, reason: "The Google credential helper did not answer.")
    }

    public func clientConfigurationStatus(clientID: String, helperURL: URL)
        -> GoogleWorkspaceClientConfigurationStatus {
        (try? GoogleWorkspaceHelperRunner(helperURL: helperURL, clientID: clientID,
                                          appName: appName).clientConfigurationStatus())
            ?? .init(state: .invalid,
                reason: "The Google OAuth client configuration could not be checked.")
    }
}

extension GoogleWorkspaceConnectorPreparation: ConnectorLaunchPreparing {
    public func prepares(_ launch: ConnectorLaunchConfiguration) -> Bool {
        [Self.gmailCommand, Self.gmailSendCommand, Self.calendarCommand, Self.driveCommand].contains(launch.command)
    }

    public var needsOwnedProfile: Bool { false }

    public func server(for launch: ConnectorLaunchConfiguration, profileURL: URL?,
                       temporaryDirectoryURL: URL,
                       fence: FenceProxyResource) throws -> ClaudeTextConnectorServer {
        let resolved = try resolve(launch)
        guard clientConfigurationStatus(clientID: resolved.clientID,
                                        helperURL: resolved.helper).isReady else {
            throw Failure.clientConfigurationMissing
        }
        let status = connectionStatus(clientID: resolved.clientID, helperURL: resolved.helper)
        guard status.state == .connected, status.connectionID != nil else { throw Failure.notConnected }
        let capability = try GoogleWorkspaceHelperRunner(
            helperURL: resolved.helper, clientID: resolved.clientID, appName: appName)
            .capability(service: resolved.service)
        let role: ClaudeTextConnectorRole = switch resolved.service {
        case .gmail: .googleGmailReadDraft
        case .gmailSend: .googleGmailSend
        case .calendar: .googleCalendarRead
        case .drive: .googleDriveRead
        }
        precondition(role.handsBackUntrustedMaterial)
        let program: ClaudeTextConnectorProgram
        do {
            program = try fence.fenced(
                .node(interpreterURL: resolved.interpreter, entryPointURL: resolved.script),
                label: role.fenceLabel)
        } catch let failure as FenceProxyResource.Failure { throw Failure.fenceUnavailable(failure) }
        return try ClaudeTextConnectorServer(
            name: launch.serverKey, role: role, program: program, options: [],
            environment: [
                "OPENBOTS_APP_NAME": appName,
                "OPENBOTS_GOOGLE_CLIENT_ID": resolved.clientID,
                "OPENBOTS_GOOGLE_CAPABILITY": capability,
                "OPENBOTS_GOOGLE_HELPER": resolved.helper.path,
                "OPENBOTS_GOOGLE_SERVICE": resolved.service.rawValue,
            ])
    }

    public func availability(for launch: ConnectorLaunchConfiguration) -> ConnectorAvailability? {
        guard prepares(launch) else { return nil }
        do {
            let resolved = try resolve(launch)
            try fence.verify()
            let configuration = clientConfigurationStatus(
                clientID: resolved.clientID, helperURL: resolved.helper)
            guard configuration.isReady else {
                return .needsSetup(configuration.reason
                    ?? "Import the original Google Desktop OAuth client JSON below.")
            }
            let status = connectionStatus(clientID: resolved.clientID, helperURL: resolved.helper)
            switch status.state {
            case .connected: return .ready
            case .disconnected:
                return .needsSetup("Connect the separate OpenBots Google account below. OpenBots never sees its password.")
            case .revocationPending:
                return .needsSetup(status.reason ?? "Google access is disabled locally; finish provider cleanup below.")
            case .invalid:
                return .needsSetup(status.reason ?? "Reconnect the OpenBots Google account below.")
            }
        } catch Failure.malformedClientID {
            return .needsSetup("This build needs a new Google Desktop OAuth client before the account can be connected.")
        } catch Failure.scriptMissing, Failure.helperMissing {
            return .unavailable("This build is missing the Google connector. Reinstall the app.")
        } catch Failure.interpreterMissing {
            return .needsSetup("Node is not installed where the app can use it, and the Google connector needs it to run.")
        } catch let failure as FenceProxyResource.Failure {
            return FenceProxyResource.availability(for: failure)
        } catch {
            return .needsSetup("The Google connector cannot be used as this build carries it.")
        }
    }
}

public enum GoogleWorkspaceAuthorizationError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case busy
    case failed(String)
    /// The helper's refusal named the page of an API's switch in Google Cloud,
    /// one this build would have built itself (`GoogleWorkspaceAPIError.switchPage`).
    case failedWithSwitchPage(String, switchPage: URL)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message), .failedWithSwitchPage(let message, _): message
        case .busy: "A Google account action is already in progress."
        }
    }

    /// The page of the switch that would fix this, when there is one.
    public var switchPage: URL? {
        if case .failedWithSwitchPage(_, let page) = self { return page }
        return nil
    }
}

/// The app-settings action. Authorization happens in the bundled helper so the
/// same executable that creates the Keychain item is the only executable that
/// later reads it. The app receives status and the account address, never a
/// token or password.
@MainActor
public final class GoogleWorkspaceAuthorizationService {
    private let helperURL: URL?
    private let clientID: String?
    private let appName: String
    private var activeProcess: Process?
    private var outputPipe: Pipe?

    public init(helperURL: URL?, clientID: String?, appName: String = "OpenBots Next") {
        self.helperURL = helperURL; self.clientID = clientID; self.appName = appName
    }

    public var isConfigured: Bool { helperURL != nil && clientID != nil }

    public func status() async -> GoogleWorkspaceConnectionStatus {
        guard let helperURL, let clientID else {
            return .init(state: .invalid,
                reason: "This build needs a new Google Desktop OAuth client before the account can be connected.")
        }
        let appName = self.appName
        return await Task.detached(priority: .utility) {
            (try? GoogleWorkspaceHelperRunner(helperURL: helperURL, clientID: clientID,
                                              appName: appName).status())
                ?? .init(state: .invalid, reason: "The Google credential helper did not answer.")
        }.value
    }

    public func clientConfigurationStatus() async -> GoogleWorkspaceClientConfigurationStatus {
        guard let helperURL, let clientID else {
            return .init(state: .invalid,
                reason: "This build needs a valid Google Desktop OAuth client before its JSON can be imported.")
        }
        let appName = self.appName
        return await Task.detached(priority: .utility) {
            (try? GoogleWorkspaceHelperRunner(helperURL: helperURL, clientID: clientID,
                                              appName: appName).clientConfigurationStatus())
                ?? .init(state: .invalid,
                    reason: "The Google OAuth client configuration could not be checked.")
        }.value
    }

    /// The selected path never crosses the process boundary. The app opens and
    /// validates one regular bounded file, then the helper inherits that open
    /// descriptor as stdin and alone parses or stores its secret bytes.
    public func importClientConfiguration(from url: URL) async throws
        -> GoogleWorkspaceClientConfigurationStatus {
        guard activeProcess == nil else { throw GoogleWorkspaceAuthorizationError.busy }
        guard let helperURL, let clientID else {
            throw GoogleWorkspaceAuthorizationError.unavailable(
                "This build needs a valid Google Desktop OAuth client before its JSON can be imported.")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: url) }
        catch {
            throw GoogleWorkspaceAuthorizationError.failed(
                "The selected Google OAuth client JSON could not be read.")
        }
        defer { try? input.close() }
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              info.st_size <= off_t(GoogleWorkspaceCredentialStore.maximumClientConfigurationBytes)
        else {
            throw GoogleWorkspaceAuthorizationError.failed(
                "Choose one regular Google OAuth client JSON no larger than 64 KB.")
        }

        let process = GoogleWorkspaceHelperRunner.makeProcess(
            helperURL: helperURL, clientID: clientID, appName: appName,
            command: "import_client_configuration")
        let pipe = Pipe()
        process.standardInput = input
        process.standardOutput = pipe
        process.standardError = Pipe()
        activeProcess = process; outputPipe = pipe
        defer { activeProcess = nil; outputPipe = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    Task { @MainActor in
                        if finished.terminationStatus == 0,
                           data.count <= 64 * 1024,
                           let status = try? JSONDecoder().decode(
                               GoogleWorkspaceClientConfigurationStatus.self, from: data) {
                            continuation.resume(returning: status)
                        } else {
                            continuation.resume(throwing: GoogleWorkspaceAuthorizationError.failed(
                                Self.errorMessage(data)))
                        }
                    }
                }
                do { try process.run() }
                catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: GoogleWorkspaceAuthorizationError.unavailable(
                        "The bundled Google credential helper could not be started."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    public func authorize() async throws -> GoogleWorkspaceConnectionStatus {
        try await run("authorize")
    }

    public func stageRevocation() async throws -> GoogleWorkspaceConnectionStatus {
        try await run("stage_revocation")
    }

    public func finishRevocation() async throws -> GoogleWorkspaceConnectionStatus {
        try await run("finish_revocation")
    }

    public func cancel() {
        guard let process = activeProcess, process.isRunning else { return }
        process.terminate()
    }

    private func run(_ command: String) async throws -> GoogleWorkspaceConnectionStatus {
        guard activeProcess == nil else { throw GoogleWorkspaceAuthorizationError.busy }
        guard let helperURL, let clientID else {
            throw GoogleWorkspaceAuthorizationError.unavailable(
                "This build needs a new Google Desktop OAuth client before the account can be connected.")
        }
        let process = GoogleWorkspaceHelperRunner.makeProcess(
            helperURL: helperURL, clientID: clientID, appName: appName, command: command)
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = Pipe()
        activeProcess = process; outputPipe = pipe
        defer { activeProcess = nil; outputPipe = nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    Task { @MainActor in
                        if finished.terminationStatus == 0,
                           data.count <= 64 * 1024,
                           let status = try? JSONDecoder().decode(GoogleWorkspaceConnectionStatus.self,
                                                                  from: data) {
                            continuation.resume(returning: status)
                        } else {
                            continuation.resume(throwing: Self.failure(data))
                        }
                    }
                }
                do { try process.run() }
                catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: GoogleWorkspaceAuthorizationError.unavailable(
                        "The bundled Google credential helper could not be started."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// The helper's refusal, with the page of a switch only when it is one
    /// this build would have built.
    nonisolated fileprivate static func failure(_ data: Data) -> GoogleWorkspaceAuthorizationError {
        let message = errorMessage(data)
        guard data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let offered = object["enable_page"] as? String,
              let page = GoogleWorkspaceAPIError.switchPage(offered) else { return .failed(message) }
        return .failedWithSwitchPage(message, switchPage: page)
    }

    nonisolated fileprivate static func errorMessage(_ data: Data) -> String {
        guard data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String else {
            return "The Google account action did not finish. Nothing new was authorized."
        }
        return String(message.prefix(600))
    }
}

private struct GoogleWorkspaceHelperRunner: Sendable {
    let helperURL: URL
    let clientID: String
    let appName: String

    func status() throws -> GoogleWorkspaceConnectionStatus {
        let result = try runSmall(command: "status")
        guard result.status == 0, result.data.count <= 64 * 1024,
              let status = try? JSONDecoder().decode(GoogleWorkspaceConnectionStatus.self,
                                                      from: result.data)
        else { throw GoogleWorkspaceAuthorizationError.failed("The Google credential helper did not answer.") }
        return status
    }

    func clientConfigurationStatus() throws -> GoogleWorkspaceClientConfigurationStatus {
        let result = try runSmall(command: "client_configuration_status")
        guard result.status == 0, result.data.count <= 64 * 1024,
              let status = try? JSONDecoder().decode(
                  GoogleWorkspaceClientConfigurationStatus.self, from: result.data) else {
            throw GoogleWorkspaceAuthorizationError.failed(
                "The Google OAuth client configuration could not be checked.")
        }
        return status
    }

    func capability(service: GoogleWorkspaceService) throws -> String {
        let result = try runSmall(command: "authorize_connector",
                                  extraArguments: ["--service", service.rawValue])
        guard result.status == 0, result.data.count <= 16 * 1024,
              let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let capability = object["capability"] as? String,
              !capability.isEmpty, capability.utf8.count <= 4_096 else {
            throw GoogleWorkspaceAuthorizationError.failed(
                "The Google helper could not bind this connector to the running app.")
        }
        return capability
    }

    private func runSmall(command: String, extraArguments: [String] = []) throws
        -> (status: Int32, data: Data) {
        let process = Self.makeProcess(helperURL: helperURL, clientID: clientID,
            appName: appName, command: command, extraArguments: extraArguments)
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 2) != .success {
            process.terminate()
            if done.wait(timeout: .now() + 0.25) != .success {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            throw GoogleWorkspaceAuthorizationError.failed("The Google credential helper timed out.")
        }
        return (process.terminationStatus, pipe.fileHandleForReading.readDataToEndOfFile())
    }

    static func makeProcess(helperURL: URL, clientID: String, appName: String,
                            command: String, extraArguments: [String] = []) -> Process {
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [command, "--client-id", clientID] + extraArguments
        var environment: [String: String] = ["OPENBOTS_APP_NAME": appName]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "LANG"] {
            if let value = inherited[key] { environment[key] = value }
        }
        process.environment = environment
        return process
    }
}
