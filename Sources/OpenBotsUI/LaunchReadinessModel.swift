import Combine
import OpenBotsServices

/// Main-actor presentation state for the read-only startup check. Constructing
/// the model retains only the injected inspector; inspection begins solely when
/// `refresh()` is called.
@MainActor
public final class LaunchReadinessModel: ObservableObject {
    @Published public private(set) var state: LaunchReadinessState = .notConfigured

    private let readinessService: LaunchReadinessService
    private var refreshGeneration: UInt64 = 0

    public init(inspector: any LaunchReadinessInspecting) {
        readinessService = LaunchReadinessService(inspector: inspector)
    }

    /// Runs the executor-independent inspection and publishes an immediate,
    /// non-spinner opening state while it is in flight.
    public func refresh() async {
        guard state != .opening else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .opening
        let inspectedState = await readinessService.inspectReadiness()
        guard generation == refreshGeneration else { return }
        state = inspectedState
    }

    /// Lets previews and design review render every closed state without
    /// performing filesystem, database, credential, or runtime work.
    public func setPreviewReviewState(_ state: LaunchReadinessState) {
        refreshGeneration &+= 1
        self.state = state
    }
}
