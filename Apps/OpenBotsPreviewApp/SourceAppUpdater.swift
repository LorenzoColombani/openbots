import AppKit
import OpenBotsServices
import OpenBotsUI

@MainActor
protocol NativeAppUpdating: AnyObject {
    var requiresCancellationBeforeQuit: Bool { get }
    func cancelUpdateBeforeQuitting(reply: @escaping (Bool) -> Void) -> Bool
    func terminationWasCanceled(reply: @escaping (Bool) -> Void)
    func beginShutdown()
}

extension NativeAppUpdating {
    func terminationWasCanceled(reply: @escaping (Bool) -> Void) { reply(true) }
    func beginShutdown() {}
}

/// The native boundary supplies the installed bundle and normal AppKit Quit.
/// No build process or installation is started merely by opening the app.
@MainActor
final class SourceAppUpdater: NativeAppUpdating {
    private let coordinator: SourceAppUpdateCoordinator

    init?(model: AppUpdateModel, googleConfiguration: GoogleWorkspaceUpdateConfiguration,
          verifyGoogleConfiguration: @escaping @Sendable () async throws -> GoogleWorkspaceUpdateConfiguration) {
        guard let configuration = model.configuration,
              case .source(let repository) = configuration.delivery,
              let publicKey = Data(base64Encoded: configuration.publicKey),
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return nil }
        let service = SourceAppUpdateService(
            configuration: .init(feedURL: configuration.feedURL, publicKey: publicKey, repository: repository),
            installedApplicationURL: Bundle.main.bundleURL, currentBuild: build,
            googleConfiguration: googleConfiguration)
        coordinator = SourceAppUpdateCoordinator(model: model, service: service,
            verifyGoogleConfiguration: verifyGoogleConfiguration,
            // Not terminate(nil) in place: this runs inside the coordinator's
            // main-actor task, and a .terminateLater reply also needs the main
            // actor, so Install and Relaunch would freeze on "Restarting…". A
            // run-loop pass later it is an ordinary Quit.
            requestTermination: {
                NSApplication.shared.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            })
        coordinator.startAutomaticChecks()
    }

    var requiresCancellationBeforeQuit: Bool { coordinator.requiresCancellationBeforeQuit }
    func cancelUpdateBeforeQuitting(reply: @escaping (Bool) -> Void) -> Bool {
        coordinator.cancelBeforeQuitting(reply: reply)
    }
    func terminationWasCanceled(reply: @escaping (Bool) -> Void) {
        coordinator.terminationWasCanceled(reply: reply)
    }
    func beginShutdown() { coordinator.beginShutdown() }
}
