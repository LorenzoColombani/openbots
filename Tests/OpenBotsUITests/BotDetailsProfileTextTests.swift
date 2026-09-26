import OpenBotsDomain
import XCTest
@testable import OpenBotsUI

/// Details once said "No description yet" about a
/// bot whose "What this bot does" had just been typed in the New Bot sheet, because
/// it read only the instructions. Details now says what the settings say, under the
/// same two names.
final class BotDetailsProfileTextTests: XCTestCase {
    func testWhatTheBotDoesIsItsRole() throws {
        let profile = try TeammateProfile(displayName: "Polish One", role: "Practice bot for testing.")
        let sections = BotDetailsProfileText.sections(for: profile)
        XCTAssertEqual(sections, [.init(label: "What this bot does", text: "Practice bot for testing.")])
    }

    func testInstructionsFollowUnderTheirOwnName() throws {
        let profile = try TeammateProfile(displayName: "Ada", role: "Research and synthesis",
                                          detailedInstructions: "Working style:\nCareful and concise.")
        XCTAssertEqual(BotDetailsProfileText.sections(for: profile), [
            .init(label: "What this bot does", text: "Research and synthesis"),
            .init(label: "Instructions", text: "Working style:\nCareful and concise.")
        ])
    }

    func testBlankInstructionsAreLeftOut() throws {
        let profile = try TeammateProfile(displayName: "Ada", role: "Research", detailedInstructions: "  \n ")
        XCTAssertEqual(BotDetailsProfileText.sections(for: profile).map(\.label), ["What this bot does"])
    }
}
