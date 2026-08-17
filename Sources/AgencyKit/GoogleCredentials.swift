import Foundation

/// The agency Google account's OAuth client (his setup 2026-08-13). The
/// downloaded client JSON lives in `<root>/.secrets/` — gitignored, never
/// committed — and the app reads it at mcp.json generation time so no secret
/// is duplicated by hand.
///
/// Scope note: a DESKTOP OAuth client id+secret is public by design (RFC 8252
/// — a desktop app cannot keep it confidential); the real credentials are the
/// refresh tokens, which workspace-mcp stores outside the agent folders. So
/// putting these two values in a granted agent's own mcp.json is acceptable —
/// and that file is already fenced from every OTHER agent by the pocket rules.
public enum GoogleCredentials {
    public struct Client: Equatable {
        public let id: String
        public let secret: String
    }

    public static func secretsDir(root: URL) -> URL { root.appendingPathComponent(".secrets") }

    /// First readable Google client JSON in `<root>/.secrets/`, desktop
    /// ("installed") or web shape. nil when Lorenzo hasn't dropped one yet —
    /// callers then omit the server entirely rather than emit a broken one.
    public static func client(root: URL) -> Client? {
        let dir = secretsDir(root: root)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let node = (obj["installed"] as? [String: Any]) ?? (obj["web"] as? [String: Any])
            guard let node,
                  let id = node["client_id"] as? String,
                  let secret = node["client_secret"] as? String,
                  !id.isEmpty, !secret.isEmpty else { continue }
            return Client(id: id, secret: secret)
        }
        return nil
    }
}
