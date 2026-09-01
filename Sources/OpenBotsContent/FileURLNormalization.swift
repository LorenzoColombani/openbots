import Foundation

enum FileURLNormalization {
    /// Collapses `.` and `..` without consulting the filesystem or rewriting a
    /// physical `/private/...` path through a convenience symlink such as `/tmp`.
    static func lexical(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        var components: [String] = []
        for component in url.pathComponents {
            switch component {
            case "/", ".", "":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: url.hasDirectoryPath
        )
    }
}
