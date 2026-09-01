import AppKit
import OpenBotsDomain
import SwiftUI

/// App-owned approved artwork. The three vector paths and facial geometry are
/// copied unchanged from the accepted CharacterPreview drawing, not the old
/// generated grammar. Guide and Fin are immutable bundled transparent cutouts.
@MainActor
enum BuiltInAvatarResources {
    private final class BundleMarker: NSObject {}

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle(for: BundleMarker.self)
        #endif
    }

    static func url(for avatar: BuiltInAvatar) -> URL? {
        guard avatar == .guide || avatar == .fin else { return nil }
        return resourceBundle.url(forResource: "\(avatar.rawValue)-face-transparent", withExtension: "png")
    }

    private static let guide = url(for: .guide).flatMap(NSImage.init(contentsOf:))
    private static let fin = url(for: .fin).flatMap(NSImage.init(contentsOf:))

    static func image(for avatar: BuiltInAvatar) -> NSImage? {
        switch avatar {
        case .guide: guide
        case .fin: fin
        case .pillow, .kite, .bean: nil
        }
    }

    static func isAvailable(_ avatar: BuiltInAvatar) -> Bool {
        switch avatar {
        case .guide, .fin: image(for: avatar) != nil
        case .pillow, .kite, .bean: true
        }
    }
}

struct BuiltInAvatarArtwork: View {
    let avatar: BuiltInAvatar
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = BuiltInAvatarResources.image(for: avatar) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .scaleEffect(avatar == .fin ? 1.4 : 1)
            } else {
                vectorArtwork
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var vectorArtwork: some View {
        BuiltInAvatarBodyShape(avatar: avatar)
            .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                BuiltInAvatarBodyShape(avatar: avatar)
                    .stroke(.primary.opacity(0.72), lineWidth: 0.85)
            }
            .overlay { eyes }
            .overlay {
                BuiltInAvatarMarkShape(avatar: avatar)
                    .fill(.white.opacity(0.96))
                    .overlay {
                        BuiltInAvatarMarkShape(avatar: avatar)
                            .stroke(.black.opacity(0.82), lineWidth: 0.85)
                    }
            }
            .overlay {
                if avatar == .kite {
                    BuiltInKiteExpressionShape().stroke(
                        .black.opacity(0.8),
                        style: StrokeStyle(lineWidth: 0.85, lineCap: .round, lineJoin: .round)
                    )
                }
            }
    }

    private var eyes: some View {
        HStack(spacing: size * 0.13) { eye; eye }
            .offset(x: avatar == .bean ? size * 0.045 : 0, y: size * 0.01)
    }

    private var eye: some View {
        Capsule(style: .continuous)
            .fill(.white)
            .frame(width: size * eyeWidth, height: size * eyeHeight * 0.64)
            .overlay {
                Capsule(style: .continuous).stroke(.black.opacity(0.8), lineWidth: 0.65)
            }
            .overlay {
                Circle().fill(.black)
                    .frame(width: size * 0.065, height: size * 0.065)
                    .offset(y: size * 0.025)
            }
    }

    private var eyeWidth: CGFloat {
        switch avatar {
        case .pillow: 0.20
        case .kite: 0.18
        default: 0.17
        }
    }

    private var eyeHeight: CGFloat { avatar == .pillow ? 0.22 : 0.24 }

    private var palette: [Color] {
        switch (avatar, colorScheme) {
        case (.pillow, .dark): [rgb(0x6FA8FF), rgb(0x80D5F4)]
        case (.pillow, _): [rgb(0x3A7DD8), rgb(0x53B6DA)]
        case (.kite, .dark): [rgb(0xA797FF), rgb(0xD08FE6)]
        case (.kite, _): [rgb(0x7055CC), rgb(0xA55DB8)]
        case (.bean, .dark): [rgb(0xFF8C91), rgb(0xFFB083)]
        case (.bean, _): [rgb(0xC8535B), rgb(0xDB7B55)]
        default: [.clear, .clear]
        }
    }

    private func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

private struct BuiltInAvatarBodyShape: Shape {
    let avatar: BuiltInAvatar

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        switch avatar {
        case .pillow:
            // A low, gently inflated cushion: flat-ish crown and base, with
            // rounded corners. Its height is distinct from the current round bot.
            path.move(to: p(0.18, 0.25))
            path.addCurve(to: p(0.82, 0.25), control1: p(0.35, 0.20), control2: p(0.65, 0.20))
            path.addCurve(to: p(0.95, 0.43), control1: p(0.93, 0.23), control2: p(0.97, 0.31))
            path.addCurve(to: p(0.90, 0.75), control1: p(0.94, 0.53), control2: p(0.97, 0.67))
            path.addCurve(to: p(0.73, 0.86), control1: p(0.87, 0.86), control2: p(0.80, 0.87))
            path.addCurve(to: p(0.27, 0.86), control1: p(0.59, 0.88), control2: p(0.41, 0.88))
            path.addCurve(to: p(0.10, 0.75), control1: p(0.20, 0.87), control2: p(0.13, 0.86))
            path.addCurve(to: p(0.05, 0.43), control1: p(0.03, 0.67), control2: p(0.06, 0.53))
            path.addCurve(to: p(0.18, 0.25), control1: p(0.03, 0.31), control2: p(0.07, 0.23))

        case .fin:
            break
        case .kite:
            // Four equally weighted, softly pointed corners distinguish this
            // diamond from the current teardrop's single apex and round base.
            path.move(to: p(0.44, 0.10))
            path.addCurve(to: p(0.56, 0.10), control1: p(0.47, 0.045), control2: p(0.53, 0.045))
            path.addCurve(to: p(0.90, 0.44), control1: p(0.65, 0.23), control2: p(0.77, 0.35))
            path.addCurve(to: p(0.90, 0.56), control1: p(0.955, 0.47), control2: p(0.955, 0.53))
            path.addCurve(to: p(0.56, 0.90), control1: p(0.77, 0.65), control2: p(0.65, 0.77))
            // A tiny flat at the lower tip suggests a firmer clean-shaven chin
            // while preserving the four-direction rounded diamond silhouette.
            path.addCurve(to: p(0.53, 0.93), control1: p(0.55, 0.918), control2: p(0.54, 0.93))
            path.addLine(to: p(0.47, 0.93))
            path.addCurve(to: p(0.44, 0.90), control1: p(0.46, 0.93), control2: p(0.45, 0.918))
            path.addCurve(to: p(0.10, 0.56), control1: p(0.35, 0.77), control2: p(0.23, 0.65))
            path.addCurve(to: p(0.10, 0.44), control1: p(0.045, 0.53), control2: p(0.045, 0.47))
            path.addCurve(to: p(0.44, 0.10), control1: p(0.23, 0.35), control2: p(0.35, 0.23))

        case .bean:
            // A tall asymmetric bean, with a visible inward curve on its left
            // side. The face is slightly right of center to fit that profile.
            path.move(to: p(0.45, 0.09))
            path.addCurve(to: p(0.89, 0.30), control1: p(0.63, 0.05), control2: p(0.84, 0.13))
            path.addCurve(to: p(0.90, 0.73), control1: p(0.96, 0.42), control2: p(0.98, 0.60))
            path.addCurve(to: p(0.61, 0.94), control1: p(0.85, 0.90), control2: p(0.74, 0.95))
            path.addCurve(to: p(0.16, 0.76), control1: p(0.41, 0.93), control2: p(0.20, 0.91))
            path.addCurve(to: p(0.11, 0.55), control1: p(0.08, 0.69), control2: p(0.08, 0.62))
            path.addCurve(to: p(0.27, 0.43), control1: p(0.13, 0.48), control2: p(0.22, 0.50))
            path.addCurve(to: p(0.26, 0.27), control1: p(0.32, 0.36), control2: p(0.25, 0.35))
            path.addCurve(to: p(0.45, 0.09), control1: p(0.24, 0.17), control2: p(0.34, 0.11))

        case .guide:
            break
        }
        path.closeSubpath()
        return path
    }
}

private struct BuiltInAvatarMarkShape: Shape {
    let avatar: BuiltInAvatar

    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        switch avatar {
        case .pillow:
            // One small lower-face lozenge, kept separate from the eye treatment.
            path.move(to: p(0.44, 0.69))
            path.addCurve(to: p(0.56, 0.69), control1: p(0.48, 0.67), control2: p(0.52, 0.67))
            path.addCurve(to: p(0.50, 0.76), control1: p(0.57, 0.73), control2: p(0.54, 0.76))
            path.addCurve(to: p(0.44, 0.69), control1: p(0.46, 0.76), control2: p(0.43, 0.73))
            path.closeSubpath()

        case .fin:
            break
        case .kite:
            // Paired brows suggest the references' defined brow structure,
            // softened and gently raised so the bot does not inherit a scowl.
            path.move(to: p(0.265, 0.335))
            path.addCurve(to: p(0.435, 0.335), control1: p(0.315, 0.295), control2: p(0.395, 0.30))
            path.addCurve(to: p(0.435, 0.36), control1: p(0.442, 0.345), control2: p(0.44, 0.355))
            path.addCurve(to: p(0.29, 0.355), control1: p(0.385, 0.335), control2: p(0.33, 0.33))
            path.addCurve(to: p(0.265, 0.335), control1: p(0.275, 0.36), control2: p(0.26, 0.35))
            path.closeSubpath()

            path.move(to: p(0.565, 0.345))
            path.addCurve(to: p(0.735, 0.34), control1: p(0.615, 0.31), control2: p(0.68, 0.31))
            path.addCurve(to: p(0.715, 0.365), control1: p(0.75, 0.35), control2: p(0.735, 0.365))
            path.addCurve(to: p(0.565, 0.365), control1: p(0.66, 0.34), control2: p(0.615, 0.34))
            path.addCurve(to: p(0.565, 0.345), control1: p(0.56, 0.36), control2: p(0.56, 0.35))
            path.closeSubpath()

        case .bean:
            // Two simple cheek freckles; the asymmetry belongs to the body,
            // while the face remains calm and consistent with its siblings.
            for x in [CGFloat(0.19), CGFloat(0.745)] {
                path.addEllipse(
                    in: CGRect(
                        x: rect.minX + rect.width * x,
                        y: rect.minY + rect.height * 0.62,
                        width: rect.width * 0.075,
                        height: rect.height * 0.075
                    )
                )
            }

        case .guide:
            break
        }
        return path
    }
}

private struct BuiltInKiteExpressionShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        // A single small nose-tip curve, not a shaded or realistic human nose.
        path.move(to: p(0.50, 0.575))
        path.addCurve(to: p(0.485, 0.63), control1: p(0.496, 0.60), control2: p(0.475, 0.617))
        path.addCurve(to: p(0.535, 0.635), control1: p(0.50, 0.645), control2: p(0.517, 0.645))
        path.move(to: p(0.42, 0.70))
        path.addCurve(to: p(0.58, 0.695), control1: p(0.465, 0.725), control2: p(0.535, 0.725))
        return path
    }
}
