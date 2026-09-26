import Foundation

/// Where this module's own shipped files are, in both build systems.
///
/// SwiftPM generates `Bundle.module`; the app is built from the committed Xcode
/// project, where the same files sit in the framework's own bundle and are
/// found through a class in it. Two servers ship this way — the fence proxy and
/// the mail sender — and one lookup keeps them from drifting apart.
enum ServicesResourceBundle {
    private final class Marker: NSObject {}

    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: Marker.self)
        #endif
    }

    static func url(forResource name: String, withExtension extension: String) -> URL? {
        bundle.url(forResource: name, withExtension: `extension`)
    }
}
