import Foundation
import OpenBotsServices
import Testing
@testable import OpenBotsUI

@Suite("Application updates") @MainActor
struct AppUpdateModelTests {
    private func makeModel(configuration: AppUpdateConfiguration?, admission: AppUpdateAdmission = AppUpdateAdmission(),
                           timeout: Duration = .seconds(3), blocker: @escaping () -> String? = { nil },
                           save: @escaping () async -> Bool = { true }) -> AppUpdateModel {
        let model = AppUpdateModel(configuration: configuration, admission: admission, timeout: timeout, blocker: blocker, save: save)
        model.setDriverAvailability(configuration != nil)
        return model
    }

    @Test func nativeDriverReadinessControlsActionAdmission() {
        let model = AppUpdateModel(configuration: configuration)
        var checks = 0
        model.check = { checks += 1 }
        model.checkForUpdates()
        #expect(checks == 0, "A configured but unstarted or failed native driver cannot check")
        model.setDriverAvailability(true)
        model.checkForUpdates()
        #expect(checks == 1)
        model.setDriverAvailability(false)
        model.checkForUpdates()
        #expect(checks == 1, "The native driver's changing availability remains authoritative")
    }

    private var configuration: AppUpdateConfiguration {
        AppUpdateConfiguration(info: ["OpenBotsSourceUpdateEnabled": true,
                                      "OpenBotsSourceUpdateFeedURL": "https://updates.example.test/source-update.json",
                                      "OpenBotsSourceUpdatePublicKey": Data(repeating: 7, count: 32).base64EncodedString(),
                                      "OpenBotsSourceUpdateRepository": "example/openbots"])!
    }
    @Test func absentAndMalformedConfigurationStayInert() {
        for info: [String: Any] in [[:], ["OpenBotsSourceUpdateFeedURL": "http://updates.test/feed", "OpenBotsSourceUpdatePublicKey": "x"],
                                   ["OpenBotsSourceUpdateFeedURL": "https://user:secret@updates.test/feed",
                                    "OpenBotsSourceUpdatePublicKey": Data(repeating: 1, count: 32).base64EncodedString()]] {
            var enabledInfo = info
            enabledInfo["OpenBotsSourceUpdateEnabled"] = true
            enabledInfo["OpenBotsSourceUpdateRepository"] = "example/openbots"
            let model = makeModel(configuration: AppUpdateConfiguration(info: enabledInfo))
            var checked = false
            model.check = { checked = true }
            model.checkForUpdates()
            #expect(model.state == .inactive)
            #expect(model.checking() == nil)
            #expect(!checked)
        }
    }
    @Test func validFeedAndKeyDoNotBypassReleaseActivation() {
        let info: [String: Any] = ["OpenBotsSourceUpdateFeedURL": "https://updates.example.test/source-update.json",
                                  "OpenBotsSourceUpdatePublicKey": Data(repeating: 7, count: 32).base64EncodedString(),
                                  "OpenBotsSourceUpdateRepository": "example/openbots",
                                  "OpenBotsSourceUpdateEnabled": false]
        #expect(AppUpdateConfiguration(info: info) == nil)
    }
    @Test func findingAnUpdateDoesNotAuthorizeInstallation() throws {
        let model = makeModel(configuration: configuration)
        let cycle = try #require(model.checking())
        #expect(model.found(version: "1.1", cycle: cycle))
        var allowed = true
        model.prepareInstallation(cycle: cycle) { allowed = $0 }
        #expect(!allowed)
        #expect(model.state == .available("1.1"))
    }
    @Test func rechecksActivityAfterPersistenceAwait() async throws {
        var busy = false
        let admission = AppUpdateAdmission()
        let model = makeModel(configuration: configuration, admission: admission,
            blocker: { busy ? "An operation arrived." : nil }, save: { busy = true; return true })
        let cycle = try #require(model.checking())
        #expect(model.found(version: "1.1", cycle: cycle))
        #expect(model.authorizeDownload(cycle: cycle))
        model.sourceReady(version: "1.1", cycle: cycle)
        let allowed = await withCheckedContinuation { continuation in
            model.prepareInstallation(cycle: cycle) { continuation.resume(returning: $0) }
        }
        #expect(!allowed)
        #expect(admission.allowsWork)
        #expect(model.state == .readyToInstall("1.1"), "The finished build stays ready for another try")
    }
    @Test func timedOutSaveReturnsToUsableState() async throws {
        let admission = AppUpdateAdmission()
        let model = makeModel(configuration: configuration, admission: admission, timeout: .milliseconds(10), save: {
            try? await Task.sleep(for: .seconds(60))
            return true
        })
        let cycle = try #require(model.checking())
        #expect(model.found(version: "1.1", cycle: cycle))
        #expect(model.authorizeDownload(cycle: cycle))
        model.sourceReady(version: "1.1", cycle: cycle)
        let allowed = await withCheckedContinuation { continuation in
            model.prepareInstallation(cycle: cycle) { continuation.resume(returning: $0) }
        }
        #expect(!allowed)
        #expect(admission.allowsWork)
        #expect(model.state == .readyToInstall("1.1"))
    }

    @Test func acceptedOperationPreventsFreezeAndFreezeRejectsNewOperation() {
        let gate = ApplicationUpdateGate()
        var operation = gate.beginOperation()
        #expect(operation != nil)
        let token = UUID()
        #expect(!gate.freeze(token))
        withExtendedLifetime(operation) {}
        operation = nil
        #expect(gate.freeze(token))
        #expect(gate.beginOperation() == nil)
        gate.release(UUID())
        #expect(!gate.allowsWork)
        gate.release(token)
        #expect(gate.beginOperation() != nil)
    }

    @Test func anOpenAttachmentPickerBlocksPreparationUntilItsResultIsConsumed() {
        let gate = ApplicationUpdateGate()
        let draft = AttachmentDraftModel(importer: { _, _ in throw CancellationError() })
        let request = AttachmentPickerRequest(draft: draft, updateGate: gate)
        let token = UUID()
        #expect(!gate.freeze(token), "A picker has pending user work before ingestion begins")
        #expect(!request.consume(nil))
        #expect(gate.freeze(token))
        let late = AttachmentPickerRequest(draft: draft, updateGate: gate)
        #expect(!late.consume(URL(fileURLWithPath: "/tmp/unopened-update-picker-fixture")))
        #expect(draft.rows.isEmpty)
        gate.release(token)
    }
}
