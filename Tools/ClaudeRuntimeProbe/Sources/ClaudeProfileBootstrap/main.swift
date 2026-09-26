import ClaudeRuntimeProbeCore
import Darwin
import Foundation

private enum Command {
    case plan
    case prepare
}

private func parseCommand() throws -> Command {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["plan"]:
        return .plan
    case ["prepare", "--execute"]:
        return .prepare
    case ["prepare"]:
        throw ProbeFailure.invalidArguments("prepare is inert unless the exact --execute flag is present")
    default:
        throw ProbeFailure.invalidArguments("expected plan or prepare --execute")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

do {
    let command = try parseCommand()
    let bootstrap = try PreviewProfileBootstrap()
    switch command {
    case .plan:
        try printJSON(bootstrap.plan)
    case .prepare:
        try printJSON(bootstrap.prepare())
    }
} catch {
    FileHandle.standardError.write(Data("claude-profile-bootstrap: \(error)\n".utf8))
    exit(1)
}
