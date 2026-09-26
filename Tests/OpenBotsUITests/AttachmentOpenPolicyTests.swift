import Foundation
@testable import OpenBotsUI
import Testing

@Suite("Open on a chip never runs what a bot wrote")
struct AttachmentOpenPolicyTests {
    @Test("Documents and images open; applications, scripts, commands, images of disks and installers do not",
          arguments: [
            ("public.plain-text", "notes.txt", true), ("public.png", "chart.png", true), ("com.adobe.pdf", "report.pdf", true),
            ("public.comma-separated-values-text", "data.csv", true), ("public.zip-archive", "bundle.zip", true),
            ("com.apple.application-bundle", "Helper.app", false), ("public.shell-script", "run.sh", false),
            ("public.python-script", "tool.py", false), ("com.apple.disk-image", "Installer.dmg", false),
            ("com.apple.installer-package-archive", "Setup.pkg", false), ("public.unix-executable", "bin", false),
            (nil, "cleanup.command", false), (nil, "Helper.app", false), (nil, "script.scpt", false),
            (nil, "job.workflow", false), (nil, "notes.md", true), (nil, "run.jar", false),
            (nil, "Profile.mobileconfig", false), (nil, "Thing.prefpane", false), (nil, "link.webloc", false),
            (nil, "site.url", false), (nil, "Helper.appex", false)
          ] as [(String?, String, Bool)])
    func decides(typeIdentifier: String?, filename: String, expected: Bool) {
        #expect(AttachmentOpenPolicy.mayOpen(typeIdentifier: typeIdentifier, filename: filename) == expected, "\(filename)")
    }

    @Test("Open hands out a copy under the file's own name, in a folder of its own, replaced each time")
    func copyForOpening() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OpenBotsNextOpenTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blob = root.appending(path: "0123.blob")
        try Data("hello".utf8).write(to: blob)
        let copy = try AttachmentOpenPolicy.copyForOpening(of: blob, named: "report: draft/final.pdf", id: "0123-abcd", in: root.appending(path: "Open"))
        #expect(copy.lastPathComponent == "report- draft-final.pdf")
        #expect(copy.deletingLastPathComponent().lastPathComponent == "0123-abcd")
        #expect(try Data(contentsOf: copy) == Data("hello".utf8))
        try Data("hello again".utf8).write(to: blob)
        let again = try AttachmentOpenPolicy.copyForOpening(of: blob, named: "report: draft/final.pdf", id: "0123-abcd", in: root.appending(path: "Open"))
        let replaced = try Data(contentsOf: again)
        #expect(again == copy && replaced == Data("hello again".utf8))
        // A name of dots never resolves to the folder or its parent.
        for dots in [".", "..", "..."] {
            let odd = try AttachmentOpenPolicy.copyForOpening(of: blob, named: dots, id: "0123-abcd", in: root.appending(path: "Open"))
            #expect(odd.lastPathComponent == "attachment" && odd.deletingLastPathComponent().lastPathComponent == "0123-abcd", "\(dots)")
        }
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Open/0123-abcd/report- draft-final.pdf").path))
    }
}
