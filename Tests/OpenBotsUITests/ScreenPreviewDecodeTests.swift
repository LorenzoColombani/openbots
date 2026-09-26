import AppKit
import XCTest
@testable import OpenBotsUI

/// The screen preview's picture is decoded off the main thread: a
/// full-resolution Retina PNG decoded on the main actor at every new
/// look could stall the window.
@MainActor
final class ScreenPreviewDecodeTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func settle(_ conversation: ConversationModel, until done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testAPictureIsDecodedAwayFromTheMainThreadAndShownAtItsPixelSize() async {
        let conversation = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        conversation.setTextReplyScreenPicture(png(width: 64, height: 32))
        XCTAssertNil(conversation.textReplyScreenPicture, "decoded later, not inside the setter")
        await settle(conversation) { conversation.textReplyScreenPicture != nil }
        XCTAssertEqual(conversation.textReplyScreenPicture?.size, NSSize(width: 64, height: 32))
    }

    func testBytesThatAreNotAPictureShowNothingAndNilClearsIt() async {
        let conversation = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        conversation.setTextReplyScreenPicture(png(width: 8, height: 8))
        await settle(conversation) { conversation.textReplyScreenPicture != nil }
        conversation.setTextReplyScreenPicture(Data("not a picture".utf8))
        await settle(conversation) { conversation.textReplyScreenPicture == nil }
        XCTAssertNil(conversation.textReplyScreenPicture)
        conversation.setTextReplyScreenPicture(png(width: 8, height: 8))
        await settle(conversation) { conversation.textReplyScreenPicture != nil }
        conversation.setTextReplyScreenPicture(nil)
        XCTAssertNil(conversation.textReplyScreenPicture, "the turn ended: gone at once")
    }

    func testAnOlderDecodeNeverReplacesANewerPicture() async {
        let conversation = ConversationModel(conversationID: UUID(), submit: { _, _, _ in })
        conversation.setTextReplyScreenPicture(png(width: 2400, height: 1600))
        conversation.setTextReplyScreenPicture(png(width: 10, height: 10))
        await settle(conversation) { conversation.textReplyScreenPicture?.size == NSSize(width: 10, height: 10) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(conversation.textReplyScreenPicture?.size, NSSize(width: 10, height: 10))
    }
}
