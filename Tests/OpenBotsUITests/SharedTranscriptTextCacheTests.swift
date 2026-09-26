import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// What the shared measurement and parse stores are allowed to do.
///
/// They exist because the transcript is a `LazyVStack`: a row that scrolls out
/// of the viewport is destroyed, and coming back builds a new label with an
/// empty cache and a new markdown coordinator with an empty parse.
/// `TranscriptLabelMeasurementBenchmarkTests` measures what that costs. This
/// file guards the three ways a store shared between rows can be worse than no
/// store at all: answering for text it was not measured for, surviving a change
/// that should have dropped it, and growing without end.
@MainActor
final class SharedTranscriptTextCacheTests: XCTestCase {
    private static let reply = """
    ## Report on the transcript

    The column rests at a handful of widths and every row is measured at each of
    them, which is the floor for a transcript unless the sizes themselves change.

    - The first visit lays the text out.
    - The second visit must not.

    **Receipts over claims.** A cache that changes a height is a bug rather than a
    speed-up, so every height below is compared against a full text layout.
    """

    // MARK: - The height a rebuilt row is given

    /// The claim the whole cache rests on: a second label showing text a first
    /// label already measured is answered from memory, and answered with exactly
    /// the height a complete text layout would have produced.
    func testARebuiltRowIsAnsweredWithTheHeightALayoutWouldHaveProduced() {
        let widths: [CGFloat] = [320, 420, 500.5, 620, 763.25, 900]
        for text in [Self.reply, "Local demo message is sent.", String(repeating: "a", count: 400)] {
            for width in widths {
                // A label that has never been declared never reads from or writes
                // to the shared store, so this is a full text layout every time.
                let uncached = Self.undeclaredLabel(text)
                let layout = StableSelectableText.measuredSize(proposedWidth: width, field: uncached).height

                let first = Self.declaredLabel(text)
                let firstHeight = StableSelectableText.measuredSize(proposedWidth: width, field: first).height

                let counted = withLayoutDiagnostics(counters: true) { () -> (CGFloat, Int, Int) in
                    let before = LayoutStormCounters.lifetime
                    let rebuilt = Self.declaredLabel(text)
                    let height = StableSelectableText.measuredSize(proposedWidth: width, field: rebuilt).height
                    let after = LayoutStormCounters.lifetime
                    return (
                        height,
                        after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                        after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
                    )
                }

                XCTAssertEqual(firstHeight, layout, "the declared path measured a different height at \(width)")
                XCTAssertEqual(counted.0, layout, "a shared answer differed from a text layout at \(width)")
                XCTAssertEqual(counted.1, 1, "the rebuilt row did not answer from the shared store at \(width)")
                XCTAssertEqual(counted.2, 0, "the rebuilt row laid its text out again at \(width)")
            }
        }
    }

    /// A reply and a message can hold the same characters and wrap differently,
    /// because the reply's bold, monospaced and indented runs have their own
    /// metrics. Neither may ever be handed the other's height.
    func testAFormattedReplyAndAPlainMessageNeverAnswerForEachOther() {
        let source = "**Alpha** beta gamma"
        let markdown = Self.markdownLabel(source)
        let rendered = markdown.stringValue
        XCTAssertEqual(rendered, "Alpha beta gamma", "the parse no longer renders what this test assumes")

        _ = StableSelectableText.measuredSize(proposedWidth: 620, field: markdown)
        let plain = Self.declaredLabel(rendered)
        let events = withLayoutDiagnostics(counters: true) { () -> (Int, Int) in
            let before = LayoutStormCounters.lifetime
            _ = StableSelectableText.measuredSize(proposedWidth: 620, field: plain)
            let after = LayoutStormCounters.lifetime
            return (
                after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
            )
        }
        XCTAssertEqual(events.0, 0, "a plain message was handed a formatted reply's height")
        XCTAssertEqual(events.1, 1)

        // The same separation, stated directly on the keys.
        let plainDigest = TranscriptTextDigest.make(TranscriptTextDeclaration(
            kind: .plain, tone: 1, font: NSFont.preferredFont(forTextStyle: .body), content: rendered
        ))
        let markdownDigest = TranscriptTextDigest.make(TranscriptTextDeclaration(
            kind: .markdown, tone: 0, font: NSFont.preferredFont(forTextStyle: .body), content: rendered
        ))
        XCTAssertNotEqual(plainDigest, markdownDigest)
    }

    /// The two other things a height depends on, each moved on its own.
    func testTheDigestSeparatesToneFontAndContent() {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let base = TranscriptTextDeclaration(kind: .plain, tone: 1, font: font, content: "Alpha")
        let digests = Set([
            TranscriptTextDigest.make(base),
            TranscriptTextDigest.make(TranscriptTextDeclaration(kind: .plain, tone: 2, font: font, content: "Alpha")),
            TranscriptTextDigest.make(TranscriptTextDeclaration(
                kind: .plain, tone: 1, font: NSFont.preferredFont(forTextStyle: .caption1), content: "Alpha"
            )),
            TranscriptTextDigest.make(TranscriptTextDeclaration(kind: .plain, tone: 1, font: font, content: "Alphb")),
            TranscriptTextDigest.make(TranscriptTextDeclaration(kind: .markdown, tone: 1, font: font, content: "Alpha"))
        ])
        XCTAssertEqual(digests.count, 5, "two declarations that measure differently share a digest")

        // And the same declaration twice is the same key, or nothing is shared.
        XCTAssertEqual(TranscriptTextDigest.make(base), TranscriptTextDigest.make(base))
    }

    // MARK: - When a label must stop trusting what it was declared to be

    /// A past failure mode: a font written through the cell, which
    /// the label's own `font` property never sees. It is checked at the moment
    /// the declaration would be used, so the label stops reading from and
    /// writing to a store shared with every other row.
    func testAFontWrittenThroughTheCellDropsTheDeclaration() throws {
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        XCTAssertNotNil(label.contentDigest)

        label.cell?.font = NSFont.boldSystemFont(ofSize: 22)
        XCTAssertNil(label.contentDigest, "a cell-level font write left the declaration standing")

        // Re-declared by the next update pass, which is how it recovers.
        StableSelectableText(Self.reply).applyStablePresentation(to: label)
        XCTAssertNotNil(label.contentDigest)
    }

    /// The same for text written past the label's own setter.
    func testTextWrittenThroughTheCellDropsTheDeclaration() throws {
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        XCTAssertNotNil(label.contentDigest)

        label.cell?.stringValue = "Something else entirely."
        XCTAssertNil(label.contentDigest, "a cell-level text write left the declaration standing")
    }

    /// And an invalidation on its own does not, because AppKit raises one for
    /// reasons that change nothing — being put in a window is enough — and a
    /// label that dropped its declaration there took the slow path on the first
    /// measurement of every row that scrolled in.
    func testAnInvalidationAloneKeepsTheDeclaration() throws {
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        let digest = label.contentDigest
        XCTAssertNotNil(digest)
        label.invalidateIntrinsicContentSize()
        XCTAssertEqual(label.contentDigest, digest, "an invalidation that changed nothing dropped the declaration")
    }

    /// The one invalidation that is not taken at face value. Writing
    /// `preferredMaxLayoutWidth` to follow the frame changes no character and no
    /// metric, and treating it as a text change cost two thirds of the win.
    func testFollowingTheFrameWidthKeepsTheDeclaration() throws {
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        let digest = label.contentDigest
        XCTAssertNotNil(digest)
        label.setFrameSize(NSSize(width: 480, height: 400))
        XCTAssertEqual(label.contentDigest, digest, "following the frame width dropped the declaration")
    }

    /// A screen change must not drop the declaration — `viewDidChangeBackingProperties`
    /// fires when a view is inserted into a window, which is the moment a row
    /// scrolls in. The backing scale is a component of the shared key instead.
    func testAScreenChangeKeepsTheDeclarationAndSeparatesTheKeys() throws {
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        let digest = try XCTUnwrap(label.contentDigest)
        label.viewDidChangeBackingProperties()
        XCTAssertEqual(label.contentDigest, digest, "a backing-property change dropped the declaration")

        let retina = SharedTranscriptTextCaches.MeasurementKey(
            digest: digest, snappedWidth: 620, backingScale: 2, appearance: .aqua
        )
        let onex = SharedTranscriptTextCaches.MeasurementKey(
            digest: digest, snappedWidth: 620, backingScale: 1, appearance: .aqua
        )
        XCTAssertNotEqual(retina, onex)
        SharedTranscriptTextCaches.remember(101, for: retina)
        SharedTranscriptTextCaches.remember(202, for: onex)
        XCTAssertEqual(SharedTranscriptTextCaches.measuredHeight(for: retina), 101)
        XCTAssertEqual(SharedTranscriptTextCaches.measuredHeight(for: onex), 202)
    }

    /// One label's appearance change is not the whole store's business.
    ///
    /// `viewDidChangeEffectiveAppearance` fires for a vibrant or high-contrast
    /// container, for a second window with an appearance override, and for every
    /// label the moment it is put in a window. While one process-wide last-seen
    /// name decided whether both stores were emptied, two labels reporting two
    /// names turned every row that scrolled in into a full clear of a store that
    /// costs about 48 ms a row to refill.
    func testOneLabelsAppearanceChangeLeavesEveryOtherRowsHeightStanding() throws {
        SharedTranscriptTextCaches.removeAll()
        let read = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        let height = StableSelectableText.measuredSize(proposedWidth: 620, field: read).height
        XCTAssertEqual(SharedTranscriptTextCaches.storedMeasurementCount, 1, "the read row never reached the store")

        // A different label, reporting a different appearance, doing exactly what
        // AppKit makes it do. The name is chosen against whatever this Mac is set
        // to, so the label really is reporting a second one.
        let ambient = NSView().effectiveAppearance.name
        let contrasting: NSAppearance.Name = ambient == .darkAqua ? .aqua : .darkAqua
        let other = try XCTUnwrap(Self.declaredLabel("Another row entirely.") as? StableWrappingLabel)
        other.appearance = NSAppearance(named: contrasting)
        XCTAssertEqual(other.effectiveAppearance.name, contrasting, "the appearance assignment did not take")
        other.viewDidChangeEffectiveAppearance()

        let rebuilt = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        let events = withLayoutDiagnostics(counters: true) { () -> (CGFloat, Int, Int) in
            let before = LayoutStormCounters.lifetime
            let measured = StableSelectableText.measuredSize(proposedWidth: 620, field: rebuilt).height
            let after = LayoutStormCounters.lifetime
            return (
                measured,
                after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
            )
        }
        XCTAssertEqual(events.0, height)
        XCTAssertEqual(events.1, 1, "one label's appearance change emptied the store for every other row")
        XCTAssertEqual(events.2, 0, "the read row laid its text out again after another label changed appearance")
    }

    /// Two appearances on screen at once keep their own heights, because the
    /// appearance is part of the key the measure path builds rather than a reason
    /// to throw the store away.
    func testTwoAppearancesKeepTheirOwnHeightsInsteadOfEvictingEachOther() throws {
        SharedTranscriptTextCaches.removeAll()
        let light = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        light.appearance = NSAppearance(named: .aqua)
        let dark = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        dark.appearance = NSAppearance(named: .darkAqua)
        XCTAssertNotEqual(
            light.effectiveAppearance.name, dark.effectiveAppearance.name,
            "both labels report one appearance, so this test would measure the same key twice"
        )

        _ = StableSelectableText.measuredSize(proposedWidth: 620, field: light)
        _ = StableSelectableText.measuredSize(proposedWidth: 620, field: dark)
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, 2,
            "two appearances shared one entry, so one of them is being answered with the other's height"
        )

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let rebuilt = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
            rebuilt.appearance = NSAppearance(named: name)
            let events = withLayoutDiagnostics(counters: true) { () -> (Int, Int) in
                let before = LayoutStormCounters.lifetime
                _ = StableSelectableText.measuredSize(proposedWidth: 620, field: rebuilt)
                let after = LayoutStormCounters.lifetime
                return (
                    after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                    after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
                )
            }
            XCTAssertEqual(events.0, 1, "a \(name.rawValue) row did not answer from the shared store")
            XCTAssertEqual(events.1, 0, "a \(name.rawValue) row laid its text out again")
        }
    }

    // MARK: - What a reply still arriving is allowed to write

    /// A reply is delivered in chunks and re-rendered after each one, so a long
    /// answer passes through a couple of hundred intermediate states. Each has
    /// its own digest, so each used to insert a parse into a store holding 64 and
    /// a height into a store holding 512 — turning the parse store over several
    /// times and throwing out the answers belonging to every row above it. The
    /// row streaming pays its own parse and its own layout either way; the rows
    /// above must not pay for it.
    func testAReplyStillArrivingLeavesEveryOtherRowsAnswerInPlace() throws {
        SharedTranscriptTextCaches.removeAll()
        let readRows = (0..<20).map { "Row \($0) of a conversation already read.\n\n" + Self.reply }
        var heights: [CGFloat] = []
        for text in readRows {
            heights.append(StableSelectableText.measuredSize(
                proposedWidth: 620, field: Self.markdownLabel(text)
            ).height)
        }
        XCTAssertEqual(SharedTranscriptTextCaches.storedParseCount, readRows.count)
        XCTAssertEqual(SharedTranscriptTextCaches.storedMeasurementCount, readRows.count)

        // The reply arriving, four words at a time into one row that is on
        // screen the whole time: one label, one coordinator, many snapshots.
        let field = StableSelectableText.makeField("")
        let coordinator = SafeReplyMarkdownText.Coordinator()
        let words = Array(repeating: Self.reply, count: 4).joined(separator: "\n\n")
            .split(separator: " ", omittingEmptySubsequences: false)
        var snapshots = 0
        var streamed = ""
        for end in stride(from: 4, through: words.count, by: 4) {
            streamed = words.prefix(end).joined(separator: " ")
            SafeReplyMarkdownText(content: streamed).apply(to: field, coordinator: coordinator)
            _ = StableSelectableText.measuredSize(proposedWidth: 620, field: field)
            snapshots += 1
        }
        XCTAssertGreaterThan(
            snapshots, SharedTranscriptTextCaches.parseLimit,
            "the reply streamed in fewer snapshots than the parse store holds, so this test would prove nothing"
        )

        let label = try XCTUnwrap(field as? StableWrappingLabel)
        XCTAssertFalse(
            label.isContentDeclared,
            "a row whose text is still arriving declared itself into the stores every other row shares"
        )
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedParseCount, readRows.count + 1,
            "the snapshots of one arriving reply turned the parse store over"
        )
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, readRows.count + 1,
            "the snapshots of one arriving reply filled the measurement store"
        )

        // Every row already read still answers from memory: no parse, no layout.
        let events = withLayoutDiagnostics(counters: true) { () -> ([CGFloat], Int, Int, Int) in
            let before = LayoutStormCounters.lifetime
            let measured = readRows.map {
                StableSelectableText.measuredSize(proposedWidth: 620, field: Self.markdownLabel($0)).height
            }
            let after = LayoutStormCounters.lifetime
            func delta(_ name: String) -> Int { after[name, default: 0] - before[name, default: 0] }
            return (measured, delta("markdown.parseShared"), delta("markdown.parse"), delta("label.measureMiss"))
        }
        XCTAssertEqual(events.0, heights, "a row read before the reply arrived came back a different height")
        XCTAssertEqual(events.1, readRows.count, "a row read before the reply arrived parsed its markdown again")
        XCTAssertEqual(events.2, 0)
        XCTAssertEqual(events.3, 0, "a row read before the reply arrived laid its text out again")

        // And the finished reply is not exiled: the next row built to show it
        // declares it, so scrolling back to it is free like any other.
        let finished = Self.markdownLabel(streamed)
        let finishedHeight = StableSelectableText.measuredSize(proposedWidth: 620, field: finished).height
        XCTAssertEqual(try XCTUnwrap(finished as? StableWrappingLabel).isContentDeclared, true)
        let reread = withLayoutDiagnostics(counters: true) { () -> (CGFloat, Int, Int) in
            let before = LayoutStormCounters.lifetime
            let height = StableSelectableText.measuredSize(
                proposedWidth: 620, field: Self.markdownLabel(streamed)
            ).height
            let after = LayoutStormCounters.lifetime
            func delta(_ name: String) -> Int { after[name, default: 0] - before[name, default: 0] }
            return (height, delta("markdown.parseShared"), delta("label.measureMiss"))
        }
        XCTAssertEqual(reread.0, finishedHeight)
        XCTAssertEqual(reread.1, 1, "the finished reply never reached the parse store")
        XCTAssertEqual(reread.2, 0, "the finished reply laid its text out again")
    }

    // MARK: - What a window drag is allowed to write

    /// A drag across the transcript's width range measures every realized row at
    /// every width the edge passes through. Written into a 512-entry store shared
    /// with every other row and evicted oldest-first, those widths throw out the
    /// heights the rows already read were measured at — and nothing ever asks for
    /// a drag width again, so the store ends the drag holding only answers no row
    /// will ever want. Scrolling back up then pays a full text layout a row, which
    /// is the cost these stores exist to remove.
    func testAWindowDragKeepsItsWidthsOutOfTheStoreTheReadRowsShare() throws {
        SharedTranscriptTextCaches.removeAll()
        let restingWidth: CGFloat = 620
        let readRows = (0..<40).map { "Row \($0) of a conversation already read. " + Self.reply }
        var heights: [CGFloat] = []
        for text in readRows {
            heights.append(StableSelectableText.measuredSize(
                proposedWidth: restingWidth, field: Self.declaredLabel(text)
            ).height)
        }
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, readRows.count,
            "the rows already read never reached the store, so this test would prove nothing"
        )

        // The drag. Eight rows are on screen, and AppKit tells every view in the
        // window that the edge is moving before the first frame.
        let onScreen = try (0..<8).map { index in
            try XCTUnwrap(
                Self.declaredLabel("Visible row \(index) while the window edge moves.") as? StableWrappingLabel
            )
        }
        for label in onScreen { label.viewWillStartLiveResize() }
        for width in stride(from: CGFloat(400), through: 519, by: 1) {
            for label in onScreen { _ = StableSelectableText.measuredSize(proposedWidth: width, field: label) }
        }
        for label in onScreen { label.viewDidEndLiveResize() }

        // One entry a row, for the width the column came to rest at — not one
        // entry per width the edge passed through, which is what would evict
        // the heights the rows above were read at.
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, readRows.count + onScreen.count,
            "a drag wrote more than its resting width into the store shared with every other row"
        )

        // Every row already read still answers from memory, with the height it
        // was read at.
        let events = withLayoutDiagnostics(counters: true) { () -> ([CGFloat], Int, Int) in
            let before = LayoutStormCounters.lifetime
            let measured = readRows.map {
                StableSelectableText.measuredSize(proposedWidth: restingWidth, field: Self.declaredLabel($0)).height
            }
            let after = LayoutStormCounters.lifetime
            return (
                measured,
                after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
            )
        }
        XCTAssertEqual(events.0, heights, "a row read before the drag came back a different height")
        XCTAssertEqual(events.1, readRows.count, "a row read before the drag no longer answered from the store")
        XCTAssertEqual(events.2, 0, "a row read before the drag laid its text out again")
    }

    /// The rows that were on screen while the edge moved measured at the width
    /// the column came to rest at, like every row realized after the drag. Held
    /// only in each label's own map, that height dies with the row: scrolling
    /// back over those six to thirteen rows rebuilds each one with an empty
    /// cache and pays a full text layout apiece, which is the cost the shared
    /// store exists to remove.
    func testTheRowsOnScreenDuringADragShareTheHeightTheyRestedAt() throws {
        SharedTranscriptTextCaches.removeAll()
        let onScreenTexts = (0..<8).map { "Visible row \($0) while the window edge moves. " + Self.reply }
        let onScreen = try onScreenTexts.map { text in
            try XCTUnwrap(Self.declaredLabel(text) as? StableWrappingLabel)
        }
        for label in onScreen { label.viewWillStartLiveResize() }
        var restingHeights: [CGFloat] = []
        for width in stride(from: CGFloat(400), through: 519, by: 1) {
            for (index, label) in onScreen.enumerated() {
                let height = StableSelectableText.measuredSize(proposedWidth: width, field: label).height
                if width == 519 { restingHeights.append(height); _ = index }
            }
        }
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, 0,
            "the drag shared a width before the edge stopped"
        )
        for label in onScreen { label.viewDidEndLiveResize() }

        // Each of those rows is rebuilt when it scrolls back. It answers from
        // the store, with the height it was resting at, and lays out nothing.
        let events = withLayoutDiagnostics(counters: true) { () -> ([CGFloat], Int, Int) in
            let before = LayoutStormCounters.lifetime
            let measured = onScreenTexts.map {
                StableSelectableText.measuredSize(proposedWidth: 519, field: Self.declaredLabel($0)).height
            }
            let after = LayoutStormCounters.lifetime
            return (
                measured,
                after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
            )
        }
        XCTAssertEqual(events.0, restingHeights, "a row rebuilt after the drag came back a different height")
        XCTAssertEqual(events.1, onScreen.count, "a row on screen during the drag never shared its resting height")
        XCTAssertEqual(events.2, 0, "a row on screen during the drag laid its text out again after it")
    }

    /// A reply still arriving while the window edge moves changes the text under
    /// the label. The height held for the resting width belongs to text this
    /// label is no longer showing, so the edge stopping must share nothing.
    func testTextThatChangesDuringADragSharesNothingWhenItEnds() throws {
        SharedTranscriptTextCaches.removeAll()
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        label.viewWillStartLiveResize()
        _ = StableSelectableText.measuredSize(proposedWidth: 519, field: label)
        XCTAssertEqual(SharedTranscriptTextCaches.storedMeasurementCount, 0)
        StableSelectableText(Self.reply + "\n\nOne more paragraph arrived.").applyStablePresentation(to: label)
        label.viewDidEndLiveResize()
        XCTAssertEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, 0,
            "a height measured before the text changed was shared with every other row"
        )
    }

    /// The same drag still gets its own answers: the store is read whatever the
    /// window edge is doing, and the label keeps every width it measured.
    func testALabelStillAnswersFromMemoryWhileTheEdgeIsMoving() throws {
        SharedTranscriptTextCaches.removeAll()
        let label = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        let settled = StableSelectableText.measuredSize(proposedWidth: 620, field: label).height

        let dragged = try XCTUnwrap(Self.declaredLabel(Self.reply) as? StableWrappingLabel)
        dragged.viewWillStartLiveResize()
        let events = withLayoutDiagnostics(counters: true) { () -> (CGFloat, Int, Int) in
            let before = LayoutStormCounters.lifetime
            let height = StableSelectableText.measuredSize(proposedWidth: 620, field: dragged).height
            let after = LayoutStormCounters.lifetime
            return (
                height,
                after["label.measureShared", default: 0] - before["label.measureShared", default: 0],
                after["label.measureMiss", default: 0] - before["label.measureMiss", default: 0]
            )
        }
        dragged.viewDidEndLiveResize()
        XCTAssertEqual(events.0, settled)
        XCTAssertEqual(events.1, 1, "a row drawn during a drag was refused an answer it already had")
        XCTAssertEqual(events.2, 0, "a row drawn during a drag laid out text that was already measured")
    }

    // MARK: - Bounded

    func testBothStoresStayBoundedAndKeepTheNewestEntries() {
        SharedTranscriptTextCaches.removeAll()
        let font = NSFont.preferredFont(forTextStyle: .body)
        let overflow = SharedTranscriptTextCaches.measurementLimit + 20
        var keys: [SharedTranscriptTextCaches.MeasurementKey] = []
        for index in 0..<overflow {
            let key = Self.measurementKey("row \(index)")
            keys.append(key)
            SharedTranscriptTextCaches.remember(CGFloat(index), for: key)
        }
        XCTAssertLessThanOrEqual(
            SharedTranscriptTextCaches.storedMeasurementCount, SharedTranscriptTextCaches.measurementLimit
        )
        XCTAssertEqual(SharedTranscriptTextCaches.measuredHeight(for: keys[overflow - 1]), CGFloat(overflow - 1))
        XCTAssertNil(SharedTranscriptTextCaches.measuredHeight(for: keys[0]), "the oldest entry was never evicted")

        for index in 0..<(SharedTranscriptTextCaches.parseLimit + 10) {
            let digest = TranscriptTextDigest.make(TranscriptTextDeclaration(
                kind: .markdown, tone: 0, font: font, content: "reply \(index)"
            ))
            SharedTranscriptTextCaches.rememberParsedMarkdown(NSAttributedString(string: "\(index)"), for: digest)
        }
        XCTAssertLessThanOrEqual(SharedTranscriptTextCaches.storedParseCount, SharedTranscriptTextCaches.parseLimit)
        SharedTranscriptTextCaches.removeAll()
        XCTAssertEqual(SharedTranscriptTextCaches.storedMeasurementCount, 0)
        XCTAssertEqual(SharedTranscriptTextCaches.storedParseCount, 0)
    }

    /// The diagnostics set beside the stores is bounded too. It is written on
    /// every miss while `OPENBOTS_LAYOUT_DIAGNOSTICS=1`, which is the documented
    /// way to chase a live layout storm in a shipped build, and an unbounded set
    /// outgrows the 512-entry store it exists to annotate for the life of the
    /// process.
    func testTheDiagnosticsKeySetStaysBounded() {
        SharedTranscriptTextCaches.removeAll()
        withLayoutDiagnostics(counters: true) {
            for index in 0..<(SharedTranscriptTextCaches.recordedKeyLimit + 40) {
                SharedTranscriptTextCaches.remember(CGFloat(index), for: Self.measurementKey("recorded \(index)"))
            }
        }
        XCTAssertGreaterThan(SharedTranscriptTextCaches.recordedKeyCount, 0, "the counters were never on")
        XCTAssertLessThanOrEqual(
            SharedTranscriptTextCaches.recordedKeyCount, SharedTranscriptTextCaches.recordedKeyLimit,
            "the diagnostics set grew past its bound"
        )
        SharedTranscriptTextCaches.removeAll()
        XCTAssertEqual(SharedTranscriptTextCaches.recordedKeyCount, 0)
    }

    // MARK: - Inside a real window

    /// The seam this design could have failed on quietly. SwiftUI declares a
    /// label's content during its update pass; AppKit then inserts the view into
    /// a window, which fires `viewDidChangeBackingProperties` and
    /// `viewDidChangeEffectiveAppearance` before anything is measured. If either
    /// of those dropped the declaration, every row scrolling in would take the
    /// slow path and the benchmark beside this file — which owns no window —
    /// would still report a win. So this hosts the row for real.
    func testARowHostedInAWindowStillAnswersFromTheSharedStore() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }

        for row in [AnyView(StableSelectableText(Self.reply)), AnyView(SafeReplyMarkdownText(content: Self.reply))] {
            SharedTranscriptTextCaches.removeAll()
            let first = try Self.hostRow(row, in: window)
            XCTAssertGreaterThan(first.height, 0, "the hosted row measured nothing")

            // The LazyVStack's rebuild: the whole hosting view is thrown away
            // and a new one is made for the same message.
            let events = try withLayoutDiagnostics(counters: true) { () -> (CGSize, Int, Int, Int) in
                let before = LayoutStormCounters.lifetime
                let rebuilt = try Self.hostRow(row, in: window)
                let after = LayoutStormCounters.lifetime
                func delta(_ name: String) -> Int { after[name, default: 0] - before[name, default: 0] }
                return (rebuilt, delta("label.measureShared"), delta("label.measureMiss"), delta("markdown.parse"))
            }
            XCTAssertEqual(events.0, first, "a rebuilt hosted row measured a different size")
            XCTAssertGreaterThan(events.1, 0, "a rebuilt hosted row never reached the shared store")
            XCTAssertEqual(events.2, 0, "a rebuilt hosted row laid its text out again")
            XCTAssertEqual(events.3, 0, "a rebuilt hosted row parsed its markdown again")
        }
    }

    // MARK: - Helpers

    /// One row, hosted in the window and laid out, then taken back out. Returns
    /// the size the row settled at.
    private static func hostRow(_ row: AnyView, in window: NSWindow) throws -> CGSize {
        let host = NSHostingView(rootView: row.frame(width: 620, alignment: .leading))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        let label = try XCTUnwrap(
            descendants(of: host).compactMap { $0 as? NSTextField }.first,
            "the hosted row never realized a label"
        )
        let size = label.frame.size
        window.contentView = nil
        return size
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// The label as `StableSelectableText` builds it, declaration included.
    private static func declaredLabel(_ text: String) -> NSTextField {
        let field = StableSelectableText.makeField(text)
        StableSelectableText(text).applyStablePresentation(to: field)
        return field
    }

    /// The same label, never declared: the path a bare `NSTextField` and a label
    /// whose invalidation could not be explained both take. A full text layout.
    private static func undeclaredLabel(_ text: String) -> NSTextField {
        let field = StableSelectableText.makeField(text)
        field.font = NSFont.preferredFont(forTextStyle: .body)
        field.textColor = .labelColor
        return field
    }

    /// A key for text nothing ever measures, for the bounds above.
    private static func measurementKey(_ text: String) -> SharedTranscriptTextCaches.MeasurementKey {
        SharedTranscriptTextCaches.MeasurementKey(
            digest: TranscriptTextDigest.make(TranscriptTextDeclaration(
                kind: .plain, tone: 1, font: NSFont.preferredFont(forTextStyle: .body), content: text
            )),
            snappedWidth: 620,
            backingScale: 2,
            appearance: .aqua
        )
    }

    private static func markdownLabel(_ source: String) -> NSTextField {
        let field = StableSelectableText.makeField("")
        SafeReplyMarkdownText(content: source)
            .apply(to: field, coordinator: SafeReplyMarkdownText.Coordinator())
        return field
    }
}
