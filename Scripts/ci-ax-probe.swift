// CI probe: does a plain SwiftUI Button hosted in AppKit report AXButton, and does text render to
// pixels, on this runner? Mirrors the technique of the OpenBotsUITests that fail on macos-15
// (NSHostingController + layoutSubtreeIfNeeded + NSButton descendants + cacheDisplay bitmap).
// Run: swift Scripts/ci-ax-probe.swift
import AppKit
import SwiftUI

extension NSView {
    var probeDescendants: [NSView] { subviews + subviews.flatMap(\.probeDescendants) }
}

func brightPixels(_ view: NSView) -> (bright: Int, total: Int) {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return (-1, 0) }
    view.cacheDisplay(in: view.bounds, to: rep)
    var bright = 0
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                if c.alphaComponent > 0.5, lum > 0.6 || lum < 0.25 { bright += 1 }  // any non-mid pixel: text drew
            }
            x += 2
        }
        y += 2
    }
    return (bright, (w / 2) * (h / 2))
}

func describeButtons(_ host: NSView, label: String) {
    let buttons = host.probeDescendants.compactMap { $0 as? NSButton }
    print("[\(label)] NSButton descendants: \(buttons.count)")
    for b in buttons {
        let role = b.accessibilityRole().map { $0.rawValue } ?? "nil"
        print("[\(label)]   class=\(type(of: b)) title='\(b.title)' axLabel='\(b.accessibilityLabel() ?? "nil")' axRole=\(role) isAXElement=\(b.isAccessibilityElement()) axChildren=\(b.accessibilityChildren()?.count ?? -1) frame=\(NSStringFromRect(b.frame))")
    }
    let controls = host.probeDescendants.compactMap { $0 as? NSControl }
    print("[\(label)] NSControl descendants: \(controls.count); classes: \(Set(controls.map { String(describing: type(of: $0)) }).sorted())")
}

_ = NSApplication.shared
let os = ProcessInfo.processInfo.operatingSystemVersionString
print("== AX probe on \(os); screens=\(NSScreen.screens.count) mainScreen=\(NSScreen.main != nil)")
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
print("== window-server session: \(session == nil ? "NONE (headless)" : "present") keys=\(session?.keys.sorted().joined(separator: ",") ?? "-")")
print("== NSApp activationPolicy=\(NSApp.activationPolicy().rawValue) isActive=\(NSApp.isActive)")
print("== AX enabled (AXIsProcessTrusted)=\(AXIsProcessTrusted())")

struct Probe: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Settings").font(.title)
            Button("Probe Button") {}
            Button("Second Probe") {}.disabled(true)
        }.padding(20).frame(width: 320)
    }
}

// 1. Off-screen host, exactly like the tests.
let controller = NSHostingController(rootView: Probe())
let host = controller.view
host.frame = CGRect(x: 0, y: 0, width: 320, height: 200)
for _ in 0..<3 {
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
describeButtons(host, label: "offscreen")
let px1 = brightPixels(host)
print("[offscreen] bitmap: bright=\(px1.bright) of \(px1.total) sampled")

// 2. Same view inside a real, ordered-front window.
let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let controller2 = NSHostingController(rootView: Probe())
window.contentViewController = controller2
window.makeKeyAndOrderFront(nil)
for _ in 0..<5 {
    controller2.view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
print("== window: isVisible=\(window.isVisible) isKey=\(window.isKeyWindow) onScreen=\(window.screen != nil) backingScale=\(window.backingScaleFactor)")
describeButtons(controller2.view, label: "in-window")
let px2 = brightPixels(controller2.view)
print("[in-window] bitmap: bright=\(px2.bright) of \(px2.total) sampled")

// 3. Control: a raw AppKit NSButton, no SwiftUI — detached, then inside the window, then after
//    the app has finished launching. Separates "SwiftUI" from "no running app" from "no window".
func rawRole(_ b: NSButton) -> String { b.accessibilityRole().map { $0.rawValue } ?? "nil" }
let raw = NSButton(title: "Raw AppKit", target: nil, action: nil)
print("[raw NSButton detached] axRole=\(rawRole(raw)) isAXElement=\(raw.isAccessibilityElement())")
raw.frame = CGRect(x: 10, y: 10, width: 120, height: 24)
window.contentView?.addSubview(raw)
window.contentView?.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
print("[raw NSButton in-window] axRole=\(rawRole(raw)) isAXElement=\(raw.isAccessibilityElement())")
NSApp.setActivationPolicy(.regular)
NSApp.finishLaunching()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
print("[raw NSButton after finishLaunching] axRole=\(rawRole(raw)) isAXElement=\(raw.isAccessibilityElement())")
describeButtons(controller2.view, label: "in-window after finishLaunching")
print("== done")
