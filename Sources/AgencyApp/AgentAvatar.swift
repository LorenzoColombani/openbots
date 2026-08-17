import SwiftUI
import AgencyKit

/// Decoded-avatar cache keyed by path + mtime (review round 2, issue 2). Without
/// it, `AgentAvatar` re-read and re-decoded the file inside `body` on EVERY
/// SwiftUI pass — and the sidebar re-renders per streamed token, so a reply from
/// one agent meant N agents × refresh-rate × (file read + image decode) of
/// un-downscaled originals on the main thread. The mtime in the key keeps
/// "applies immediately" working: a new avatar changes mtime → a fresh decode.
enum AvatarCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(atPath path: String) -> NSImage? {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(mtime)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

/// An agent's avatar: the chosen image if one is set and loadable, otherwise the
/// emoji. The emoji is the always-there default — old agents, "use emoji", or any
/// load failure fall back to it, so an agent never renders blank.
struct AgentAvatar: View {
    let agent: Agent
    var size: CGFloat = 28

    var body: some View {
        if let path = agent.avatarPath, let img = AvatarCache.image(atPath: path) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        } else {
            Text(agent.emoji)
                .font(.system(size: size * 0.82))
                .frame(width: size, height: size)
        }
    }
}

/// A team's face (R3): its emoji (👥 default) in a tinted circle — visually a
/// GROUP, never mistakable for one agent's photo.
struct TeamAvatar: View {
    let team: Team
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.14))
            Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            Text(team.emoji ?? "👥")
                .font(.system(size: size * 0.55))
        }
        .frame(width: size, height: size)
    }
}
