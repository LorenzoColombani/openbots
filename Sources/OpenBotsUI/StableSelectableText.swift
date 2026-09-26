import AppKit
import CryptoKit
import OpenBotsServices
import SwiftUI

/// Which of the two transcript rows a label is showing. A reply and a message
/// holding the same characters must never answer for each other: the reply's
/// bold, monospaced and indented runs wrap at a different height.
enum TranscriptTextKind: UInt8 {
    case plain = 1
    case markdown = 2
}

/// What a row declares its label to be showing: everything that decides a
/// measured height except the width itself.
struct TranscriptTextDeclaration: Equatable {
    let kind: TranscriptTextKind
    let tone: UInt8
    let fontName: String
    let fontSize: CGFloat
    let content: String
    /// How many characters the label ends up holding: the content itself for a
    /// message, and the rendered length for a reply, whose markers are gone by
    /// the time the label sees it. Not part of the digest — it is what the label
    /// checks itself against before it trusts a declaration.
    let renderedLength: Int

    init(kind: TranscriptTextKind, tone: UInt8, font: NSFont, content: String, renderedLength: Int? = nil) {
        self.kind = kind
        self.tone = tone
        fontName = font.fontName
        fontSize = font.pointSize
        self.content = content
        self.renderedLength = renderedLength ?? content.utf16.count
    }
}

/// A declaration's fingerprint, and the key the shared stores below are built on.
///
/// A digest rather than the text: those stores hold a few hundred entries, and
/// keying them by value would swap a layout cost for holding a few hundred
/// six-kilobyte replies alive after the rows showing them are gone. Two labels
/// whose declarations digest the same measure the same height, so one label's
/// text layout answers for the other's. Computed once when a row declares its
/// content, never inside a measurement.
struct TranscriptTextDigest: Hashable {
    let high: UInt64
    let low: UInt64

    /// SHA-256, truncated to 128 bits. A cheaper 64-bit hash would be fast
    /// enough — this runs once per row build, four microseconds for a
    /// six-kilobyte reply — but a collision here is a wrong row height, which is
    /// the one failure this cache is not allowed to introduce.
    static func make(_ declaration: TranscriptTextDeclaration) -> TranscriptTextDigest {
        var sha = SHA256()
        var header = Data([declaration.kind.rawValue, declaration.tone])
        // Length-prefixed, so a longer font name and a shorter body cannot hash
        // the same bytes as a shorter name and a longer body.
        let name = Array(declaration.fontName.utf8)
        withUnsafeBytes(of: UInt32(name.count).littleEndian) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: declaration.fontSize.bitPattern.littleEndian) { header.append(contentsOf: $0) }
        header.append(contentsOf: name)
        withUnsafeBytes(of: UInt64(declaration.content.utf8.count).littleEndian) { header.append(contentsOf: $0) }
        sha.update(data: header)
        var content = declaration.content
        content.withUTF8 { sha.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, byte) in sha.finalize().enumerated() {
            if index < 8 { high = high << 8 | UInt64(byte) } else if index < 16 { low = low << 8 | UInt64(byte) } else { break }
        }
        return TranscriptTextDigest(high: high, low: low)
    }
}

/// Measured heights and parsed markdown that outlive the row that produced them.
///
/// Any row whose hosting views are rebuilt — as happened on every scroll back
/// while the transcript was a `LazyVStack`, and still happens whenever a row is
/// recreated — starts with a brand-new label with an empty per-label cache and
/// a brand-new markdown coordinator with an empty parse. Without these stores,
/// a rebuilt row would cost a full markdown parse and a full text layout on
/// the main thread, about 47 ms for a long reply and three dropped frames, once
/// per message. These two stores make the second build free.
///
/// Bounded, so a long session cannot grow them without end, and keyed by a
/// digest, so nothing here holds a reply by value.
@MainActor
enum SharedTranscriptTextCaches {
    /// The backing scale and the appearance are in the key rather than reasons to
    /// clear. The scale decides which widths a label snaps to; the appearance can
    /// change a label's metrics, and a vibrant container, a high-contrast setting
    /// or a second window with an appearance override puts two of them on screen
    /// at once. Clearing on either would also be wrong in a worse way —
    /// `viewDidChangeBackingProperties` and `viewDidChangeEffectiveAppearance`
    /// both fire when a view is inserted into a window, which is exactly when a
    /// row scrolls in, so a clear there would empty the store on the pass it
    /// exists to serve. Keyed, the two coexist instead of evicting each other.
    struct MeasurementKey: Hashable {
        let digest: TranscriptTextDigest
        let snappedWidth: CGFloat
        let backingScale: CGFloat
        let appearance: NSAppearance.Name
    }

    /// A transcript column rests at a handful of widths, so a few hundred
    /// heights is several screens of history at every width it has had.
    static let measurementLimit = 512
    /// Parsed replies are the heavy entries — a formatted six-kilobyte reply is
    /// an attributed string with hundreds of runs — so this is deliberately the
    /// smaller of the two: a working set, not a transcript.
    static let parseLimit = 64
    /// How far back the diagnostics below can tell a repeated measurement from a
    /// first one. Twice the store, so a key the store has just evicted is still
    /// recognised as one whose text was already laid out at that width.
    static let recordedKeyLimit = measurementLimit * 2

    private static var measurements: [MeasurementKey: CGFloat] = [:]
    private static var measurementOrder: [MeasurementKey] = []
    private static var parses: [TranscriptTextDigest: NSAttributedString] = [:]
    private static var parseOrder: [TranscriptTextDigest] = []
    /// Diagnostics only: the most recent keys measured, including keys the bound
    /// above has since evicted. A miss on a key that is in here is a text layout
    /// performed twice for the same text at the same width, which is the defect
    /// these stores exist to remove; a miss on a key that is not is a first
    /// measurement, which is the floor. Counting misses alone cannot tell those
    /// apart, and a scrolling harness realizes different rows going down than
    /// coming up, so the difference is the whole question. Bounded like the two
    /// stores: `OPENBOTS_LAYOUT_DIAGNOSTICS=1` turns the counters on in a shipped
    /// build, and a long session with them on must not grow a set without end.
    private static var everMeasured: Set<MeasurementKey> = []
    private static var everMeasuredOrder: [MeasurementKey] = []

    static func noteMissed(_ key: MeasurementKey) {
        guard LayoutStormCounters.isEnabled else { return }
        LayoutStormCounters.hit(everMeasured.contains(key) ? "label.measureRepeat" : "label.measureFirst")
    }

    static func measuredHeight(for key: MeasurementKey) -> CGFloat? { measurements[key] }

    static func remember(_ height: CGFloat, for key: MeasurementKey) {
        if LayoutStormCounters.isEnabled, everMeasured.insert(key).inserted {
            everMeasuredOrder.append(key)
            trim(&everMeasured, &everMeasuredOrder, to: recordedKeyLimit)
        }
        guard measurements.updateValue(height, forKey: key) == nil else { return }
        measurementOrder.append(key)
        trim(&measurements, &measurementOrder, to: measurementLimit)
    }

    static func parsedMarkdown(for digest: TranscriptTextDigest) -> NSAttributedString? { parses[digest] }

    static func rememberParsedMarkdown(_ value: NSAttributedString, for digest: TranscriptTextDigest) {
        guard parses.updateValue(value, forKey: digest) == nil else { return }
        parseOrder.append(digest)
        trim(&parses, &parseOrder, to: parseLimit)
    }

    /// Diagnostics, and the receipt that the bounds above are real.
    static var storedMeasurementCount: Int { measurements.count }
    static var storedParseCount: Int { parses.count }
    static var recordedKeyCount: Int { everMeasured.count }

    static func removeAll() {
        measurements.removeAll(keepingCapacity: true)
        measurementOrder.removeAll(keepingCapacity: true)
        parses.removeAll(keepingCapacity: true)
        parseOrder.removeAll(keepingCapacity: true)
        everMeasured.removeAll(keepingCapacity: true)
        everMeasuredOrder.removeAll(keepingCapacity: true)
    }

    /// Cheap eviction: drop the oldest quarter in one pass when the store fills,
    /// rather than one entry per insertion. A transcript's working set survives.
    private static func trim<Key: Hashable, Value>(
        _ store: inout [Key: Value], _ order: inout [Key], to limit: Int
    ) {
        guard order.count > limit else { return }
        let drop = max(1, limit / 4)
        for key in order.prefix(drop) { store.removeValue(forKey: key) }
        order.removeFirst(drop)
    }

    /// The same eviction for the diagnostics set beside them.
    private static func trim<Key: Hashable>(_ store: inout Set<Key>, _ order: inout [Key], to limit: Int) {
        guard order.count > limit else { return }
        let drop = max(1, limit / 4)
        for key in order.prefix(drop) { store.remove(key) }
        order.removeFirst(drop)
    }
}

/// Selectable, wrapping transcript text without SwiftUI's private
/// `SelectionOverlay` bridge.
///
/// On macOS 26.6.2 that bridge can reapply its backing text field's font while
/// a lazy transcript is replacing rows and moving focus. The font write
/// invalidates intrinsic size during AppKit's constraint pass and can create an
/// unbounded display-cycle feedback loop. A native wrapping label preserves
/// selection and accessibility while keeping one stable AppKit control.
struct StableSelectableText: NSViewRepresentable {
    enum Style {
        case body
        case callout
        case caption

        var font: NSFont {
            switch self {
            case .body:
                NSFont.preferredFont(forTextStyle: .body)
            case .callout:
                NSFont.preferredFont(forTextStyle: .callout)
            case .caption:
                NSFont.preferredFont(forTextStyle: .caption1)
            }
        }
    }

    enum Tone {
        case primary
        case secondary

        var color: NSColor {
            switch self {
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            }
        }

        /// Stable across builds: it goes into a content digest, not a file.
        var key: UInt8 {
            switch self {
            case .primary: 1
            case .secondary: 2
            }
        }
    }

    let content: String
    let style: Style
    let tone: Tone

    init(
        _ content: String,
        style: Style = .body,
        tone: Tone = .primary
    ) {
        self.content = content
        self.style = style
        self.tone = tone
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = Self.makeField(content)
        applyStablePresentation(to: field)
        return field
    }

    /// The native label as configured for the transcript, without a SwiftUI context.
    static func makeField(_ content: String) -> NSTextField {
        let field = StableWrappingLabel(wrappingLabelWithString: content)
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        LayoutStormCounters.hit("label.update", detail: Self.updateDetail(field))
        // Avoid unconditional AppKit writes from SwiftUI update passes. Font
        // and text changes legitimately invalidate intrinsic size; identical
        // values must not restart a constraint pass.
        applyStablePresentation(to: field)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView field: NSTextField,
        context: Context
    ) -> CGSize? {
        LayoutStormCounters.hit("label.sizeThatFits", detail: Self.proposalDetail(proposal))
        return Self.measuredSize(proposedWidth: proposal.width, field: field)
    }

    /// Diagnostics only; built solely while the counters are enabled. Two
    /// `enclosingScrollView` walks and seven interpolations would otherwise run
    /// here on every SwiftUI update pass.
    private static func updateDetail(_ field: NSTextField) -> String {
        let scroll = field.enclosingScrollView
        return "chars=\(field.stringValue.count) y=\(Int(field.frame.origin.y)) h=\(Int(field.frame.height)) doc=\(Int(scroll?.documentView?.frame.height ?? -1)) off=\(Int(scroll?.contentView.bounds.origin.y ?? -1)) vis=\(Int(scroll?.contentView.bounds.height ?? -1)) superH=\(Int(field.superview?.frame.height ?? -1))"
    }

    private static func proposalDetail(_ proposal: ProposedViewSize) -> String {
        "\(proposal.width.map { String(format: "%.1f", $0) } ?? "nil")x\(proposal.height.map { String(format: "%.1f", $0) } ?? "nil")"
    }

    static func measuredSize(proposedWidth: CGFloat?, field: NSTextField) -> CGSize {
        guard let width = proposedWidth, width.isFinite, width > 0 else {
            return field.intrinsicContentSize
        }
        let size = measuredSizeAtWidth(width, field: field)
        if LayoutStormDiagnostics.isEnabled {
            MainActor.assumeIsolated { LayoutStormDiagnostics.record(proposedWidth: width, measured: size, field: field) }
        }
        return size
    }

    private static func measuredSizeAtWidth(_ width: CGFloat, field: NSTextField) -> CGSize {
        // SwiftUI proposes the alignment rectangle, while NSTextFieldCell
        // measures the full frame including its text margins. Passing the
        // alignment width straight to the cell subtracts those margins twice:
        // a one-line intrinsic size can remeasure as two lines at its own width.
        // Use AppKit's inverse geometry conversions without mutating the view.
        // Measure at the width the view can actually be given: SwiftUI hands
        // the platform view a frame snapped to the backing pixel grid, so a
        // fractional proposal measured as-is can wrap one line less than the
        // final frame does. That half-point mismatch inside a scroll view is
        // enough for a relayout that never settles (main thread at 100 %,
        // observed live with the details pane open).
        let scale = field.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let snappedWidth = max(1, floor(width * scale) / scale)
        // The height below is a complete text layout: 49 ms for a six-kilobyte
        // reply on a test Mac, and nothing used to remember it, while SwiftUI asks
        // several times per pass and AppKit asks again on its own schedule. It
        // is a pure function of the snapped width, the text, the font and the
        // alignment insets, so the label remembers it per snapped width and
        // forgets it whenever any of those change. Same answer, computed less.
        let label = field as? StableWrappingLabel
        if let cached = label?.cachedMeasuredHeight(forSnappedWidth: snappedWidth) {
            LayoutStormCounters.hit("label.measureHit")
            return CGSize(width: width, height: cached)
        }
        // A row that scrolls back into view is a new label with an empty cache,
        // but its text was laid out at this width when it was read the first
        // time. The answer belongs to the text, not to the label that asked, so
        // it is kept where the next label showing that text can find it.
        let sharedKey = label?.contentDigest.map {
            SharedTranscriptTextCaches.MeasurementKey(
                digest: $0,
                snappedWidth: snappedWidth,
                backingScale: scale,
                appearance: field.effectiveAppearance.name
            )
        }
        if let sharedKey, let shared = SharedTranscriptTextCaches.measuredHeight(for: sharedKey) {
            LayoutStormCounters.hit("label.measureShared")
            label?.rememberMeasuredHeight(shared, forSnappedWidth: snappedWidth)
            return CGSize(width: width, height: shared)
        }
        LayoutStormCounters.hit("label.measureMiss")
        // Which kind of miss this is: a first measurement, a second measurement
        // of text already laid out at this width, or a label whose row never
        // declared what it was showing so it cannot share at all.
        if let sharedKey {
            SharedTranscriptTextCaches.noteMissed(sharedKey)
        } else {
            LayoutStormCounters.hit("label.measureUnkeyed")
        }
        let frameWidth = field.frame(forAlignmentRect: NSRect(
            x: 0, y: 0, width: snappedWidth, height: 1
        )).width
        let bounds = NSRect(
            x: 0,
            y: 0,
            width: frameWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        let height: CGFloat
        if let cell = field.cell {
            let measuredFrame = NSRect(origin: .zero, size: cell.cellSize(forBounds: bounds))
            height = field.alignmentRect(forFrame: measuredFrame).height
        } else {
            height = field.intrinsicContentSize.height
        }
        let measuredHeight = ceil(height)
        label?.rememberMeasuredHeight(measuredHeight, forSnappedWidth: snappedWidth)
        // The label keeps every height it measures; the store shared with every
        // other row keeps only the ones measured at a width the layout has
        // settled on. A drag is still answered from the store — the read above
        // runs whatever the edge is doing — it just leaves nothing behind.
        if let sharedKey {
            if label?.sharesMeasurementsWithOtherRows == true {
                SharedTranscriptTextCaches.remember(measuredHeight, for: sharedKey)
            } else {
                label?.holdMeasurementUntilTheEdgeStops(measuredHeight, key: sharedKey)
            }
        }
        return CGSize(width: width, height: measuredHeight)
    }

    /// The presentation SwiftUI writes on `makeNSView` and on every update pass.
    /// Not private: a benchmark builds the row without a SwiftUI `Context`, and
    /// it has to build the one AppKit actually receives.
    func applyStablePresentation(to field: NSTextField) {
        if field.stringValue != content {
            field.stringValue = content
        }
        let targetFont = style.font
        if field.font?.isEqual(targetFont) != true {
            field.font = targetFont
        }
        let targetColor = tone.color
        if field.textColor?.isEqual(targetColor) != true {
            field.textColor = targetColor
        }
        // Last, deliberately: each write above empties the label's caches and
        // drops whatever it had been declared to be showing.
        (field as? StableWrappingLabel)?.declare(TranscriptTextDeclaration(
            kind: .plain, tone: tone.key, font: targetFont, content: content
        ))
    }
}

/// A wrapping label whose AppKit intrinsic size follows the width SwiftUI gave it.
///
/// Without a preferred maximum layout width, `NSTextField` reports the widest
/// unbreakable line as its intrinsic width (5,594 pt for one sandbox error line
/// holding a 200-character path) and remembers the previous frame's wrapping.
/// Inside `PlatformViewHost` that disagreement with the frame invalidates layout,
/// SwiftUI re-proposes, and with a transcript column that just changed width the
/// cycle never settled: main thread at 100 %, window gone (seen in the installed app,
/// details pane opening over long report lines). Keeping the
/// preferred width equal to the alignment width makes intrinsic and measured
/// sizes agree; the write is changed-only so an unchanged frame writes nothing.
final class StableWrappingLabel: NSTextField {
    private var invalidations = 0
    /// Heights this label has already laid its text out for, by snapped width.
    /// Emptied by every write that can change what a measurement would answer.
    private var measuredHeights: [CGFloat: CGFloat] = [:]
    /// AppKit's own intrinsic sizes, by the preferred width each was measured at.
    private var appKitIntrinsicSizes: [CGFloat: NSSize] = [:]
    /// True only for the single statement in which this label writes its own
    /// `preferredMaxLayoutWidth`, so the invalidation that write causes is not
    /// mistaken for a change to the text.
    private var isFollowingFrameWidth = false
    /// True between AppKit's two live-resize notifications, which a window sends
    /// to every view it holds.
    private var isInsideALiveResize = false
    /// The last height the drag kept out of the shared store, with the key it
    /// was measured under. The final width a drag passes through is the width
    /// the column comes to rest at, so this is the answer every other row will
    /// want; it is shared the moment the edge stops.
    private var measurementHeldForRest: (key: SharedTranscriptTextCaches.MeasurementKey, height: CGFloat)?
    /// What the row says this label is showing, and its fingerprint. Only a
    /// label holding a declaration reads from or writes to the shared stores.
    private var declaration: TranscriptTextDeclaration?
    private var declaredDigest: TranscriptTextDigest?

    /// The row tells the label what it is showing, on the same pass that writes
    /// the text. A digest is passed in only where the row already had to compute
    /// one; otherwise it is computed on demand below, so an update pass that
    /// changes nothing never hashes a six-kilobyte reply.
    func declare(_ declaration: TranscriptTextDeclaration, digest: TranscriptTextDigest? = nil) {
        if self.declaration == declaration {
            if let digest, declaredDigest == nil { declaredDigest = digest }
            return
        }
        self.declaration = declaration
        declaredDigest = digest
    }

    /// Whether a row has said what this label is showing. Cheap: it never
    /// hashes and never checks the declaration is still true.
    var isContentDeclared: Bool { declaration != nil }

    /// Nil until a row has declared this label's content, and nil again the
    /// moment the label can see that the declaration is no longer true. Nil
    /// means the shared stores are neither read nor written, which costs a text
    /// layout and can never hand another row a wrong height.
    ///
    /// The declaration is checked here rather than dropped on
    /// `invalidateIntrinsicContentSize`, because AppKit invalidates a label for
    /// reasons that change nothing — being inserted into a window is enough —
    /// and dropping it there turned the shared stores off for the first
    /// measurement of every row that scrolled in, which is the whole cost this
    /// cache exists to remove. What the non-settling relayout actually does is
    /// write a font through the cell, and that is caught exactly below rather
    /// than inferred from an invalidation whose cause is unknown.
    var contentDigest: TranscriptTextDigest? {
        guard let declaration else { return nil }
        // The cell's font is what wraps a plain message, so a write to it is
        // checked. It is not what wraps a reply: the parse puts a font on every
        // run of the attributed string, and a reply's label is never given a
        // font of its own — it still reports AppKit's unresolved default.
        let fontIsStillTheDeclaredOne = declaration.kind == .markdown
            || (super.font.map { $0.pointSize == declaration.fontSize && $0.fontName == declaration.fontName } ?? false)
        guard fontIsStillTheDeclaredOne, super.stringValue.utf16.count == declaration.renderedLength else {
            // Whatever wrote through the cell, this label is no longer showing
            // what its row said it was. Stop reading and stop writing.
            self.declaration = nil
            declaredDigest = nil
            return nil
        }
        if let declaredDigest { return declaredDigest }
        let digest = TranscriptTextDigest.make(declaration)
        declaredDigest = digest
        return digest
    }

    /// Whether a height measured now is worth keeping for the rows that come
    /// after this one.
    ///
    /// Dragging the window edge proposes a new width every frame: the transcript
    /// column follows the window until it reaches its 880 pt cap, and the snapped
    /// width steps by a point on a 1x screen and half a point on a Retina one, so
    /// a one-to-three-second drag walks sixty to several hundred distinct widths
    /// and every realized row measures at each of them. Those heights are worth
    /// computing — the frame has to be drawn — and worth keeping in this label's
    /// own map, which is small and dies with the row. They are not worth writing
    /// into a store shared with every other row and evicted oldest-first, where
    /// one drag throws out the heights the rows above were read at in favour of
    /// widths nothing will ever ask for again. `inLiveResize` covers a row that
    /// scrolls in mid-drag, which never receives the notification below.
    var sharesMeasurementsWithOtherRows: Bool { !isInsideALiveResize && !inLiveResize }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isInsideALiveResize = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isInsideALiveResize = false
        // The rows on screen during the drag measured at the resting width like
        // every other row, but kept it to themselves; without this the store
        // learns that width only from rows realized after the drag, and each of
        // these pays a full text layout again when it is scrolled back to.
        if let held = measurementHeldForRest {
            SharedTranscriptTextCaches.remember(held.height, for: held.key)
            measurementHeldForRest = nil
        }
    }

    /// Keeps a height the drag refused to share, for the one width that turns
    /// out to be the resting one. Only the newest is kept: the widths before it
    /// are the ones the edge passed through, which nothing will ask for again.
    func holdMeasurementUntilTheEdgeStops(_ height: CGFloat, key: SharedTranscriptTextCaches.MeasurementKey) {
        measurementHeldForRest = (key, height)
    }

    func cachedMeasuredHeight(forSnappedWidth width: CGFloat) -> CGFloat? {
        measuredHeights[width]
    }

    func rememberMeasuredHeight(_ height: CGFloat, forSnappedWidth width: CGFloat) {
        // A live window resize proposes a new width every frame; keep this a
        // small map of the widths a transcript column actually rests at rather
        // than every width it passed through.
        if measuredHeights.count >= 32 { measuredHeights.removeAll(keepingCapacity: true) }
        measuredHeights[width] = height
    }

    /// Everything that can change a measured height ends here: the text, the
    /// attributed text and the font written below, a backing-scale or
    /// appearance change, and AppKit's own invalidation, which is the path a
    /// cell-level font write takes and therefore the one that catches the
    /// non-settling relayout the property overrides cannot see.
    private func discardMeasurements() {
        if !measuredHeights.isEmpty { measuredHeights.removeAll(keepingCapacity: true) }
        if !appKitIntrinsicSizes.isEmpty { appKitIntrinsicSizes.removeAll(keepingCapacity: true) }
        // A reply still arriving changes its text mid-drag. Sharing the height
        // held for it would hand every other row an answer for text this label
        // is no longer showing.
        measurementHeldForRest = nil
    }

    /// Everything above, and the claim about what this label is showing. Used
    /// by the three writes that genuinely replace the text or the font; the
    /// row's next update pass declares again.
    private func discardMeasurementsAndDeclaration() {
        discardMeasurements()
        declaration = nil
        declaredDigest = nil
    }

    override var stringValue: String {
        get { super.stringValue }
        set { super.stringValue = newValue; discardMeasurementsAndDeclaration() }
    }

    override var attributedStringValue: NSAttributedString {
        get { super.attributedStringValue }
        set { super.attributedStringValue = newValue; discardMeasurementsAndDeclaration() }
    }

    override var font: NSFont? {
        get { super.font }
        set { super.font = newValue; discardMeasurementsAndDeclaration() }
    }

    /// A move between a Retina and a 1x screen changes which widths the label
    /// snaps to, and a dynamic-type or appearance change can change its metrics.
    /// Both keep the declaration: neither a screen nor a colour scheme changes
    /// which characters this label holds, and both fire when a view is inserted
    /// into a window — the moment a row scrolls in. Both the backing scale and
    /// the appearance are components of the shared key instead of reasons to
    /// clear it, so only this label's own measurements go.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        discardMeasurements()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        discardMeasurements()
    }

    /// Diagnostics: who asks this label to recompute its size, and how often.
    override func invalidateIntrinsicContentSize() {
        // `followFrameWidth` below invalidates by writing `preferredMaxLayoutWidth`,
        // which changes no character and no metric: what was measured is still
        // true, and both maps are keyed by a width, so the write only changes
        // which key is read. Every other invalidation is taken at face value,
        // which is what catches a cell-level write the properties cannot see.
        if !isFollowingFrameWidth { discardMeasurements() }
        if LayoutStormCounters.isEnabled {
            invalidations += 1
            // Symbolicating a stack is expensive even once in forty; it never
            // runs unless the diagnostics are switched on.
            LayoutStormCounters.hit(
                "label.invalidateIntrinsic",
                detail: invalidations % 40 == 1 ? LayoutStormBacktrace.short() : nil
            )
        }
        super.invalidateIntrinsicContentSize()
    }

    override func layout() {
        LayoutStormCounters.hit("label.layout")
        super.layout()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin {
            LayoutStormCounters.hit(
                "label.setFrameOrigin",
                detail: "chars=\(stringValue.count) y \(Int(frame.origin.y))->\(Int(newOrigin.y))"
            )
        }
        super.setFrameOrigin(newOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        LayoutStormCounters.hit(
            "label.setFrameSize",
            detail: "\(newSize.width)x\(newSize.height) was \(frame.width)x\(frame.height)"
        )
        super.setFrameSize(newSize)
        followFrameWidth()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        followFrameWidth()
    }

    private func followFrameWidth() {
        let width = alignmentRect(forFrame: bounds).width
        guard width.isFinite, width > 0, abs(preferredMaxLayoutWidth - width) > 0.25 else { return }
        isFollowingFrameWidth = true
        preferredMaxLayoutWidth = width
        isFollowingFrameWidth = false
    }

    /// AppKit's own answer, for diagnostics: it wraps at `preferredMaxLayoutWidth`
    /// with cell metrics that can differ by a line from `measuredSize` at the same width.
    /// Deliberately uncached, so the cost of AppKit's own layout stays measurable.
    var appKitIntrinsicContentSize: NSSize { super.intrinsicContentSize }

    /// AppKit's answer, remembered. `super.intrinsicContentSize` is a second
    /// complete text layout beside our own (46 ms against 49 ms for a
    /// six-kilobyte reply), and it answers the same for as long as the text, the
    /// font and `preferredMaxLayoutWidth` are unchanged. The first two are what
    /// `discardMeasurements` watches; the third is the key.
    private var rememberedAppKitIntrinsicContentSize: NSSize {
        let preferredWidth = preferredMaxLayoutWidth
        if let size = appKitIntrinsicSizes[preferredWidth] { return size }
        let size = super.intrinsicContentSize
        if appKitIntrinsicSizes.count >= 32 { appKitIntrinsicSizes.removeAll(keepingCapacity: true) }
        appKitIntrinsicSizes[preferredWidth] = size
        return size
    }

    /// SwiftUI sizes this label through `measuredSize`. Report the same height
    /// for the width the label actually has, so AppKit and SwiftUI can never hold
    /// two different heights for one label and a lazy stack cannot alternate
    /// between them. The width stays AppKit's (bounded by the preferred width).
    override var intrinsicContentSize: NSSize {
        let base = rememberedAppKitIntrinsicContentSize
        let width = alignmentRect(forFrame: bounds).width
        guard width.isFinite, width > 0 else { return base }
        return NSSize(width: base.width, height: StableSelectableText.measuredSize(proposedWidth: width, field: self).height)
    }
}

/// Diagnostics only. A label measured hundreds of times within one second is a
/// layout loop; this writes one bounded line per second with the numbers that
/// decide wrapping (never the text), so a live loop names its cause in the log.
@MainActor
enum LayoutStormDiagnostics {
    /// Off with the rest of the layout diagnostics: `record` runs inside every
    /// measurement, and the measurement is the transcript's hot path.
    static var isEnabled = LayoutDiagnosticsDefault.isEnabled
    static let threshold = 400
    static let maximumLines = 40
    private struct FieldStats {
        var measurements = 0
        var proposals: Set<CGFloat> = []
        var frameWidths: Set<CGFloat> = []
        var heights: Set<CGFloat> = []
        var chars = 0
    }
    private static var windowStart: TimeInterval = 0
    private static var count = 0
    private static var fields: [ObjectIdentifier: FieldStats] = [:]
    private static var loggedThisWindow = false
    private static var linesWritten = 0

    static func record(proposedWidth: CGFloat, measured: CGSize, field: NSTextField) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - windowStart >= 1 { windowStart = now; count = 0; fields = [:]; loggedThisWindow = false }
        count += 1
        var stats = fields[ObjectIdentifier(field)] ?? FieldStats()
        stats.measurements += 1
        if stats.proposals.count < 6 { stats.proposals.insert(proposedWidth) }
        if stats.frameWidths.count < 6 { stats.frameWidths.insert(field.frame.width) }
        if stats.heights.count < 6 { stats.heights.insert(measured.height) }
        stats.chars = field.stringValue.count
        fields[ObjectIdentifier(field)] = stats
        guard count >= threshold, !loggedThisWindow, linesWritten < maximumLines else { return }
        loggedThisWindow = true; linesWritten += 1
        func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        func list(_ values: Set<CGFloat>) -> String { values.sorted().map(f).joined(separator: "/") }
        let scale = field.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 0
        let top = fields.values.sorted { $0.measurements > $1.measurements }.prefix(5).map { stats in
            "[n=\(stats.measurements) chars=\(stats.chars) proposals=\(list(stats.proposals)) frames=\(list(stats.frameWidths)) heights=\(list(stats.heights))]"
        }.joined(separator: " ")
        AgenticDiagnosticsLog.note("layout", "measure storm: \(count)+ measurements this second over \(fields.count) labels; scale=\(f(scale)); top: \(top)")
    }
}

/// Diagnostics: a few caller names from the current stack, without addresses.
enum LayoutStormBacktrace {
    static func short(depth: Int = 9) -> String {
        Thread.callStackSymbols.dropFirst(3).prefix(depth).map { line -> String in
            // "3   AppKit   0x000000019... -[NSTextField setFont:] + 120" → "-[NSTextField setFont:]"
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 3 else { return String(line.suffix(40)) }
            let symbol = parts.dropFirst(3).joined(separator: " ")
            return String(symbol.split(separator: "+").first ?? Substring(symbol)).trimmingCharacters(in: .whitespaces).prefix(60).description
        }.joined(separator: " < ")
    }
}
