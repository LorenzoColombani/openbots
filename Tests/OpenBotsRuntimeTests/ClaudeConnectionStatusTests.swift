import Foundation
import Testing
@testable import OpenBotsRuntime

@Test("Only successful first-party Pro or Max status becomes eligible", arguments: ["pro", "max", "MAX"])
func claudeConnectionEligibleStatus(tier: String) {
    let json = """
    {"loggedIn":true,"authMethod":"Claude.AI","apiProvider":"FirstParty","subscriptionType":"\(tier)",
     "email":"discarded@example.invalid","unknown":{"small":[1,2]}}
    """
    #expect(ClaudeConnectionStatusParser.classify(stdout: Data(json.utf8), exitCode: 0)
            == .eligible(tier.lowercased() == "pro" ? .pro : .max))
    #expect(ClaudeConnectionStatusParser.classify(stdout: Data(json.utf8), exitCode: 1) == .inconclusive)
}

@Test("Explicit logged-out schema is distinct from a failed status command", arguments: [Int32(0), Int32(1)])
func claudeConnectionExplicitSignedOut(exitCode: Int32) {
    for json in [
        "{\"loggedIn\":false,\"authMethod\":\"none\"}",
        "{\"loggedIn\":false,\"authMethod\":\"none\",\"apiProvider\":\"firstParty\",\"subscriptionType\":null}"
    ] {
        #expect(ClaudeConnectionStatusParser.classify(stdout: Data(json.utf8), exitCode: exitCode) == .signedOut)
        #expect(ClaudeConnectionStatusParser.classify(stdout: Data(json.utf8), exitCode: 2) == .inconclusive)
    }
}

@Test("Malformed, alternate-provider, ambiguous and contradictory status stays inconclusive")
func claudeConnectionRejectsInvalidStatus() {
    let invalid = [
        "", "null", "[]", "{}", "not JSON", "{\"error\":\"expired\"}",
        "{\"loggedIn\":false}",
        "{\"loggedIn\":false,\"authMethod\":\"unknown\"}",
        "{\"loggedIn\":false,\"authMethod\":\"none\",\"subscriptionType\":\"max\"}",
        "{\"loggedIn\":false,\"authMethod\":\"none\",\"apiProvider\":\"bedrock\"}",
        "{\"loggedIn\":0,\"authMethod\":\"none\"}",
        "{\"loggedIn\":\"true\",\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"pro\"}",
        "{\"loggedIn\":true,\"authMethod\":\"apiKey\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"pro\"}",
        "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"vertex\",\"subscriptionType\":\"pro\"}",
        "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"free\"}",
        "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\"}",
        "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":[]}"
    ]
    for json in invalid {
        #expect(ClaudeConnectionStatusParser.classify(stdout: Data(json.utf8), exitCode: 0) == .inconclusive)
    }
}

@Test("Status schema has bounded size, nesting, fields and unambiguous keys")
func claudeConnectionStatusSchemaBounds() {
    let base = "\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"subscriptionType\":\"max\""
    let invalid = [
        "{" + base + ",\"loggedIn\":false}",
        "{" + base + ",\"\\u006coggedIn\":false}",
        "{" + base + ",\"unknown\":" + String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9) + "}",
        "{" + base + "," + (0..<33).map { "\"key\($0)\":null" }.joined(separator: ",") + "}",
        "{" + base + ",\"unknown\":[" + Array(repeating: "0", count: 66).joined(separator: ",") + "]}",
        "{" + base + ",\"padding\":\"" + String(repeating: "x", count: 16_384) + "\"}",
        "{" + base + "} {}"
    ]
    for json in invalid {
        #expect(ClaudeConnectionStatusParser.classify(stdout: Data(json.utf8), exitCode: 0) == .inconclusive)
    }
    let minimal = Data(("{" + base + "}").utf8)
    var atLimit = minimal
    atLimit.append(Data(repeating: 32, count: ClaudeConnectionStatusParser.maximumOutputBytes - minimal.count))
    #expect(ClaudeConnectionStatusParser.classify(stdout: atLimit, exitCode: 0) == .eligible(.max))
    atLimit.append(32)
    #expect(ClaudeConnectionStatusParser.classify(stdout: atLimit, exitCode: 0) == .inconclusive)
}
