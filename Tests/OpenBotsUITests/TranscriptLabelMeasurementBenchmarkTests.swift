import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// What a transcript row costs, measured rather than asserted.
///
/// The transcript felt slow in use. Idle CPU is zero,
/// so the cost sits in interaction: scrolling, typing, streaming. Every one of
/// those re-measures the native labels, and a long reply pays for a complete
/// text layout each time. This file is the receipt for that claim and for any
/// fix to it: it prints wall time for each layout pass, the label event counts,
/// and a geometry fingerprint, so two builds can be compared line by line.
///
/// The assertions stay deliberately loose, because the printed numbers are the
/// point. What is asserted is only what must never stop being true: measuring
/// the same text at the same width twice returns the same size, and the second
/// time must not cost a second full text layout.
@MainActor
final class TranscriptLabelMeasurementBenchmarkTests: XCTestCase {
    private static let benchmarkWidth: CGFloat = 620

    // MARK: - Cause A: the cost of measuring text that has not changed

    func testRepeatedMeasurementOfUnchangedTextIsNotAFullTextLayout() throws {
        let reply = BenchmarkTranscriptText.reply(seed: 7, characters: 6_000)
        let width = Self.benchmarkWidth
        let iterations = 60

        // Cold: labels that have never been measured. Built outside the timed
        // block so the number is text layout, not NSTextField allocation.
        let coldLabels = (0..<iterations).map { _ in Self.benchmarkLabel(reply) }
        let cold = Self.milliseconds {
            for label in coldLabels {
                _ = StableSelectableText.measuredSize(proposedWidth: width, field: label)
            }
        }

        // Warm: one label, one width, asked again and again. This is what a
        // SwiftUI update pass, an AppKit constraint pass and a scrolled frame
        // all do to the same row.
        let warmLabel = Self.benchmarkLabel(reply)
        let firstMeasurement = StableSelectableText.measuredSize(proposedWidth: width, field: warmLabel)
        let warm = Self.milliseconds {
            for _ in 0..<iterations {
                _ = StableSelectableText.measuredSize(proposedWidth: width, field: warmLabel)
            }
        }
        let repeated = StableSelectableText.measuredSize(proposedWidth: width, field: warmLabel)

        let coldPerCall = cold / Double(iterations)
        let warmPerCall = warm / Double(iterations)
        print(String(
            format: "[bench] measure 6000-char reply at %.0f pt: cold %.3f ms/call, warm %.3f ms/call, ratio %.4f (%d calls each)",
            width, coldPerCall, warmPerCall, coldPerCall > 0 ? warmPerCall / coldPerCall : 0, iterations
        ))

        // The size must not move. A cache that changes a height is a bug, not a
        // speed-up: an earlier relayout loop was a half-point disagreement.
        XCTAssertEqual(repeated, firstMeasurement, "repeated measurement changed the size")
        XCTAssertGreaterThan(firstMeasurement.height, 0)
        XCTAssertEqual(firstMeasurement.width, width)
        // The receipt that the cost is gone and stays gone. A cache hit is a
        // dictionary lookup; a miss is a full text layout of six kilobytes.
        XCTAssertLessThan(
            warmPerCall, coldPerCall * 0.2,
            "measuring unchanged text at an unchanged width still costs a full text layout: cold \(coldPerCall) ms, warm \(warmPerCall) ms"
        )
    }

    /// Where the time in one row actually goes. `intrinsicContentSize` runs both
    /// AppKit's own layout and ours, so it is the expensive half of every
    /// AppKit-driven pass; this prints the split so a fix is aimed at the right one.
    func testIntrinsicSizeCostSplitBetweenAppKitAndMeasuredSize() throws {
        let reply = BenchmarkTranscriptText.reply(seed: 11, characters: 6_000)
        let width = Self.benchmarkWidth
        let iterations = 40
        let label = try XCTUnwrap(Self.benchmarkLabel(reply) as? StableWrappingLabel)
        label.setFrameSize(NSSize(width: width, height: 400))
        _ = label.intrinsicContentSize

        let appKit = Self.milliseconds { for _ in 0..<iterations { _ = label.appKitIntrinsicContentSize } }
        let measured = Self.milliseconds {
            for _ in 0..<iterations { _ = StableSelectableText.measuredSize(proposedWidth: width, field: label) }
        }
        let intrinsic = Self.milliseconds { for _ in 0..<iterations { _ = label.intrinsicContentSize } }
        print(String(
            format: "[bench] per call on a 6000-char label: appKitIntrinsic %.3f ms, measuredSize %.3f ms, intrinsicContentSize %.3f ms",
            appKit / Double(iterations), measured / Double(iterations), intrinsic / Double(iterations)
        ))
        XCTAssertGreaterThan(label.intrinsicContentSize.height, 0)
    }

    // MARK: - The geometry fingerprint

    /// Every measured height this code must keep identical. Printed, not
    /// asserted against constants, because the fonts are the reader's own: the
    /// proof is that two builds print the same line.
    func testGeometryFingerprintIsStableAcrossWidths() {
        var fingerprint: [String] = []
        for (name, text) in BenchmarkTranscriptText.fingerprintSamples {
            let label = Self.benchmarkLabel(text)
            let heights = BenchmarkTranscriptText.fingerprintWidths.map { width -> String in
                let size = StableSelectableText.measuredSize(proposedWidth: width, field: label)
                XCTAssertEqual(size.width, width)
                XCTAssertGreaterThan(size.height, 0)
                return String(format: "%.0f:%.1f", width, size.height)
            }
            fingerprint.append("\(name)[\(heights.joined(separator: " "))]")
        }
        print("[bench] geometry fingerprint: \(fingerprint.joined(separator: " "))")

        // Narrower wraps taller, and asking twice never changes the answer.
        let label = Self.benchmarkLabel(BenchmarkTranscriptText.reply(seed: 3, characters: 3_000))
        let narrow = StableSelectableText.measuredSize(proposedWidth: 320, field: label)
        let wide = StableSelectableText.measuredSize(proposedWidth: 780, field: label)
        XCTAssertGreaterThan(narrow.height, wide.height)
        for _ in 0..<8 {
            XCTAssertEqual(StableSelectableText.measuredSize(proposedWidth: 320, field: label), narrow)
            XCTAssertEqual(StableSelectableText.measuredSize(proposedWidth: 780, field: label), wide)
        }
    }

    // MARK: - The realistic transcript

    /// Forty rows of the shape a user actually reads: short messages they typed
    /// and long formatted replies. Hosted, laid out at one width, scrolled,
    /// re-laid out at a second width and back, and re-rendered in place.
    ///
    /// Timed with the diagnostics off, because that is what the app ships, and
    /// then run again with the counters on purely to harvest the event counts.
    /// Timing a counted run would hide what the counters themselves cost.
    func testHostedTranscriptLayoutPassCost() throws {
        try withLayoutDiagnostics(counters: false) { try runHostedTranscriptPasses(counted: false) }
        try withLayoutDiagnostics(counters: true) { try runHostedTranscriptPasses(counted: true) }
    }

    private func runHostedTranscriptPasses(counted: Bool) throws {
        // The counted run reads its own transcript. The timed run keeps the
        // original one, so its wall time stays comparable with what was measured
        // before this file existed; but heights are now remembered across rows,
        // so a counted second pass over the same forty replies would report the
        // work of a first visit as zero and mean nothing.
        // `lifetime` is cumulative for the process, so the report below is a
        // difference between two snapshots. Printing the totals made the line
        // depend on which other suites had already run with the counters on.
        let baseline = LayoutStormCounters.lifetime
        let fixture = BenchmarkTranscriptFixture(salt: counted ? 303 : 0)
        let controller = NSHostingController(rootView: BenchmarkTranscriptHarness(fixture: fixture))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 720)

        let coldRender = Self.milliseconds { Self.settle(host) }
        let quiet = Self.milliseconds { Self.settle(host) }

        let labels = host.benchmarkDescendants.compactMap { $0 as? NSTextField }
        XCTAssertGreaterThan(labels.count, 8, "the hosted transcript did not realize its rows")

        let scroll = labels.compactMap(\.enclosingScrollView).first
        let scrolled = Self.milliseconds {
            guard let scroll, let document = scroll.documentView else { return }
            let span = max(0, document.bounds.height - scroll.contentView.bounds.height)
            for step in 0...20 {
                let offset = span * CGFloat(step) / 20
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? offset : span - offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                Self.settle(host, cycles: 2)
            }
        }

        let narrowed = Self.milliseconds {
            host.frame.size.width = 640
            Self.settle(host)
        }
        let widened = Self.milliseconds {
            host.frame.size.width = 900
            Self.settle(host)
        }
        let rerendered = Self.milliseconds {
            fixture.revision += 1
            Self.settle(host)
        }

        print(String(
            format: "[bench] hosted 40-row transcript (%@): cold %.1f ms, quiet %.1f ms, scroll(21 steps) %.1f ms, width 900->640 %.1f ms, 640->900 %.1f ms, re-render %.1f ms",
            counted ? "counters on" : "shipped path, counters off",
            coldRender, quiet, scrolled, narrowed, widened, rerendered
        ))
        if counted { print("[bench] label events: \(Self.eventReport(since: baseline))") }

        for label in host.benchmarkDescendants.compactMap({ $0 as? NSTextField }) {
            XCTAssertTrue(label.frame.height.isFinite, "non-finite row height")
            XCTAssertLessThan(label.frame.height, 8_000, "runaway row height \(label.frame)")
        }
    }

    // MARK: - Cause C: scrolling, where the row itself is destroyed and rebuilt

    /// The transcript is a `LazyVStack`. A row that leaves the viewport has its
    /// hosting views destroyed, so scrolling back to a message already read
    /// builds a brand-new native label with an empty measurement cache and a
    /// brand-new markdown coordinator with an empty parse. `testHostedTranscript`
    /// above cannot see that: it lays every row out before it scrolls, so its
    /// scroll pass only moves a clip view.
    ///
    /// This walks a six-row viewport down forty rows and back up at one fixed
    /// width, destroying what leaves and building fresh what enters. Its wall
    /// time is a lower bound on the app's scroll cost, not the app's number: it
    /// is the text work alone, with no SwiftUI diffing and no AppKit constraint
    /// pass around it. What it does measure exactly is how much of that text work
    /// a second visit to the same message repeats.
    func testScrollingBackOverReadRowsDoesNotLayThemOutAgain() throws {
        let timed = withLayoutDiagnostics(counters: false) { Self.scrollJourney(salt: 101) }
        print(String(
            format: "[bench] scroll 40 rows, 6 visible, %.0f pt, shipped path: down %.1f ms (%d rows rebuilt), up %.1f ms (%d rows rebuilt)",
            Self.benchmarkWidth, timed.downMilliseconds, timed.downRowsBuilt,
            timed.upMilliseconds, timed.upRowsBuilt
        ))

        // A second transcript, in a generator range nothing else visits, so the
        // counted journey starts with nothing remembered about any of its rows
        // no matter what ran before it in this process.
        let counted = withLayoutDiagnostics(counters: true) { Self.scrollJourney(salt: 202) }
        print("[bench] scroll work: down textLayouts=\(counted.downLayouts) markdownParses=\(counted.downParses)"
            + " | up textLayouts=\(counted.upLayouts) markdownParses=\(counted.upParses)"
            + " (rows rebuilt: down \(counted.downRowsBuilt), up \(counted.upRowsBuilt))")

        // The harness has to be honest before its numbers mean anything: the
        // return journey must really have destroyed and rebuilt those rows.
        XCTAssertEqual(counted.upRowsBuilt, Self.expectedRebuilds, "the return journey did not rebuild its rows")
        XCTAssertEqual(counted.downRowsBuilt, Self.expectedRebuilds)
        // Going down, every row is new: one text layout each, one parse per reply.
        XCTAssertEqual(counted.downLayouts, Self.expectedRebuilds, "a first visit should lay each row out exactly once")
        XCTAssertEqual(counted.downParses, Self.expectedRebuilds / 2, "a first visit should parse each reply exactly once")
        // Coming back up, none of it is new. This is the regression guard.
        XCTAssertEqual(counted.upLayouts, 0, "scrolling back over messages already read laid their text out again")
        XCTAssertEqual(counted.upParses, 0, "scrolling back over replies already read parsed their markdown again")
        // And a shared answer has to be the same answer.
        XCTAssertEqual(timed.heightsDisagreed, [], "a rebuilt row measured a different height")
        XCTAssertEqual(counted.heightsDisagreed, [], "a rebuilt row measured a different height")
    }

    /// Rows the journey destroys and builds again in each direction: the forty
    /// rows minus the six already on screen when it starts.
    private static let expectedRebuilds = 34

    private struct ScrollJourney {
        var downMilliseconds = 0.0
        var upMilliseconds = 0.0
        var downRowsBuilt = 0
        var upRowsBuilt = 0
        var downLayouts = 0
        var upLayouts = 0
        var downParses = 0
        var upParses = 0
        var heightsDisagreed: [String] = []
    }

    private static func scrollJourney(
        salt: Int,
        rowCount: Int = 40,
        visible: Int = 6,
        width: CGFloat = benchmarkWidth
    ) -> ScrollJourney {
        let rows = BenchmarkTranscriptText.transcript(rowCount: rowCount, salt: salt)
        var live: [Int: NSTextField] = [:]
        var heights: [Int: CGFloat] = [:]
        var disagreements: [String] = []
        var built = 0

        func show(_ visibleRows: Range<Int>) {
            for index in live.keys where !visibleRows.contains(index) {
                // The LazyVStack's destruction: the label and its coordinator go.
                live.removeValue(forKey: index)
            }
            for index in visibleRows where live[index] == nil {
                let field = buildRow(rows[index])
                let height = StableSelectableText.measuredSize(proposedWidth: width, field: field).height
                if let previous = heights[index], previous != height {
                    disagreements.append("row \(index): \(previous) -> \(height)")
                }
                heights[index] = height
                live[index] = field
                built += 1
            }
        }

        var journey = ScrollJourney()
        let last = rowCount - visible
        show(0..<visible)

        // `lifetime` is cumulative for the whole process, so every number below
        // is a difference between two snapshots, never a total.
        let start = LayoutStormCounters.lifetime
        built = 0
        journey.downMilliseconds = milliseconds { for top in 1...last { show(top..<(top + visible)) } }
        journey.downRowsBuilt = built
        let turn = LayoutStormCounters.lifetime
        journey.downLayouts = delta(turn, start, "label.measureMiss")
        journey.downParses = delta(turn, start, "markdown.parse")

        built = 0
        journey.upMilliseconds = milliseconds {
            for top in stride(from: last - 1, through: 0, by: -1) { show(top..<(top + visible)) }
        }
        journey.upRowsBuilt = built
        let end = LayoutStormCounters.lifetime
        journey.upLayouts = delta(end, turn, "label.measureMiss")
        journey.upParses = delta(end, turn, "markdown.parse")
        journey.heightsDisagreed = disagreements
        return journey
    }

    private static func delta(_ after: [String: Int], _ before: [String: Int], _ name: String) -> Int {
        after[name, default: 0] - before[name, default: 0]
    }

    /// One transcript row exactly as SwiftUI builds it when a destroyed row
    /// scrolls back into view: a fresh native label, and for a reply a fresh
    /// coordinator whose parse has never run.
    private static func buildRow(_ row: BenchmarkTranscriptFixture.Row) -> NSTextField {
        guard row.isReply else {
            let field = StableSelectableText.makeField(row.text)
            StableSelectableText(row.text).applyStablePresentation(to: field)
            return field
        }
        let field = StableSelectableText.makeField("")
        SafeReplyMarkdownText(content: row.text)
            .apply(to: field, coordinator: SafeReplyMarkdownText.Coordinator())
        return field
    }

    // MARK: - Helpers

    /// The transcript's label, configured the way the app configures it.
    private static func benchmarkLabel(_ text: String) -> NSTextField {
        let label = StableSelectableText.makeField(text)
        label.font = NSFont.preferredFont(forTextStyle: .body)
        label.textColor = .labelColor
        return label
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        body()
        return (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    /// Drive SwiftUI and AppKit to a settled layout. Every pass uses the same
    /// shape, so the run-loop floor is the same in each and the `quiet` pass
    /// above prints what that floor is.
    private static func settle(_ view: NSView, cycles: Int = 6) {
        for _ in 0..<cycles {
            view.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        _ = view.fittingSize
    }

    private static func eventReport(since baseline: [String: Int]) -> String {
        let interesting = [
            "label.sizeThatFits", "label.update", "label.layout", "label.setFrameOrigin",
            "label.setFrameSize", "label.invalidateIntrinsic", "markdown.update",
            "label.measureHit", "label.measureShared", "label.measureMiss",
            "markdown.parse", "markdown.parseShared"
        ]
        let lifetime = LayoutStormCounters.lifetime
        return interesting
            .map { "\($0)=\(lifetime[$0, default: 0] - baseline[$0, default: 0])" }
            .joined(separator: " ")
    }
}

// MARK: - Fixture

@MainActor
private final class BenchmarkTranscriptFixture: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let text: String
        let isReply: Bool
    }

    let rows: [Row]
    @Published var revision = 0

    init(salt: Int = 0) {
        rows = BenchmarkTranscriptText.transcript(rowCount: 40, salt: salt)
    }
}

/// The transcript's real shape: a message the reader typed, then a formatted
/// reply, in a scrolling column. Not lazy, so all forty rows are measured and
/// the number means the same thing on both sides of a change.
private struct BenchmarkTranscriptHarness: View {
    @ObservedObject var fixture: BenchmarkTranscriptFixture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Streaming revision \(fixture.revision)").font(.caption)
                ForEach(fixture.rows) { row in
                    if row.isReply {
                        SafeReplyMarkdownText(content: row.text)
                    } else {
                        StableSelectableText(row.text)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Deterministic transcript text. Two runs of two builds must measure the same
/// characters, so nothing here is random and nothing is read from disk.
private enum BenchmarkTranscriptText {
    static let fingerprintWidths: [CGFloat] = [320, 420, 500.5, 620, 763.25, 900]

    static var fingerprintSamples: [(String, String)] {
        [
            ("short", "Local demo message is sent."),
            ("medium", reply(seed: 1, characters: 2_000)),
            ("long", reply(seed: 2, characters: 6_000)),
            ("token", "Report line " + String(repeating: "a", count: 200) + " continues after the unbreakable token.")
        ]
    }

    /// `salt` moves the whole transcript into a generator range no other run in
    /// this class visits, so a scenario that must start with nothing remembered
    /// needs no cache to be reset and no test-ordering assumption to hold.
    static func transcript(rowCount: Int, salt: Int = 0) -> [BenchmarkTranscriptFixture.Row] {
        let lengths = [2_000, 3_500, 5_000, 6_000]
        return (0..<rowCount).map { index in
            let seed = index &+ salt &* 10_000
            if index.isMultiple(of: 2) {
                return BenchmarkTranscriptFixture.Row(id: index, text: userMessage(seed: seed), isReply: false)
            }
            let characters = lengths[(index / 2) % lengths.count]
            return BenchmarkTranscriptFixture.Row(
                id: index, text: reply(seed: seed, characters: characters), isReply: true
            )
        }
    }

    static func userMessage(seed: Int) -> String {
        var generator = Generator(seed: seed)
        return sentence(&generator, words: 6 + generator.next(14))
    }

    /// A formatted reply of about `characters` characters: a heading, prose, a
    /// bullet list and a fenced block, which is what the markdown row parses.
    static func reply(seed: Int, characters: Int) -> String {
        var generator = Generator(seed: seed &* 31 &+ 7)
        var lines: [String] = ["## " + sentence(&generator, words: 4)]
        var length = lines[0].count
        var block = 0
        while length < characters {
            switch block % 4 {
            case 0:
                for _ in 0..<3 {
                    let line = sentence(&generator, words: 14 + generator.next(12))
                    lines.append(line)
                    length += line.count + 1
                }
            case 1:
                for _ in 0..<4 {
                    let line = "- " + sentence(&generator, words: 6 + generator.next(8))
                    lines.append(line)
                    length += line.count + 1
                }
            case 2:
                lines.append("```")
                for _ in 0..<3 {
                    let line = "    let " + word(&generator) + " = " + word(&generator) + "(" + word(&generator) + ")"
                    lines.append(line)
                    length += line.count + 1
                }
                lines.append("```")
                length += 8
            default:
                let line = "**" + sentence(&generator, words: 3) + "** " + sentence(&generator, words: 18 + generator.next(10))
                lines.append(line)
                length += line.count + 1
            }
            lines.append("")
            length += 1
            block += 1
        }
        return lines.joined(separator: "\n")
    }

    private static let vocabulary = [
        "transcript", "layout", "measurement", "reply", "teammate", "workspace",
        "conversation", "recovery", "backup", "attachment", "composer", "sidebar",
        "diagnostics", "intrinsic", "constraint", "selection", "accessibility",
        "scrolling", "streaming", "handoff", "session", "installed", "window",
        "column", "wrapping", "native", "control", "bounded", "settled", "receipt"
    ]

    private static func word(_ generator: inout Generator) -> String {
        vocabulary[generator.next(vocabulary.count)]
    }

    private static func sentence(_ generator: inout Generator, words count: Int) -> String {
        var parts: [String] = []
        for _ in 0..<max(1, count) { parts.append(word(&generator)) }
        return parts.joined(separator: " ").prefix(1).uppercased() + parts.joined(separator: " ").dropFirst() + "."
    }

    /// A small linear congruential generator: the same seed gives the same text
    /// on every machine and every run, which is what a benchmark needs.
    private struct Generator {
        private var state: UInt64

        init(seed: Int) {
            state = UInt64(truncatingIfNeeded: seed) &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        }

        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return bound <= 0 ? 0 : Int((state >> 33) % UInt64(bound))
        }
    }
}

private extension NSView {
    var benchmarkDescendants: [NSView] { subviews + subviews.flatMap(\.benchmarkDescendants) }
}
