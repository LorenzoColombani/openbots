import Foundation
import UniformTypeIdentifiers

/// Whether "Open" may hand a saved attachment to its usual app. A file a bot
/// wrote must never run as the user on one click: applications, scripts,
/// shell commands, disk images and installer packages get Reveal and Save
/// only. Decided by the declared type first, then by the file name.
public enum AttachmentOpenPolicy {
    static let refusedTypes: [UTType] = [
        .executable, .applicationBundle, .application, .unixExecutable, .script, .shellScript, .appleScript,
        .osaScript, .pythonScript, .rubyScript, .perlScript, .phpScript, .javaScript, .diskImage,
        UTType("com.apple.installer-package-archive"), UTType("com.apple.automator-workflow"),
        UTType("com.apple.terminal.shell-script"), UTType("com.sun.java-archive"), UTType("com.microsoft.windows-executable")
    ].compactMap { $0 }
    static let refusedExtensions: Set<String> = ["app", "command", "sh", "zsh", "bash", "fish", "scpt", "scptd", "applescript",
        "workflow", "pkg", "mpkg", "dmg", "jar", "exe", "bat", "cmd", "ps1", "py", "rb", "pl", "php", "js", "mjs", "action", "terminal",
        "mobileconfig", "prefpane", "saver", "plugin", "kext", "qlgenerator", "appex", "xpc", "webloc", "url", "inetloc", "fileloc"]

    /// The owned copy is stored as `<id>.blob`, which no app would open as a
    /// document; Open hands out a copy under the file's own name in a folder
    /// of its own, replaced on each open. The caller fences the type first.
    public static func copyForOpening(of blob: URL, named displayName: String, id: String, in directory: URL,
                                      fileManager: FileManager = .default) throws -> URL {
        let safeName = displayName.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        var name = String(String(safeName).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        // A name of dots would resolve to the folder or its parent; never that.
        if name.allSatisfy({ $0 == "." }) { name = "" }
        let folder = directory.appending(path: id.filter { $0.isLetter || $0.isNumber || $0 == "-" }, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = folder.appending(path: name.isEmpty ? "attachment" : name)
        if fileManager.fileExists(atPath: copy.path) { try fileManager.removeItem(at: copy) }
        try fileManager.copyItem(at: blob, to: copy)
        return copy
    }

    public static func mayOpen(typeIdentifier: String?, filename: String?) -> Bool {
        if let identifier = typeIdentifier, let type = UTType(identifier) {
            if refusedTypes.contains(where: { type.conforms(to: $0) }) { return false }
        }
        if let filename {
            let ext = (filename as NSString).pathExtension.lowercased()
            if refusedExtensions.contains(ext) { return false }
            if let type = UTType(filenameExtension: ext), refusedTypes.contains(where: { type.conforms(to: $0) }) { return false }
        }
        return true
    }
}
