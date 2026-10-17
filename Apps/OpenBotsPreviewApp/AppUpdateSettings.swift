import OpenBotsUI
import SwiftUI

@MainActor
struct AppUpdateInteractionGuard: ViewModifier {
    @ObservedObject var model: AppUpdateModel
    @ObservedObject private var admission = AppUpdateAdmission.shared
    func body(content: Content) -> some View {
        content.disabled(admission.isPreparing || model.isCancelingForQuit)
    }
}

@MainActor
struct AppUpdateSettings: View {
    @ObservedObject var model: AppUpdateModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.message)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.updates.status")
            if let notice = model.previousInstallationNotice {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.updates.previous-result")
            }
            HStack {
                if model.isSourceUpdate, case .available = model.state {
                    Button("Update now") { model.downloadSourceUpdate?() }
                        .disabled(!model.canDownloadSourceUpdate)
                        .accessibilityIdentifier("settings.updates.download")
                } else if model.isSourceUpdate, case .readyToInstall = model.state {
                    Button("Install and Relaunch") { model.installSourceUpdate?() }
                        .disabled(!model.canInstallSourceUpdate)
                        .accessibilityIdentifier("settings.updates.install")
                } else {
                    Button("Check for Updates…", action: model.checkForUpdates)
                        .disabled(!model.canCheck)
                        .accessibilityIdentifier("settings.updates.check")
                }
                if model.canCancelSourceUpdate {
                    Button("Cancel") { model.cancelSourceUpdate?() }
                        .accessibilityIdentifier("settings.updates.cancel")
                }
            }
            if model.isSourceUpdate {
                Text("Xcode builds the update on this Mac. When it is ready, you choose when to install and restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Updates deliver reviewed OpenBots fixes. Claude Code keeps its own installation and update settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct UpdateMenuAction: View {
    @ObservedObject var model: AppUpdateModel
    var body: some View {
        if model.isSourceUpdate, case .available = model.state {
            Button("Update now…") { model.downloadSourceUpdate?() }
                .disabled(!model.canDownloadSourceUpdate)
        } else if model.isSourceUpdate, case .readyToInstall = model.state {
            Button("Install and Relaunch") { model.installSourceUpdate?() }
                .disabled(!model.canInstallSourceUpdate)
        } else {
            Button("Check for Updates…", action: model.checkForUpdates)
                .disabled(!model.canCheck)
        }
        if model.canCancelSourceUpdate {
            // This remains reachable if failed helper cancellation must keep
            // the workspace and Settings controls frozen for another retry.
            Button("Cancel Update") { model.cancelSourceUpdate?() }
        }
    }
}
