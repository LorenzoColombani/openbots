import Foundation

/// The one place that decides whether a program already on this Mac is one the
/// app will run, and resolves it to the file that actually executes.
///
/// It is held to a different standard than a package's own files, because the
/// two are installed differently and one rule cannot fit both. Homebrew
/// installs `node` as a symlink into the Cellar, so refusing a symlink refuses
/// node itself; Chrome in `/Applications` is group-writable by `admin` on an
/// ordinary Mac, so refusing a group-writable executable refuses Chrome.
/// Between them, those two refusals would make the browser unusable on an
/// ordinary Mac.
///
/// What is still required: the resolved path is a regular file, executable,
/// owned by this user or by root, and **not writable by everyone**. The
/// resolved path is also what gets launched, so the symlink cannot be repointed
/// between the check and the run.
public struct InstalledToolResolution: Sendable {
    private let ownerUID: uid_t

    public init(ownerUID: uid_t = getuid()) { self.ownerUID = ownerUID }

    /// Made per call: `FileManager` is not `Sendable`, and the connector
    /// catalog reads the disk the same way.
    private var fileManager: FileManager { FileManager() }

    /// The file that will actually run, or nil when this is not one to run.
    public func resolve(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              owner == ownerUID || owner == 0,
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
              permissions & 0o002 == 0,
              fileManager.isExecutableFile(atPath: resolved.path)
        else { return nil }
        return resolved
    }

    /// The first candidate that resolves, in the order given. Candidates are
    /// candidates, not promises: an absent one is skipped, never guessed at.
    public func firstResolved(of candidates: [URL]) -> URL? {
        for candidate in candidates { if let resolved = resolve(candidate) { return resolved } }
        return nil
    }
}
