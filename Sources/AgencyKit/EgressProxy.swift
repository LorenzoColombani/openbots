import Foundation
import Network

/// The network egress fence's road out (spec 2026-08-13): a loopback-only HTTP
/// CONNECT proxy, one instance per fenced run. The child gets HTTPS_PROXY
/// pointing here; Seatbelt denies every other outbound route. Allowlisted
/// hosts tunnel through a blind TCP relay (no TLS interception — the CONNECT
/// line carries the hostname in the clear, proven live 2026-08-13); everything
/// else is refused with 403 and surfaced via `onDeny` so a tricked agent's
/// exfil attempt becomes a visible thread note, never a silent failure.
///
/// Native Swift (his call): no external runtime, identical for app and CLI,
/// and the listener dies with the process — no orphaned helpers.
public final class EgressProxy: @unchecked Sendable {
    /// Hosts a fenced run may reach, matched label-anchored (the host equals
    /// the entry or ends with "." + entry — a look-alike registration like
    /// evil-anthropic.com never matches). The spike proved a full run needs
    /// only api.anthropic.com; claude.ai covers auth; claude.com is the same
    /// owner's newer domain (CLI ≥2.1.232 calls platform.claude.com and exits 1
    /// when it's refused — observed live 2026-08-14). Anything else fails
    /// VISIBLY through onDeny — fail-closed, not fail-silent.
    public static let defaultAllowedHostSuffixes = ["anthropic.com", "claude.ai", "claude.com"]

    /// The fence means "the API", not "any service on the domain": every real
    /// connection observed is TLS on 443, so CONNECT to another port on an
    /// allowed host is refused too (/dod stage-2 finding).
    public static let defaultAllowedPorts: Set<UInt16> = [443]

    /// Hosts claude's OWN runtime phones on every run (observed live
    /// 2026-08-13: pypi.org version checks, Datadog logs intake). Their
    /// denials are the fence working QUIETLY — a thread note for each would
    /// bury the real signal (an agent-driven exfil attempt) in noise, so the
    /// app/broker suppress these from thread notices. The CLI still prints
    /// every denial to stderr, and the fence blocks them all the same.
    public static let knownRuntimeNoiseHosts = ["pypi.org", "datadoghq.com"]

    public static func isRuntimeNoise(host: String) -> Bool {
        isAllowed(host: host, suffixes: knownRuntimeNoiseHosts)
    }

    public static func isAllowedPort(_ port: UInt16, allowedPorts: Set<UInt16>) -> Bool {
        allowedPorts.contains(port)
    }

    private let allowed: [String]
    private let allowedPorts: Set<UInt16>
    /// Carries host AND port (review M8): a 443-rule denial on an ALLOWED host
    /// would otherwise read "egress denied: api.anthropic.com" — like the
    /// fence malfunctioning rather than refusing an odd port.
    private let onDeny: (@Sendable (String, UInt16) -> Void)?
    private var listener: NWListener?
    /// Live tunnels, mutated only on `queue` (review M9/M11): stop() must tear
    /// down established relays too, or a tunnel opened by a backgrounded child
    /// outlives the run it was fenced for.
    private var live: [NWConnection] = []
    private let queue = DispatchQueue(label: "agency.egress-proxy")

    public init(allowedHostSuffixes: [String] = EgressProxy.defaultAllowedHostSuffixes,
                allowedPorts: Set<UInt16> = EgressProxy.defaultAllowedPorts,
                onDeny: (@Sendable (String, UInt16) -> Void)? = nil) {
        self.allowed = allowedHostSuffixes
        self.allowedPorts = allowedPorts
        self.onDeny = onDeny
    }

    /// Label-anchored suffix match. Case-insensitive, tolerant of a trailing
    /// FQDN dot — DNS semantics, not string vibes.
    public static func isAllowed(host: String, suffixes: [String]) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return false }
        return suffixes.contains { s in
            let s = s.lowercased()
            return h == s || h.hasSuffix("." + s)
        }
    }

    /// Parses `CONNECT host:port HTTP/x` out of a request head. Anything else
    /// (GET/POST absolute-URI proxying included) returns nil — plain-HTTP
    /// egress is refused entirely; the API is HTTPS-only.
    public static func parseConnectTarget(_ head: String) -> (host: String, port: UInt16)? {
        guard let requestLine = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "CONNECT" else { return nil }
        let target = parts[1]
        guard let colon = target.lastIndex(of: ":"),
              let port = UInt16(target[target.index(after: colon)...]),
              colon != target.startIndex else { return nil }
        let host = String(target[..<colon])
        // Structural host validity (review M14): a userinfo trick like
        // `evil.com@api.anthropic.com` only failed at DNS by accident —
        // refuse anything that isn't a plain host token.
        guard !host.contains("@"), !host.contains("/"), !host.contains("\\") else { return nil }
        return (host, port)
    }

    /// Binds 127.0.0.1 on an ephemeral port and returns it. Throws when the
    /// listener cannot become ready — the caller must FAIL CLOSED (refuse the
    /// run), mirroring the sandbox-unavailable refusal.
    public func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        let sem = DispatchSemaphore(value: 0)
        let state = NSMutableString(string: "pending")
        listener.stateUpdateHandler = { s in
            switch s {
            case .ready: state.setString("ready"); sem.signal()
            case .failed, .cancelled: state.setString("failed"); sem.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        guard state as String == "ready", let port = listener.port?.rawValue else {
            listener.cancel()
            self.listener = nil
            throw ProcessFailure(status: -1, stderr: "egress proxy could not bind loopback")
        }
        return port
    }

    /// Stops accepting AND tears down live tunnels (review M9) — the fence
    /// dies with the run, not with the last relay. Serialised on `queue`
    /// (review M11) so it can't race the accept path.
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            live.forEach { $0.cancel() }
            live.removeAll()
        }
    }

    // MARK: connection handling

    /// On `queue` (listener callback). Tracks the connection for stop().
    private func handle(_ client: NWConnection) {
        live.removeAll { $0.state == .cancelled }   // prune as we go
        live.append(client)
        client.start(queue: queue)
        receiveHead(client, buffer: Data())
    }

    /// Accumulates until the end of the request head ("\r\n\r\n"), then routes.
    private func receiveHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { client.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 65536 || error != nil { client.cancel(); return }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done { client.cancel() } else { self.receiveHead(client, buffer: buffer) }
                return
            }
            let head = String(data: buffer[..<headEnd.upperBound], encoding: .utf8) ?? ""
            guard let target = Self.parseConnectTarget(head) else {
                self.refuse(client, status: "405 Method Not Allowed")
                return
            }
            guard Self.isAllowed(host: target.host, suffixes: self.allowed),
                  Self.isAllowedPort(target.port, allowedPorts: self.allowedPorts) else {
                self.onDeny?(target.host, target.port)
                self.refuse(client, status: "403 Forbidden")
                return
            }
            self.tunnel(client, to: target, clientLeftover: buffer[headEnd.upperBound...])
        }
    }

    private func refuse(_ client: NWConnection, status: String) {
        let resp = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        client.send(content: Data(resp.utf8), completion: .contentProcessed { _ in client.cancel() })
    }

    /// Opens the upstream connection, confirms the tunnel to the client, then
    /// relays blindly in both directions until either side closes.
    private func tunnel(_ client: NWConnection, to target: (host: String, port: UInt16),
                        clientLeftover: Data) {
        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            refuse(client, status: "400 Bad Request"); return
        }
        let upstream = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        live.append(upstream)   // on `queue` (receive callback) — stop() reaches it
        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
                client.send(content: Data(ok.utf8), completion: .contentProcessed { _ in
                    // Any bytes the client sent past the head (TLS hello) go first.
                    if !clientLeftover.isEmpty {
                        upstream.send(content: clientLeftover, completion: .contentProcessed { _ in })
                    }
                    Self.pump(client, into: upstream)
                    Self.pump(upstream, into: client)
                })
            case .failed, .cancelled:
                client.cancel()
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    /// One direction of the relay: read → write → repeat; EOF/error tears both down.
    private static func pump(_ from: NWConnection, into to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { from.cancel(); to.cancel(); return }
                    if done || error != nil { from.cancel(); to.cancel() }
                    else { pump(from, into: to) }
                })
            } else if done || error != nil {
                from.cancel(); to.cancel()
            } else {
                pump(from, into: to)
            }
        }
    }
}
