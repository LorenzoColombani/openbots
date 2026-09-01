import OpenBotsDomain
import SwiftUI

/// A single, source-ordered native inspector surface. It presents fixture
/// authority only, never a live permission switch or execution shortcut.
public struct TrustAuthorizationWorkspaceView: View {
    @ObservedObject private var model: TrustAuthorizationWorkspaceModel

    public init(model: TrustAuthorizationWorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
            header
            if model.context == nil {
                note(TrustAuthorizationPresentation.noContextMessage)
            } else if let snapshot = model.snapshot {
                grants(snapshot)
                if let review = model.pendingGrantReview {
                    grantReview(review)
                }
                actions(snapshot)
                if let review = model.approvalReview {
                    actionReview(review)
                }
                readiness(snapshot)
                shellBoundary
                evidence(snapshot)
            } else if !model.isBusy {
                Button("Load Demo Access") { Task { await model.load() } }
            }
            if model.isBusy {
                Label("Updating demo review…", systemImage: "clock")
                    .font(.caption)
            }
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Access and Approvals — local simulation")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label("Access & Approvals", systemImage: "hand.raised")
                .font(.headline)
            if let context = model.context {
                Text("Demo access for \(model.teammateName)")
                    .font(.subheadline.weight(.semibold))
                Text("Conversation \(context.conversationID.description.prefix(8))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            note(TrustAuthorizationPresentation.fixtureDisclosure)
        }
    }

    private func grants(_ snapshot: TrustFixtureSnapshot) -> some View {
        GroupBox("Teammate demo capabilities") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                note(TrustAuthorizationPresentation.readChangeBoundary)
                ForEach(FixtureCapability.allCases, id: \.self) { capability in
                    if capability != .readReferenceFolder { Divider() }
                    grantRow(capability, snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func grantRow(
        _ capability: FixtureCapability,
        snapshot: TrustFixtureSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(capabilityHeading(capability))
                .font(.subheadline.weight(.semibold))
            note(capability.scopeSummary)
            if snapshot.activeGrant(for: capability) != nil {
                Label("Demo grant active", systemImage: "checkmark.shield")
                    .font(.caption)
                Button("Revoke Demo Grant") { Task { await model.revoke(capability) } }
                    .accessibilityLabel("Revoke demo grant: \(capability.title)")
                    .disabled(model.isBusy)
            } else {
                Text(snapshot.grants.contains { $0.capability == capability } ? "Demo grant revoked" : "Off by default")
                    .font(.caption)
                Button("Review Demo Grant") { Task { await model.prepareGrant(capability) } }
                    .accessibilityLabel("Review demo grant: \(capability.title)")
                    .disabled(model.isBusy || model.hasActiveReview)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func grantReview(_ review: FixtureGrantReview) -> some View {
        GroupBox("Review demo grant") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                reviewValue("Teammate", model.teammateName)
                reviewValue("Allowed operation", review.capability.title)
                reviewValue("Exact demo scope", review.scopeSummary)
                note(review.effectSummary)
                reviewMetadata(fingerprint: review.fingerprint, expiresAt: review.expiresAt)
                if model.grantReviewState == .pending {
                    Button("Confirm Demo Grant") { Task { await model.confirmPendingGrant() } }
                        .disabled(model.isBusy)
                } else {
                    note("This demo grant review is \(model.grantReviewState?.rawValue ?? "unavailable").")
                }
                Button("Cancel") { Task { await model.cancelPendingGrant() } }
                    .accessibilityLabel("Cancel demo grant review")
                    .disabled(model.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ snapshot: TrustFixtureSnapshot) -> some View {
        GroupBox("Exact action reviews") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing12) {
                actionChoice(
                    "Review Demo Artifact",
                    proposal: .sampleArtifact,
                    capability: .createCompletedArtifact,
                    snapshot: snapshot
                )
                Divider()
                actionChoice(
                    "Review Demo Message",
                    proposal: .sampleConnectorSend,
                    capability: .connectorUse,
                    snapshot: snapshot
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionChoice(
        _ title: String,
        proposal: FixtureActionProposal,
        capability: FixtureCapability,
        snapshot: TrustFixtureSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(proposal.targetSummary)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let blocker = snapshot.eligibilityBlocker(for: capability) {
                note(blocker)
            }
            Button(title) { Task { await model.prepareApproval(proposal) } }
                .disabled(
                    model.isBusy || model.hasActiveReview
                    || snapshot.eligibilityBlocker(for: capability) != nil
                )
        }
    }

    private func actionReview(_ review: FixtureApprovalReview) -> some View {
        GroupBox("Frozen demo action") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                reviewValue("Teammate", model.teammateName)
                reviewValue("Exact target / account", review.proposal.targetSummary)
                reviewValue("Exact payload", review.proposal.payloadSummary)
                note(review.scopeSummary)
                note(review.effectSummary)
                reviewMetadata(fingerprint: review.fingerprint, expiresAt: review.expiresAt)
                note(TrustAuthorizationPresentation.reviewDisclosure)
                actionResolution
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actionResolution: some View {
        switch model.approvalState {
        case .pending:
            Button("Approve Once") { Task { await model.approveOnce() } }
                .accessibilityLabel("Approve exact demo action once — does not execute")
                .disabled(model.isBusy)
            Button("Deny") { Task { await model.deny() } }
                .accessibilityLabel("Deny exact demo action")
                .disabled(model.isBusy)
        case .approved:
            Label("Demo approval recorded — not executed", systemImage: "checkmark.circle")
                .font(.caption)
            Button("Simulate Once") { Task { await model.simulateOnce() } }
                .accessibilityLabel("Simulate approved demo action once — no real action")
                .disabled(model.isBusy)
        case .simulated:
            Label("Simulated once. No file was created and no message was sent.", systemImage: "checkmark.seal")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        case .denied:
            Label("Denied. No action ran.", systemImage: "hand.raised")
                .font(.caption)
        case .expired:
            Label("Expired. Prepare a new exact review.", systemImage: "clock.badge.exclamationmark")
                .font(.caption)
        case .invalidated:
            Label("No longer authorized. Review the current demo grant and readiness.", systemImage: "shield.slash")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            note("This review is unavailable. No action ran.")
        }
    }

    private func readiness(_ snapshot: TrustFixtureSnapshot) -> some View {
        GroupBox("Independent demo readiness") {
            VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing8) {
                note(TrustAuthorizationPresentation.readinessDisclosure)
                Picker("macOS permission (demo)", selection: Binding(
                    get: { snapshot.macOSPermission },
                    set: { value in Task { await model.setMacOSPermission(value) } }
                )) {
                    Text("Not requested").tag(FixtureMacOSPermission.notDetermined)
                    Text("Granted").tag(FixtureMacOSPermission.granted)
                    Text("Denied").tag(FixtureMacOSPermission.denied)
                    Text("Restricted").tag(FixtureMacOSPermission.restricted)
                    Text("Unknown").tag(FixtureMacOSPermission.unknown)
                }
                .accessibilityLabel("Simulated macOS permission — no system prompt")
                Picker("Connector install (demo)", selection: Binding(
                    get: { snapshot.connector.installation },
                    set: { value in Task { await model.setConnectorInstallation(value) } }
                )) {
                    Text("Not installed").tag(ConnectorInstallationState.notInstalled)
                    Text("Installed").tag(ConnectorInstallationState.installed)
                    Text("Failed").tag(ConnectorInstallationState.failed)
                }
                .accessibilityLabel("Simulated connector installation")
                Picker("Account sign-in (demo)", selection: Binding(
                    get: { snapshot.connector.accountAuthentication },
                    set: { value in Task { await model.setConnectorAuthentication(value) } }
                )) {
                    Text("Not signed in").tag(ConnectorAccountAuthenticationState.notAuthenticated)
                    Text("Signed in").tag(ConnectorAccountAuthenticationState.authenticated)
                    Text("Failed").tag(ConnectorAccountAuthenticationState.failed)
                }
                .accessibilityLabel("Simulated account authentication — no account access")
                reviewValue("Connector bot grant (demo)", connectorGrantLabel(snapshot.connector.perBotGrant))
                reviewValue("Connector action approval (demo)", connectorApprovalLabel(snapshot.connector.perActionApproval))
            }
            .pickerStyle(.menu)
            .disabled(model.isBusy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shellBoundary: some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Label(TrustAuthorizationPresentation.shellStatus, systemImage: "terminal")
                .font(.caption.weight(.semibold))
            note(TrustAuthorizationPresentation.shellWarning)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func evidence(_ snapshot: TrustFixtureSnapshot) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text("Recent demo activity").font(.caption.weight(.semibold))
            if snapshot.evidence.isEmpty {
                note("No demo decisions yet.")
            } else {
                ForEach(Array(snapshot.evidence.suffix(3).reversed())) { entry in
                    Text(entry.summary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func reviewValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewMetadata(fingerprint: String, expiresAt: Date) -> some View {
        VStack(alignment: .leading, spacing: OpenBotsVisualStyle.spacing4) {
            Text("Review \(TrustAuthorizationPresentation.shortFingerprint(fingerprint))")
                .font(.caption.monospaced())
            Text("Expires \(expiresAt.formatted(date: .omitted, time: .standard))")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func capabilityHeading(_ capability: FixtureCapability) -> String {
        switch capability {
        case .readReferenceFolder: "Read broadly"
        case .createCompletedArtifact: "Change narrowly"
        case .connectorUse: "Use one connector account"
        }
    }

    private func connectorGrantLabel(_ state: ConnectorPerBotGrantState) -> String {
        switch state {
        case .notGranted: "Not granted"
        case .granted: "Granted"
        case .revoked: "Revoked"
        }
    }

    private func connectorApprovalLabel(_ state: ConnectorPerActionApprovalState) -> String {
        switch state {
        case .notRequested: "Not requested"
        case .pending: "Pending exact review"
        case .approved: "Approved once; not an account-wide grant"
        case .denied: "Denied"
        }
    }
}
