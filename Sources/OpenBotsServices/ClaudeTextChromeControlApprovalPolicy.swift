import Foundation
import OpenBotsDomain
import OpenBotsRuntime

/// One tab of the user's Chrome, as Chrome itself described it just before a card
/// went up. The title and the address are the page's own words, so they are
/// only ever shown, bounded and on one line, never trusted.
public struct ChromeTab: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let address: String

    public init(id: Int, title: String, address: String) {
        self.id = id; self.title = title; self.address = address
    }
}

/// What the app found when it asked the user's Chrome about one tab.
public enum ChromeTabLookup: Equatable, Sendable {
    case found(ChromeTab)
    /// Chrome answered, and no tab has that number now.
    case noSuchTab
    /// Chrome did not answer in time: most often because macOS is still asking
    /// the user whether OpenBots Next may control it.
    case unanswered
    /// macOS refused OpenBots Next control of Chrome (the user said no, or turned it
    /// off in System Settings).
    case notAllowed
    /// Chrome answered with something this could not read.
    case unreadable
}

/// What the app knew of the user's Chrome when a card went up, checked again
/// when they approve: the same Chrome process, and for a tab card
/// the same tab still on the site the card named.
public struct ChromeCardAnchor: Equatable, Sendable {
    public let processID: Int32
    public let tab: ChromeTab?

    public init(processID: Int32, tab: ChromeTab?) { self.processID = processID; self.tab = tab }
}

/// What the card for one Control Chrome call needs to know beyond the call.
public struct ChromeControlContext: Equatable, Sendable {
    /// The user's own Chrome is running as an app they can see. The Browser connector's
    /// headless Chrome is the same app bundle but runs in the background, and
    /// does not count.
    public var chromeIsOpen: Bool { processID != nil }
    /// That Chrome's process, or nil while it is closed.
    public var processID: Int32?
    /// The tab a tab tool named, looked up in the user's Chrome; nil for a call that
    /// names no tab.
    public var tab: ChromeTabLookup?
    /// The bot's web access is on (the only door out).
    public var grantsWeb: Bool

    public init(processID: Int32?, tab: ChromeTabLookup? = nil, grantsWeb: Bool) {
        self.processID = processID; self.tab = tab; self.grantsWeb = grantsWeb
    }

    public init(chromeIsOpen: Bool, tab: ChromeTabLookup? = nil, grantsWeb: Bool) {
        self.init(processID: chromeIsOpen ? 1 : nil, tab: tab, grantsWeb: grantsWeb)
    }

    /// What the card stands on, for the check at approval.
    public var anchor: ChromeCardAnchor? {
        guard let processID else { return nil }
        if case .found(let tab) = tab { return ChromeCardAnchor(processID: processID, tab: tab) }
        return ChromeCardAnchor(processID: processID, tab: nil)
    }
}

/// What the card says when a bot wants to use the user's Chrome, through the
/// Claude Desktop extension "Control Chrome" (0.1.6).
///
/// A bot never acts in the user's Chrome on its own. Every call, reads
/// included, is a card, and no card offers "allow
/// for this reply". The script tool is not offered in this version, and without
/// it the extension has no way to click, so nothing can be submitted.
///
/// Every value is read here the way the extension's `server/index.js` reads it,
/// and whatever it would read differently is refused rather than shown:
/// - a tab number goes through `parseInt(x, 10)`, which takes `12.7` and
///   `"12abc"` as 12 and `1e21` as 1, so only a whole number or a string of
///   digits is taken;
/// - a tab number of 0, or none, is falsy there and acts on whichever tab is in
///   front, which the user's click can change after the card, so both are refused;
/// - `new_tab` defaults to true and is read for truthiness, so `0` or `false`
///   replace the user's front tab and `"false"` opens a new one: only true or nothing;
/// - `list_tabs` takes a `window_id` and never reads it, so it is refused
///   rather than let the bot think it narrowed anything;
/// - a tool this review never saw is refused: a later version is not the
///   reviewed copy and does not launch, and the policy does not rely on that.
public enum ClaudeTextChromeControlApprovalPolicy {
    static let openTool = "open_url"
    static let scriptTool = "execute_javascript"
    static let listTool = "list_tabs"
    static let frontTool = "get_current_tab"
    /// The tools that act on one tab, by its number, and what each does.
    static let tabTools: [String: (title: String, verb: String)] = [
        "get_page_content": ("Read a page in your Chrome", "read every word on"),
        "close_tab": ("Close a tab in your Chrome", "close"),
        "switch_to_tab": ("Bring a Chrome tab to the front", "bring to the front of your screen"),
        "reload_tab": ("Reload a tab in your Chrome", "reload"),
        "go_back": ("Go back in a Chrome tab", "go back one page in"),
        "go_forward": ("Go forward in a Chrome tab", "go forward one page in"),
    ]
    /// Chrome writes tab numbers of about ten digits; fifteen keeps JavaScript
    /// printing the number plainly, which `parseInt` then reads whole.
    static let maximumTabID = 999_999_999_999_999
    /// Short enough that the card's whole detail, address last, fits the
    /// approvals record's 2,000 characters.
    static let maximumAddressScalars = 1_500

    static let refusalActivity = "Blocked a Chrome call that could not be shown exactly"
    static let notOpenReason = "Google Chrome is not open on the user's Mac, and a bot never starts it. Ask the user to open "
        + "Chrome, then try again. Nothing was done."
    static let notOpenActivity = "Blocked a Chrome call: Chrome was not open"
    static let scriptReason = "Running scripts in the user's Chrome is not offered in this version of OpenBots Next. "
        + "Use get_page_content to read a page, by its tab number. Nothing was run."
    static let scriptActivity = "Blocked running a script in Chrome (not offered)"
    static let noWebReason = "Opening an address in the user's Chrome needs your web access, and it is off for you. "
        + "Nothing was opened."
    static let noWebActivity = "Blocked opening an address in Chrome: web access is off"
    static let unansweredReason = "The user's Chrome did not answer in time, so the tab could not be named on a card. If "
        + "macOS is asking the user whether OpenBots Next may control Google Chrome, they must answer that first; then "
        + "try again. Nothing was done."
    static let unansweredActivity = "Blocked a Chrome call: Chrome did not answer in time"
    static let notAllowedReason = "macOS does not let OpenBots Next control Google Chrome, so the tab could not be "
        + "named on a card. The user can allow it in System Settings, Privacy & Security, Automation, under OpenBots "
        + "Next. Nothing was done."
    static let notAllowedActivity = "Blocked a Chrome call: OpenBots Next may not control Chrome"
    static let unreadableReason = "The user's Chrome's answer about that tab could not be read, so the tab could not be "
        + "named on a card. Nothing was done."
    static let unknownToolActivity = "Blocked a Chrome tool this version never reviewed"
    /// Said when the user approves a card whose tab moved to another site, or whose
    /// Chrome was quit and started again, since it went up.
    public static let changedReason = "The tab changed after the card went up: it no longer shows the site the "
        + "card named, or Chrome was restarted. Nothing was done. List the tabs again and ask again."
    public static let changedActivity = "Blocked a Chrome call: the tab changed before the approval"
    static let secretRefusal = "This address carries something the user gave as a secret earlier in this turn, "
        + "and opening it would hand it to the site. Nothing was opened. Never put a secret the user gave you into an "
        + "address."
    static let secretActivity = "Blocked opening an address that carried a secret you gave"
    /// Said on every card, because it is what makes this connector different:
    /// the bot acts in the user's own browser.
    static let signedIn = "This is your own Chrome, signed in to your sites."

    /// The tab number a call names, read as the extension reads it, or nil when
    /// the call names none, or one the card cannot show exactly, or carries a
    /// field the tool does not take: only a call that would become a card is
    /// looked up in the user's Chrome.
    public static func requestedTabID(_ request: ClaudeTextPermissionRequest) -> Int? {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        guard tabTools[tool] != nil,
              let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any],
              unexpectedField(input, allowed: ["tab_id"]) == nil,
              case .success(let id) = tabID(input["tab_id"]) else { return nil }
        return id
    }

    enum TabIDReading: Equatable { case success(Int), missing, notExact }

    static func tabID(_ value: Any?) -> TabIDReading {
        guard let value, !(value is NSNull) else { return .missing }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return .notExact }
            let double = number.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double,
                  double >= 1, double <= Double(maximumTabID) else { return .notExact }
            return .success(Int(double))
        }
        if let string = value as? String {
            guard (1...15).contains(string.utf8.count), string.utf8.allSatisfy({ (48...57).contains($0) }),
                  let id = Int(string), id >= 1 else { return .notExact }
            return .success(id)
        }
        return .notExact
    }

    /// An address the card can show exactly and the extension will open as
    /// shown: `http` or `https`, a host, no user or password, one line, no
    /// character the card would draw as nothing, bounded.
    static func address(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let scalars = Array(string.unicodeScalars)
        guard (1...maximumAddressScalars).contains(scalars.count),
              !scalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || $0 == "\"" || $0 == "\\" }),
              AppleMessagesSendProposal.firstRefused(in: scalars) == nil,
              // Every percent sign starts a sequence that decodes, so the
              // secret check below can read the address whole (one bad
              // sequence would make the whole decode nil).
              string.removingPercentEncoding != nil,
              let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              string.lowercased().hasPrefix(scheme + "://"),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return string
    }

    /// The host of an address, for the card's target line.
    public static func host(of address: String) -> String {
        URLComponents(string: address)?.host ?? address
    }

    /// What must not change between a tab's card and the user's Approve: the site
    /// of a web page, or the whole address, less its fragment, of a page with
    /// no site. Every file has the same empty host, so a host alone let one
    /// file stand for another.
    public static func place(of address: String) -> String {
        guard var components = URLComponents(string: address) else { return address }
        let scheme = components.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" { return (components.host ?? "").lowercased() }
        components.fragment = nil
        return components.string ?? address
    }

    /// A tab as the card names it: the site first, since a page chooses its
    /// own title and can make it say anything. A page with no site (a file,
    /// a Chrome page) is named by what it shows, never by its tab number,
    /// which the user cannot recognise.
    static func named(_ tab: ChromeTab) -> (line: String, target: String, place: String) {
        let components = URLComponents(string: tab.address)
        let scheme = components?.scheme?.lowercased() ?? ""
        let host = components?.host ?? ""
        let site = scheme == "http" || scheme == "https"
            ? ClaudeTextAppleMailSendApprovalPolicy.fragment(host, 80) : ""
        let title = ClaudeTextAppleMailSendApprovalPolicy.fragment(tab.title, 120)
        let address = ClaudeTextAppleMailSendApprovalPolicy.fragment(tab.address, 300)
        let target = !site.isEmpty ? site
            : scheme == "file" ? "a file on this Mac"
            : ["chrome", "about", "chrome-untrusted", "devtools"].contains(scheme) ? "a Chrome page"
            : "a page with no site"
        let place = site.isEmpty ? "showing \(target)" : "on \(site)"
        return ("the tab \(place), titled “\(title)” (\(address))", target, place)
    }

    static func card(title: String, detail: String, target: String, kind: ConsequentialActionKind,
                     activity: String) -> ClaudeTextWorkCard {
        // No turn scope: every Chrome call asks, every time.
        ClaudeTextWorkCard(title: title, detail: detail, target: target, kind: kind, activity: activity,
                           turnScope: nil, offersTurnAllowance: false)
    }

    static func deny(_ reason: String, _ activity: String) -> ClaudeTextWorkDecision {
        .denyQuietly(reason: reason, activity: activity)
    }

    /// Refuses any field the tool does not take, compared scalar for scalar as
    /// the extension's JavaScript compares them.
    static func unexpectedField(_ input: [String: Any], allowed: [String]) -> String? {
        input.keys.sorted().first { key in !allowed.contains { $0.unicodeScalars.elementsEqual(key.unicodeScalars) } }
    }

    static func shown(_ field: String) -> String {
        field.unicodeScalars.prefix(40).map { scalar in
            (0x21...0x7E).contains(scalar.value) ? String(scalar) : String(format: "U+%04X", scalar.value)
        }.joined()
    }

    public static func decide(_ request: ClaudeTextPermissionRequest, botName: String,
                              context: ChromeControlContext) -> ClaudeTextWorkDecision {
        let tool = ClaudeTextConnectorApprovalPolicy.toolName(in: request.toolName)
        let bot = ClaudeTextAppleMailSendApprovalPolicy.fragment(botName, 60)
        if tool == scriptTool { return deny(scriptReason, scriptActivity) }
        guard context.chromeIsOpen else { return deny(notOpenReason, notOpenActivity) }
        guard let input = (try? JSONSerialization.jsonObject(with: request.inputJSON)) as? [String: Any] else {
            return deny("The call's details could not be read, so they cannot be shown on a card. Nothing was done.",
                        refusalActivity)
        }
        switch tool {
        case openTool:
            if let extra = unexpectedField(input, allowed: ["url", "new_tab"]) {
                return deny("`\(shown(extra))` is not a field of open_url: it takes only url and new_tab. Nothing "
                    + "was opened.", refusalActivity)
            }
            if let flag = input["new_tab"] {
                guard let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
                      number.boolValue else {
                    return deny("open_url opens a new tab only: leave new_tab out, or set it to true. Replacing the "
                        + "page in the user's front tab is not offered, since they may be using it. Nothing was opened.",
                        refusalActivity)
                }
            }
            guard let address = address(input["url"]) else {
                return deny("The address must be one http or https address with a site, at most "
                    + "\(maximumAddressScalars) characters, no spaces, quotes or hidden characters, and no user "
                    + "name or password in it, so the card can show exactly what opens. Nothing was opened.",
                    refusalActivity)
            }
            guard context.grantsWeb else { return deny(noWebReason, noWebActivity) }
            let site = ClaudeTextAppleMailSendApprovalPolicy.fragment(host(of: address), 80)
            // The address is shown whole and never blanked: it is exactly what
            // the user's Chrome will send to the site (the text card's rule).
            return .ask(card(
                title: "Open a page in your Chrome",
                detail: "\(bot) wants to open this address in a new tab. \(signedIn) The site sees your "
                    + "sign-in and everything in the address."
                    + ClaudeTextAppleMessagesApprovalPolicy.headingSeparator + address,
                target: site, kind: .send, activity: "Asked to open \(site) in your Chrome"))
        case listTool:
            if let extra = unexpectedField(input, allowed: []) {
                return deny("`\(shown(extra))` is not read by list_tabs: it always lists every tab in every window. "
                    + "Call it with no fields. Nothing was done.", refusalActivity)
            }
            return .ask(card(
                title: "See your Chrome tabs",
                detail: "\(bot) wants to see the address and title of every tab open in your Chrome, in every "
                    + "window. \(signedIn)",
                target: "every Chrome tab", kind: .metadataMutation, activity: "Asked to see your Chrome tabs"))
        case frontTool:
            if let extra = unexpectedField(input, allowed: []) {
                return deny("`\(shown(extra))` is not a field of get_current_tab: it takes none. Nothing was done.",
                            refusalActivity)
            }
            return .ask(card(
                title: "See your front Chrome tab",
                detail: "\(bot) wants to see the address and title of the tab in front in your Chrome. \(signedIn)",
                target: "the front Chrome tab", kind: .metadataMutation,
                activity: "Asked to see your front Chrome tab"))
        default:
            guard let words = tabTools[tool] else {
                // Whatever a later version may add: a later version is not the
                // reviewed one and does not launch, but the policy does not rely
                // on that, and a tool nobody read is never put to the user.
                return deny("\(shown(tool)) is not offered by OpenBots Next in your Chrome. Nothing was done.",
                            unknownToolActivity)
            }
            if let extra = unexpectedField(input, allowed: ["tab_id"]) {
                return deny("`\(shown(extra))` is not a field of \(tool): it takes only tab_id. Nothing was done.",
                            refusalActivity)
            }
            let id: Int
            switch tabID(input["tab_id"]) {
            case .success(let found): id = found
            case .missing:
                return deny("Name the tab by its number: list the tabs first, then call \(tool) with tab_id. "
                    + "Without one it acts on whichever tab is in front, which can change after the user approves. "
                    + "Nothing was done.", refusalActivity)
            case .notExact:
                return deny("tab_id must be a whole number from the tab list, written as a number or as digits "
                    + "only. Nothing was done.", refusalActivity)
            }
            switch context.tab {
            case .found(let tab) where tab.id == id:
                let named = named(tab)
                let extra = tool == "switch_to_tab"
                    ? " Chrome comes to the front of your screen, over what you are doing." : ""
                return .ask(card(
                    title: words.title,
                    detail: "\(bot) wants to \(words.verb) \(named.line). \(signedIn)\(extra) The card names "
                        + "the tab as it was a moment ago. If the tab moves to another site before you approve, "
                        + "nothing is done.",
                    target: named.target, kind: .metadataMutation,
                    activity: "Asked to \(words.verb) a tab \(named.place) in your Chrome"))
            case .noSuchTab, .found:
                return deny("No tab with the number \(id) is open in the user's Chrome now. List the tabs again and use "
                    + "a number from that list. Nothing was done.", refusalActivity)
            case .unanswered, nil:
                return deny(unansweredReason, unansweredActivity)
            case .notAllowed:
                return deny(notAllowedReason, notAllowedActivity)
            case .unreadable:
                return deny(unreadableReason, unansweredActivity)
            }
        }
    }

    /// Whether an address a bot asked to open carries a secret the user gave this
    /// turn. An input that cannot be read counts: it would not become a card.
    public static func openCarriesASecret(_ inputJSON: Data, secrets: [String]) -> Bool {
        guard let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any],
              let address = address(input["url"]) else { return true }
        // Read as the site may read it: raw, percent-decoded, and with `+` as
        // a space, as a form's query writes one.
        let decoded = address.removingPercentEncoding ?? address
        let spaced = address.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? address
        return secrets.filter { $0.count >= 4 }.contains { secret in
            [address, decoded, spaced].contains { form in
                form.contains(secret) || ClaudeTextAppleMessagesApprovalPolicy.containsScalars(form, secret)
            }
        }
    }
}
