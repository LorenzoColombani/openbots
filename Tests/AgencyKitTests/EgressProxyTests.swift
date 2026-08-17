import XCTest
import Network
@testable import AgencyKit

/// Network egress fence (spec 2026-08-13): a fenced agent's only road out is a
/// local CONNECT proxy that forwards allowlisted hosts and refuses the rest.
/// Feasibility proven live: claude honors HTTPS_PROXY end-to-end, and the
/// CONNECT line carries the hostname in the clear — no TLS interception needed.
final class EgressProxyTests: XCTestCase {
    // MARK: allowlist — label-anchored suffix matching

    func testAllowlistMatchesHostAndSubdomains() {
        XCTAssertTrue(EgressProxy.isAllowed(host: "anthropic.com", suffixes: ["anthropic.com"]))
        XCTAssertTrue(EgressProxy.isAllowed(host: "api.anthropic.com", suffixes: ["anthropic.com"]))
        XCTAssertTrue(EgressProxy.isAllowed(host: "statsig.anthropic.com", suffixes: ["anthropic.com"]))
    }

    func testAllowlistIsLabelAnchored() {
        // The classic bypass: a registered look-alike domain must NEVER match.
        XCTAssertFalse(EgressProxy.isAllowed(host: "evil-anthropic.com", suffixes: ["anthropic.com"]))
        XCTAssertFalse(EgressProxy.isAllowed(host: "evilanthropic.com", suffixes: ["anthropic.com"]))
        XCTAssertFalse(EgressProxy.isAllowed(host: "anthropic.com.evil.net", suffixes: ["anthropic.com"]))
    }

    func testAllowlistIsCaseInsensitiveAndTrimsTrailingDot() {
        // DNS is case-insensitive and `host.` (FQDN root dot) is the same host.
        XCTAssertTrue(EgressProxy.isAllowed(host: "API.Anthropic.COM", suffixes: ["anthropic.com"]))
        XCTAssertTrue(EgressProxy.isAllowed(host: "api.anthropic.com.", suffixes: ["anthropic.com"]))
    }

    func testDefaultAllowlistCoversTheAPIAndNothingGeneric() {
        XCTAssertTrue(EgressProxy.isAllowed(host: "api.anthropic.com",
                                            suffixes: EgressProxy.defaultAllowedHostSuffixes))
        XCTAssertTrue(EgressProxy.isAllowed(host: "claude.ai",
                                            suffixes: EgressProxy.defaultAllowedHostSuffixes))
        // CLI ≥2.1.232 calls platform.claude.com and dies (exit 1) when the
        // fence refuses it — the 2026-08-14 "every teammate stuck" incident.
        XCTAssertTrue(EgressProxy.isAllowed(host: "platform.claude.com",
                                            suffixes: EgressProxy.defaultAllowedHostSuffixes))
        XCTAssertFalse(EgressProxy.isAllowed(host: "evil-claude.com",
                                             suffixes: EgressProxy.defaultAllowedHostSuffixes),
                       "label-anchored: look-alike registrations never match")
        XCTAssertFalse(EgressProxy.isAllowed(host: "example.com",
                                             suffixes: EgressProxy.defaultAllowedHostSuffixes))
    }

    // MARK: runtime-noise suppression (/dod stage-2 finding, 2026-08-13)

    func testKnownRuntimeNoiseHostsAreClassified() {
        // Observed live: claude's OWN runtime phones these on every run. Their
        // denials are the fence working quietly — thread notices for them
        // would bury the real signal (an agent-driven exfil attempt).
        XCTAssertTrue(EgressProxy.isRuntimeNoise(host: "pypi.org"))
        XCTAssertTrue(EgressProxy.isRuntimeNoise(host: "http-intake.logs.us5.datadoghq.com"))
        XCTAssertFalse(EgressProxy.isRuntimeNoise(host: "example.com"),
                       "anything unobserved stays LOUD")
        XCTAssertFalse(EgressProxy.isRuntimeNoise(host: "evil-pypi.org"), "label-anchored here too")
    }

    // MARK: port restriction (/dod stage-2 finding)

    func testOnlyPort443TunnelsByDefault() {
        // The fence means "the API", not "any service on the domain" — all
        // real traffic is TLS on 443; CONNECT api.anthropic.com:25 is refused.
        XCTAssertTrue(EgressProxy.isAllowedPort(443, allowedPorts: EgressProxy.defaultAllowedPorts))
        XCTAssertFalse(EgressProxy.isAllowedPort(25, allowedPorts: EgressProxy.defaultAllowedPorts))
        XCTAssertFalse(EgressProxy.isAllowedPort(80, allowedPorts: EgressProxy.defaultAllowedPorts))
    }

    // MARK: CONNECT parsing

    func testParsesConnectTarget() {
        let head = "CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n"
        let t = EgressProxy.parseConnectTarget(head)
        XCTAssertEqual(t?.host, "api.anthropic.com")
        XCTAssertEqual(t?.port, 443)
    }

    func testRejectsNonConnectAndGarbage() {
        XCTAssertNil(EgressProxy.parseConnectTarget("GET http://x.com/ HTTP/1.1\r\n\r\n"),
                     "plain-HTTP proxying is refused — the API is HTTPS-only")
        XCTAssertNil(EgressProxy.parseConnectTarget("CONNECT no-port HTTP/1.1\r\n\r\n"))
        XCTAssertNil(EgressProxy.parseConnectTarget("CONNECT x.com:notaport HTTP/1.1\r\n\r\n"))
        XCTAssertNil(EgressProxy.parseConnectTarget(""))
    }

    /// fence review M14/M16: hostname confusion + IPv6 literals.
    func testHostConfusionAndIPv6Literals() {
        XCTAssertNil(EgressProxy.parseConnectTarget("CONNECT evil.com@api.anthropic.com:443 HTTP/1.1\r\n\r\n"),
                     "userinfo tricks are refused STRUCTURALLY, not left to DNS")
        XCTAssertNil(EgressProxy.parseConnectTarget("CONNECT api.anthropic.com/x:443 HTTP/1.1\r\n\r\n"))
        // An IPv6 literal parses (last-colon split → host "[::1]") but no
        // bracketed literal ever matches a name suffix — denied downstream.
        let v6 = EgressProxy.parseConnectTarget("CONNECT [::1]:443 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(v6?.port, 443)
        XCTAssertFalse(EgressProxy.isAllowed(host: v6?.host ?? "",
                                             suffixes: EgressProxy.defaultAllowedHostSuffixes))
    }

    // MARK: INTEGRATION — a real proxy, a real curl, all loopback (free, offline)

    /// A minimal loopback HTTP server: answers any request with a fixed body.
    private func startLoopbackServer(body: String) throws -> (NWListener, UInt16) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let ready = expectation(description: "server ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!.rawValue)
    }

    private func curl(_ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus,
                String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    func testProxyForwardsAllowlistedHostEndToEnd() throws {
        let (server, serverPort) = try startLoopbackServer(body: "fence-ok")
        defer { server.cancel() }
        // The loopback test server sits on an ephemeral port, so the test
        // widens allowedPorts — production keeps the [443] default.
        let proxy = EgressProxy(allowedHostSuffixes: ["127.0.0.1"], allowedPorts: [serverPort])
        let proxyPort = try proxy.start()
        defer { proxy.stop() }
        // -p forces a CONNECT tunnel even for an http:// URL — the exact shape
        // claude produces for its HTTPS traffic.
        let r = curl(["-sS", "-p", "--proxy", "http://127.0.0.1:\(proxyPort)",
                      "--connect-timeout", "5", "http://127.0.0.1:\(serverPort)/"])
        XCTAssertEqual(r.status, 0, "allowlisted CONNECT must flow: \(r.err)")
        XCTAssertEqual(r.out, "fence-ok", "bytes relayed both ways")
    }

    /// Lock-protected accumulator: the naked `var` + closure capture was the
    /// suite's last Swift-6 Sendable warning (2026-08-13 full-audit sweep).
    private final class Denials: @unchecked Sendable {
        private var items: [String] = []
        private let lock = NSLock()
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testProxyRefusesNonAllowlistedHostWithoutConnecting() throws {
        let denied = Denials()
        let proxy = EgressProxy(allowedHostSuffixes: ["anthropic.com"],
                                onDeny: { host, port in denied.add("\(host):\(port)") })
        let proxyPort = try proxy.start()
        defer { proxy.stop() }
        // RFC-5737 TEST-NET address: if the proxy (wrongly) tried to connect,
        // nothing answers — but a correct proxy refuses BEFORE any connect, so
        // this returns fast with curl's "proxy refused" failure.
        let r = curl(["-sS", "-p", "--proxy", "http://127.0.0.1:\(proxyPort)",
                      "--connect-timeout", "3", "http://192.0.2.9/"])
        XCTAssertNotEqual(r.status, 0, "denied host must not tunnel")
        XCTAssertEqual(denied.all, ["192.0.2.9:80"],
                       "the denial names host AND port (review M8) — it becomes a thread alert")
    }

    func testProxyRefusesAllowlistedHostOnDisallowedPort() throws {
        // /dod stage-2 finding: host-only matching would tunnel to ANY port on
        // an allowed domain. The fence means "the API" — 443 only by default.
        let (server, serverPort) = try startLoopbackServer(body: "should-not-arrive")
        defer { server.cancel() }
        let proxy = EgressProxy(allowedHostSuffixes: ["127.0.0.1"])   // default ports = [443]
        let proxyPort = try proxy.start()
        defer { proxy.stop() }
        let r = curl(["-sS", "-p", "--proxy", "http://127.0.0.1:\(proxyPort)",
                      "--connect-timeout", "3", "http://127.0.0.1:\(serverPort)/"])
        XCTAssertNotEqual(r.status, 0, "allowed host + non-443 port must be refused")
        XCTAssertNotEqual(r.out, "should-not-arrive")
    }
}
