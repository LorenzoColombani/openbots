import AppKit
import SwiftUI
import XCTest
@testable import OpenBotsUI

/// What `.defaultScrollAnchor(.bottom)` costs a lazy transcript.
///
/// Reported in use: scrolling in a conversation got slow. The transcript
/// was a `ScrollView` over a `LazyVStack`, and a bottom scroll
/// anchor had been added to it so that a reader sitting at the end of a conversation
/// stayed at the end when the details pane narrowed the column. A bottom anchor
/// needs the scroll view's total content height, and the suspicion is that
/// needing it defeats the lazy stack: every row measured whenever the transcript
/// lays out, instead of the two or three the viewport actually shows, and every
/// row measurement is a complete AppKit text layout of a whole reply.
///
/// This file measures that rather than arguing about it. The same forty-row
/// transcript is hosted twice in a real window at one width, once with the
/// anchor and once without, and the label counters are read as deltas around
/// two phases: the open, and a twenty-one step scroll sweep. Wall time is taken
/// in a separate uncounted run, because timing a counted run would measure the
/// counters.
///
/// The counts are the receipt. What is asserted is only what must not stop
/// being true: the harness is lazy at all (otherwise the comparison is void),
/// the counters are live (otherwise every bound below is vacuous), and a reader
/// at the end of the transcript stays there when the column narrows.
@MainActor
final class TranscriptScrollAnchorMeasurementTests: XCTestCase {
    private static let windowWidth: CGFloat = 1_080
    private static let windowHeight: CGFloat = 720
    private static let rowCount = 40
    private static let scrollSteps = 20

    // MARK: - The measurement

    func testBottomScrollAnchorAgainstAPlainLazyTranscript() throws {
        let counted = try withLayoutDiagnostics(counters: true) {
            () throws -> (plain: ScrollAnchorVariant, anchored: ScrollAnchorVariant) in
            let plain = try measureVariant(anchored: false)
            let anchored = try measureVariant(anchored: true)
            return (plain, anchored)
        }
        // Timed with the counters off, because that is what the app ships, and
        // twice per variant in alternating order so a one-off warm-up cannot be
        // read as a difference between the two. `measureVariant` now also
        // empties the shared measurement store before each run, which is what
        // makes the alternation mean anything at all once heights outlive the
        // labels that produced them.
        let timed = try withLayoutDiagnostics(counters: false) {
            () throws -> [(String, ScrollAnchorVariant)] in
            var runs: [(String, ScrollAnchorVariant)] = []
            for pass in 1...2 {
                runs.append(("plain    pass \(pass)", try measureVariant(anchored: false)))
                runs.append(("anchored pass \(pass)", try measureVariant(anchored: true)))
            }
            return runs
        }

        print("[anchor] \(Self.rowCount) rows, window \(Int(Self.windowWidth))x\(Int(Self.windowHeight)) pt")
        print("[anchor] counted   plain    \(counted.plain.report)")
        print("[anchor] counted   anchored \(counted.anchored.report)")
        for (name, run) in timed { print("[anchor] shipped   \(name) \(run.timing)") }
        print("[anchor] per-step  plain    \(counted.plain.stepReport)")
        print("[anchor] per-step  anchored \(counted.anchored.stepReport)")

        // Non-vacuous: the counters have to be recording, or every count below
        // is zero against zero and the comparison says nothing.
        XCTAssertGreaterThan(
            counted.plain.open.sizeThatFits, 0,
            "the label counters are not recording; every number here would be vacuous"
        )
        // Valid: the harness has to be lazy without the anchor, or the anchor is
        // being blamed for a measurement the harness itself forced.
        XCTAssertLessThan(
            counted.plain.open.realizedLabels, Self.rowCount,
            "the plain transcript realized every row, so this harness cannot tell the anchor apart from itself: \(counted.plain.open.realizedLabels) labels"
        )
        // Comparable: the two variants must hold the same transcript.
        XCTAssertEqual(counted.plain.open.rows, counted.anchored.open.rows)

        // The verdict, pinned. `.defaultScrollAnchor(.bottom)` does not defeat
        // the lazy stack: it starts the viewport at the end and estimates the
        // rows above exactly as the plain scroll view estimates the rows below.
        // Measured: two rows realized and six full text layouts
        // at open, against four rows and eight layouts without the anchor.
        XCTAssertLessThanOrEqual(
            counted.anchored.open.realizedLabels, Self.rowCount / 4,
            "the bottom anchor now realizes most of the transcript at open: \(counted.anchored.open.realizedLabels) of \(Self.rowCount) rows"
        )
        XCTAssertLessThanOrEqual(
            counted.anchored.open.measureMiss, max(8, counted.plain.open.measureMiss * 3),
            "the bottom anchor now costs far more text layout at open than a plain scroll view: \(counted.anchored.open.measureMiss) against \(counted.plain.open.measureMiss)"
        )
    }

    /// Where the scroll pass spends its time, and what the shared cache bought.
    ///
    /// A row that leaves the viewport is thrown away by the lazy stack, so its
    /// label goes with it. When the measurement cache lived on the label,
    /// scrolling back over rows already read paid the full AppKit text layout
    /// again: the return sweep cost what the first one cost, 46 text layouts
    /// then 47. The cache is now shared across labels.
    ///
    /// The guarantee this asserts is exact rather than approximate: **no text is
    /// ever laid out twice at the same width.** A miss is classified at the
    /// moment it happens into a first measurement, which is the floor, and a
    /// repeat, which is the defect. Asserting instead that the return sweep
    /// misses nothing would be wrong, and was: a lazy stack keeps its
    /// realization buffer ahead of the direction of travel, so coming back up
    /// realizes rows going down never touched, and those are honest first
    /// measurements of rows this harness has not yet seen. Two more traversals
    /// of the identical path settle the question — by then there is nothing left
    /// to see, and they measure nothing at all.
    func testScrollingBackOverReadRowsCostsNothingToMeasure() throws {
        // The measurement store is shared across labels and therefore across
        // tests in one process: another case in this file measures the same
        // fixture text at the same width, so without this the first sweep here
        // would already be warm and the test would prove nothing.
        SharedTranscriptTextCaches.removeAll()
        let counted = try withLayoutDiagnostics(counters: true) {
            try measureVariant(anchored: true, extraSweeps: 2)
        }
        let sweeps = [counted.scrolled, counted.returned] + counted.extra
        let names = ["1 down", "2 up", "3 down", "4 up"]
        for (name, phase) in zip(names, sweeps) {
            print("[anchor] sweep \(name): \(phase.counts)")
        }
        print("[anchor] sweep cost: " + zip(names, sweeps)
            .map { String(format: "%@ %.1f ms", $0.0, $0.1.milliseconds) }
            .joined(separator: ", "))
        let stepSets = [counted.steps, counted.returnSteps] + counted.extraSteps
        for (name, steps) in zip(names, stepSets) where !steps.isEmpty {
            let measuring = steps.filter { $0.measureMiss > 0 }
            let quiet = steps.filter { $0.measureMiss == 0 }
            func average(_ set: [ScrollAnchorStep]) -> Double {
                set.isEmpty ? 0 : set.map(\.milliseconds).reduce(0, +) / Double(set.count)
            }
            print(String(
                format: "[anchor] sweep %@ steps: %d realized a row (avg %.1f ms), %d realized none (avg %.1f ms)",
                name, measuring.count, average(measuring), quiet.count, average(quiet)
            ))
        }

        XCTAssertGreaterThan(
            counted.scrolled.measureMiss, 0,
            "the first sweep measured nothing; the counters or the sweep are not working"
        )
        XCTAssertEqual(
            counted.scrolled.measureUnkeyed + counted.returned.measureUnkeyed, 0,
            "a hosted transcript row never declared what it was showing, so it cannot share a measurement at all"
        )
        for (name, phase) in zip(names, sweeps) {
            XCTAssertEqual(
                phase.measureRepeat, 0,
                "sweep \(name) laid text out \(phase.measureRepeat) times that had already been laid out at that width"
            )
        }
        // The two traversals after sweep 2 re-walk a path already walked, so
        // they should lay out almost nothing. Not exactly nothing: a lazy stack
        // keeps its realization buffer ahead of the direction of travel, and
        // under load it can reach one row further than it did the first time,
        // whose text is then measured for the first time rather than a second.
        // The repeat count above is the guarantee; this is the magnitude.
        let firstSweep = max(counted.scrolled.measureMiss, 1)
        for (name, phase) in zip(names, sweeps).dropFirst(2) {
            XCTAssertLessThanOrEqual(
                phase.measureMiss, max(2, firstSweep / 8),
                "sweep \(name) re-walked a path already walked and still laid text out \(phase.measureMiss) times against the first sweep's \(firstSweep)"
            )
        }
    }

    /// The shipped view, `OpenBotsRootView`, with its transcript and its anchor
    /// over forty rows. This once asserted the opposite of what
    /// it asserts now: that the transcript realized only a handful of rows at
    /// open, because it was a `LazyVStack`. That lazy stack is what the installed
    /// app looped inside (rows placed and un-placed, their
    /// estimates re-measured, the anchor translated, a prefetch queueing the next
    /// transaction in the same flush, never returning to the run loop), so the
    /// transcript is a plain stack now and every loaded row is realized at open.
    /// This pins that: a lazy stack coming back would fail here before it could
    /// freeze the app again. The harness above still measures the lazy variant
    /// on purpose, as the record of what the anchor cost when the stack was lazy.
    func testShippedTranscriptRealizesEveryLoadedRowAtOpen() throws {
        // Cold, for the same reason `measureVariant` starts cold: the counts
        // below describe what opening a conversation costs, not what it costs
        // after another test in this process has already measured its rows.
        SharedTranscriptTextCaches.removeAll()
        let counted = try withLayoutDiagnostics(counters: true) {
            () throws -> (open: ScrollAnchorPhase, sweep: ScrollAnchorPhase, steps: [ScrollAnchorStep]) in
            let fixture = ShippedTranscriptFixture(rowCount: Self.rowCount)
            let window = Self.makeWindow()
            defer { Self.close(window) }

            var open = ScrollAnchorPhase()
            let before = Self.counterSnapshot()
            let start = ProcessInfo.processInfo.systemUptime
            let host = NSHostingView(rootView: ShippedTranscriptHarness(fixture: fixture))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
            Self.settle(host)
            Self.pump(for: 0.3)
            Self.settle(host)
            open.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            open.apply(Self.counterDelta(since: before))
            let scroll = try Self.transcriptScrollView(in: host)
            // Only the transcript's own rows, not the sidebar's or the header's.
            open.realizedLabels = Self.labels(in: scroll).count
            open.documentHeight = scroll.documentView?.bounds.height ?? 0
            open.viewportHeight = scroll.contentView.bounds.height
            open.rows = Self.rowCount

            var steps: [ScrollAnchorStep] = []
            var sweep = Self.sweep(
                scroll, host: host, rows: Self.rowCount, descending: false, steps: &steps
            )
            sweep.realizedLabels = Self.labels(in: scroll).count
            return (open, sweep, steps)
        }

        print("[anchor] shipped root view open[\(counted.open.counts) doc=\(Int(counted.open.documentHeight))pt] sweep[\(counted.sweep.counts)]")

        XCTAssertGreaterThan(
            counted.open.sizeThatFits, 0,
            "the label counters are not recording; the bound below would be vacuous"
        )
        // Every loaded row has a label at open: nothing in the transcript is an
        // estimate that a scroll or a pane can turn into a placement loop.
        XCTAssertGreaterThanOrEqual(
            counted.open.realizedLabels, Self.rowCount,
            "the shipped transcript realized only \(counted.open.realizedLabels) of \(Self.rowCount) rows at open; a lazy stack is back in the transcript, and that is what froze the installed app before"
        )
        // And it still opens on its latest message. The transcript's own bottom
        // padding (24 pt) may sit below the viewport: opening scrolls the last
        // row's bottom edge to the viewport's, and the padding follows the row.
        let scroll = try withLayoutDiagnostics(counters: false) { () throws -> CGFloat in
            let fixture = ShippedTranscriptFixture(rowCount: Self.rowCount)
            let window = Self.makeWindow()
            defer { Self.close(window) }
            let host = NSHostingView(rootView: ShippedTranscriptHarness(fixture: fixture))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
            Self.settle(host)
            Self.pump(for: 0.3)
            Self.settle(host)
            return Self.distanceFromEnd(of: try Self.transcriptScrollView(in: host))
        }
        XCTAssertLessThanOrEqual(
            scroll, OpenBotsVisualStyle.spacing24 + 1,
            "the shipped transcript no longer opens on its latest message: \(scroll) pt from the end"
        )
    }

    // MARK: - The guarantee the anchor was added for

    /// Seen live: the installed app hung when the details pane opened over a
    /// conversation whose reader sat at the end. `.defaultScrollAnchor(.bottom)`
    /// fixed it, and `SelectableTextLayoutRegressionTests` pins that in the real
    /// root view. This pins the narrower rule the transcript has to keep however
    /// the tail is followed: a reader at the end of the transcript is still at
    /// the end after the column narrows, with no row appended and no
    /// conversation change to trigger a follow.
    func testReaderAtTheEndStaysAtTheEndWhenTheColumnNarrows() throws {
        let fixture = ScrollAnchorFixture(rowCount: 12)
        let window = Self.makeWindow()
        defer { Self.close(window) }
        let host = NSHostingView(rootView: ScrollAnchorHarness(fixture: fixture, anchored: true))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        Self.settle(host)

        let scroll = try Self.transcriptScrollView(in: host)
        Self.scrollToEnd(scroll)
        Self.settle(host)
        XCTAssertLessThanOrEqual(
            Self.distanceFromEnd(of: scroll), 1,
            "the fixture must start at the end of the transcript"
        )

        // The details pane opening, as a width change with no new row.
        fixture.columnInset = 300
        Self.settle(host)
        Self.pump(for: 0.3)
        Self.settle(host)
        XCTAssertLessThanOrEqual(
            Self.distanceFromEnd(of: scroll), 1,
            "a reader at the end must stay at the end when the column narrows: document \(scroll.documentView?.bounds.height ?? -1) visible \(scroll.documentVisibleRect)"
        )
    }

    // MARK: - Measuring one variant

    private func measureVariant(anchored: Bool, extraSweeps: Int = 0) throws -> ScrollAnchorVariant {
        // Every variant reads the same forty rows at the same width, and a
        // measured height outlives the label that produced it and
        // is shared across the whole process. Without this the second variant
        // would find the first one's answers waiting, report almost no text
        // layout, and pass the comparison below for the wrong reason. Each
        // variant starts cold so the two are measured on equal terms.
        SharedTranscriptTextCaches.removeAll()
        let fixture = ScrollAnchorFixture(rowCount: Self.rowCount)
        let window = Self.makeWindow()
        defer { Self.close(window) }

        var open = ScrollAnchorPhase()
        let openBefore = Self.counterSnapshot()
        let openStart = ProcessInfo.processInfo.systemUptime
        let host = NSHostingView(rootView: ScrollAnchorHarness(fixture: fixture, anchored: anchored))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        Self.settle(host)
        open.milliseconds = (ProcessInfo.processInfo.systemUptime - openStart) * 1_000
        open.apply(Self.counterDelta(since: openBefore))

        let scroll = try Self.transcriptScrollView(in: host)
        open.realizedLabels = Self.labels(in: host).count
        open.documentHeight = scroll.documentView?.bounds.height ?? 0
        open.viewportHeight = scroll.contentView.bounds.height
        open.rows = fixture.rows.count

        var steps: [ScrollAnchorStep] = []
        let scrolled = Self.sweep(scroll, host: host, rows: fixture.rows.count, descending: true, steps: &steps)
        var returnSteps: [ScrollAnchorStep] = []
        let returned = Self.sweep(scroll, host: host, rows: fixture.rows.count, descending: false, steps: &returnSteps)

        // Optional further traversals of the very same path. By the third one
        // every row this harness will ever realize has been realized once, so a
        // measurement store that works takes them to zero. Two sweeps alone
        // cannot show that: a lazy stack keeps its realization buffer ahead of
        // the direction of travel, so coming back up realizes rows going down
        // never touched, and those are first measurements rather than repeats.
        var extra: [ScrollAnchorPhase] = []
        var extraSteps: [[ScrollAnchorStep]] = []
        for index in 0..<max(0, extraSweeps) {
            var sweepSteps: [ScrollAnchorStep] = []
            extra.append(Self.sweep(
                scroll, host: host, rows: fixture.rows.count,
                descending: index.isMultiple(of: 2), steps: &sweepSteps
            ))
            extraSteps.append(sweepSteps)
        }

        for label in Self.labels(in: host) {
            XCTAssertTrue(label.frame.height.isFinite, "non-finite row height")
            XCTAssertLessThan(label.frame.height, 8_000, "runaway row height \(label.frame)")
        }
        return ScrollAnchorVariant(
            open: open, scrolled: scrolled, returned: returned,
            steps: steps, returnSteps: returnSteps, extra: extra, extraSteps: extraSteps
        )
    }

    /// One scroll sweep across the whole transcript, timed and counted per step
    /// so a slow step can be matched against the rows it had to measure.
    private static func sweep(
        _ scroll: NSScrollView,
        host: NSView,
        rows: Int,
        descending: Bool,
        steps: inout [ScrollAnchorStep]
    ) -> ScrollAnchorPhase {
        var phase = ScrollAnchorPhase()
        let before = counterSnapshot()
        let start = ProcessInfo.processInfo.systemUptime
        if let document = scroll.documentView {
            let span = max(0, document.bounds.height - scroll.contentView.bounds.height)
            for step in 0...scrollSteps {
                let progress = CGFloat(step) / CGFloat(scrollSteps)
                let fraction = descending ? progress : 1 - progress
                let offset = document.isFlipped ? span * fraction : span * (1 - fraction)
                let stepBefore = counterSnapshot()
                let stepStart = ProcessInfo.processInfo.systemUptime
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(host, cycles: 2)
                let stepDelta = counterDelta(since: stepBefore)
                steps.append(ScrollAnchorStep(
                    milliseconds: (ProcessInfo.processInfo.systemUptime - stepStart) * 1_000,
                    measureMiss: stepDelta["label.measureMiss"] ?? 0,
                    sizeThatFits: stepDelta["label.sizeThatFits"] ?? 0
                ))
            }
        }
        phase.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        phase.apply(counterDelta(since: before))
        phase.realizedLabels = labels(in: host).count
        phase.documentHeight = scroll.documentView?.bounds.height ?? 0
        phase.viewportHeight = scroll.contentView.bounds.height
        phase.rows = rows
        return phase
    }

    // MARK: - Helpers

    private static let countedNames = [
        "label.sizeThatFits", "label.measureMiss", "label.measureHit", "label.update",
        "label.measureShared", "label.measureFirst", "label.measureRepeat", "label.measureUnkeyed"
    ]

    private static func counterSnapshot() -> [String: Int] {
        var snapshot: [String: Int] = [:]
        for name in countedNames { snapshot[name] = LayoutStormCounters.lifetime[name, default: 0] }
        return snapshot
    }

    /// `LayoutStormCounters.lifetime` is cumulative with no reset, so every
    /// number here is a delta around one phase. Absolutes would make whichever
    /// variant ran second look worse for free.
    private static func counterDelta(since before: [String: Int]) -> [String: Int] {
        var delta: [String: Int] = [:]
        for name in countedNames {
            delta[name] = LayoutStormCounters.lifetime[name, default: 0] - (before[name] ?? 0)
        }
        return delta
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func close(_ window: NSWindow) {
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    /// Drive SwiftUI and AppKit to a settled layout. Deliberately without
    /// `fittingSize`: asking a `ScrollView` for its ideal size measures all of
    /// its content whatever the anchor says, which would erase the difference
    /// this file exists to find.
    private static func settle(_ view: NSView, cycles: Int = 6) {
        for _ in 0..<cycles {
            view.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.003))
        }
    }

    private static func pump(for seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private static func labels(in host: NSView) -> [NSTextField] {
        host.anchorLayoutDescendants.compactMap { $0 as? NSTextField }
    }

    /// The real root view has several scroll views: the sidebar's list, the
    /// details pane, the transcript. The transcript is the one holding a
    /// forty-row conversation, so it is the tallest by a wide margin; picking
    /// the first one found walked into the sidebar and measured nothing.
    private static func transcriptScrollView(in host: NSView) throws -> NSScrollView {
        let scrolls = host.anchorLayoutDescendants.compactMap { $0 as? NSScrollView }
        let tallest = try XCTUnwrap(
            scrolls.max(by: { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }),
            "no scroll view in the hosted view"
        )
        XCTAssertGreaterThan(
            tallest.documentView?.bounds.height ?? 0, 2_000,
            "the tallest scroll view is only \(tallest.documentView?.bounds.height ?? -1) pt; this is not the transcript"
        )
        return tallest
    }

    private static func scrollToEnd(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let span = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? span : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// How far the viewport's end sits from the end of the transcript, in points.
    private static func distanceFromEnd(of scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        let visible = scroll.documentVisibleRect
        return document.isFlipped
            ? max(0, document.bounds.maxY - visible.maxY)
            : max(0, visible.minY - document.bounds.minY)
    }
}

// MARK: - What one phase measured

private struct ScrollAnchorPhase {
    var sizeThatFits = 0
    var measureMiss = 0
    var measureHit = 0
    var measureShared = 0
    /// A miss on text never laid out at this width before: the floor.
    var measureFirst = 0
    /// A miss on text already laid out at this width: the defect.
    var measureRepeat = 0
    /// A miss on a label whose row declared nothing, so it cannot share at all.
    var measureUnkeyed = 0
    var labelUpdate = 0
    var realizedLabels = 0
    var rows = 0
    var milliseconds: Double = 0
    var documentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    mutating func apply(_ delta: [String: Int]) {
        sizeThatFits = delta["label.sizeThatFits"] ?? 0
        measureMiss = delta["label.measureMiss"] ?? 0
        measureHit = delta["label.measureHit"] ?? 0
        measureShared = delta["label.measureShared"] ?? 0
        measureFirst = delta["label.measureFirst"] ?? 0
        measureRepeat = delta["label.measureRepeat"] ?? 0
        measureUnkeyed = delta["label.measureUnkeyed"] ?? 0
        labelUpdate = delta["label.update"] ?? 0
    }

    var counts: String {
        "sizeThatFits=\(sizeThatFits) measureMiss=\(measureMiss)(first \(measureFirst), repeat \(measureRepeat), unkeyed \(measureUnkeyed)) measureHit=\(measureHit) shared=\(measureShared) update=\(labelUpdate) alive=\(realizedLabels)/\(rows)"
    }
}

private struct ScrollAnchorStep {
    let milliseconds: Double
    let measureMiss: Int
    let sizeThatFits: Int
}

private struct ScrollAnchorVariant {
    let open: ScrollAnchorPhase
    let scrolled: ScrollAnchorPhase
    let returned: ScrollAnchorPhase
    let steps: [ScrollAnchorStep]
    var returnSteps: [ScrollAnchorStep] = []
    var extra: [ScrollAnchorPhase] = []
    var extraSteps: [[ScrollAnchorStep]] = []

    var report: String {
        String(
            format: "open[%@ doc=%.0fpt vis=%.0fpt] sweep[%@]",
            open.counts, open.documentHeight, open.viewportHeight, scrolled.counts
        )
    }

    var timing: String {
        String(
            format: "open %.1f ms, sweep %.1f ms, return sweep %.1f ms, doc=%.0fpt",
            open.milliseconds, scrolled.milliseconds, returned.milliseconds, open.documentHeight
        )
    }

    /// The cost of a scroll step against the text layout it had to do. A step
    /// that measures nothing is what a fast scroll looks like.
    var stepReport: String {
        let measuring = steps.filter { $0.measureMiss > 0 }
        let quiet = steps.filter { $0.measureMiss == 0 }
        func average(_ values: [ScrollAnchorStep]) -> Double {
            values.isEmpty ? 0 : values.map(\.milliseconds).reduce(0, +) / Double(values.count)
        }
        return String(
            format: "%d steps: %d measured a row (avg %.1f ms), %d measured nothing (avg %.1f ms), worst %.1f ms",
            steps.count, measuring.count, average(measuring), quiet.count, average(quiet),
            steps.map(\.milliseconds).max() ?? 0
        )
    }
}

// MARK: - Fixture

@MainActor
private final class ScrollAnchorFixture: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let text: String
        let isReply: Bool
    }

    let rows: [Row]
    /// The details pane's width, as a column the transcript has to give up.
    @Published var columnInset: CGFloat = 0

    init(rowCount: Int) {
        rows = ScrollAnchorText.transcript(rowCount: rowCount)
    }
}

/// The transcript's geometry, without the workspace around it: a scrolling lazy
/// column capped at 880 points, short messages the reader typed and long
/// formatted replies, and a pane that can take width from the right.
private struct ScrollAnchorHarness: View {
    @ObservedObject var fixture: ScrollAnchorFixture
    let anchored: Bool

    var body: some View {
        HStack(spacing: 0) {
            transcript
            if fixture.columnInset > 0 {
                Divider()
                VStack { Text("Details"); Spacer() }.frame(width: fixture.columnInset)
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if anchored {
            column.defaultScrollAnchor(.bottom)
        } else {
            column
        }
    }

    private var column: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(fixture.rows) { row in
                    Group {
                        if row.isReply {
                            SafeReplyMarkdownText(content: row.text)
                        } else {
                            StableSelectableText(row.text)
                        }
                    }
                    .id(row.id)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - The shipped view, not an imitation of it

@MainActor
private final class ShippedTranscriptFixture: ObservableObject {
    let sidebar: SidebarModel
    let conversation: ConversationModel

    init(rowCount: Int) {
        let bot = TeammateRowSnapshot(
            id: scrollAnchorUUID(1), name: "Anchor Layout Bot",
            role: "Local fixture", activity: .idle, identitySeed: 21
        )
        sidebar = SidebarModel(rows: [bot], selection: bot.id)
        let messages = ScrollAnchorText.transcript(rowCount: rowCount).map { row in
            ChatMessageSnapshot(
                id: scrollAnchorUUID(UInt64(1_000 + row.id)),
                author: row.isReply ? .teammate(bot.identity) : .user,
                body: row.text,
                delivery: .sent,
                timestamp: Date(timeIntervalSince1970: Double(row.id))
            )
        }
        conversation = ConversationModel(
            conversationID: scrollAnchorUUID(100), title: bot.name, messages: messages,
            readyDeliveryDescription: "Scroll-anchor measurement fixture; no runtime or repository.",
            inputAvailability: .ready, submit: { _, _, _ in }
        )
    }
}

private struct ShippedTranscriptHarness: View {
    @ObservedObject var fixture: ShippedTranscriptFixture

    var body: some View {
        OpenBotsRootView(
            sidebar: fixture.sidebar, conversation: fixture.conversation,
            createTeammate: {}, openSettings: {}
        )
    }
}

private func scrollAnchorUUID(_ suffix: UInt64) -> UUID {
    UUID(uuidString: String(format: "A0C40000-0000-0000-0000-%012llx", suffix))!
}

/// Deterministic transcript text: the same seed gives the same characters on
/// every machine and every run, so two variants measure the same transcript.
private enum ScrollAnchorText {
    static func transcript(rowCount: Int) -> [ScrollAnchorFixture.Row] {
        let lengths = [2_000, 3_500, 5_000, 6_000]
        return (0..<rowCount).map { index in
            if index.isMultiple(of: 2) {
                return ScrollAnchorFixture.Row(id: index, text: userMessage(seed: index), isReply: false)
            }
            return ScrollAnchorFixture.Row(
                id: index,
                text: reply(seed: index, characters: lengths[(index / 2) % lengths.count]),
                isReply: true
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
                let line = "**" + sentence(&generator, words: 3) + "** "
                    + sentence(&generator, words: 18 + generator.next(10))
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
        "transcript", "anchor", "measurement", "reply", "teammate", "workspace",
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
        let joined = parts.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

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
    var anchorLayoutDescendants: [NSView] { subviews + subviews.flatMap(\.anchorLayoutDescendants) }
}
