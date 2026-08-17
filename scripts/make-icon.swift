import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift make-icon.swift <input image> <output dir>
// Center-crops to square, applies the macOS squircle mask, emits an .iconset.

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: make-icon <input> <outdir>\n", stderr); exit(1) }
let inputURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fputs("cannot read \(inputURL.path)\n", stderr); exit(1)
}

// Center-crop to square, biased toward the top third (usually where a
// non-square image's subject sits); a no-op for already-square input.
let side = min(img.width, img.height)
let x = (img.width - side) / 2
let y = max(0, (img.height - side) / 6)   // top-biased
guard let square = img.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
    fputs("crop failed\n", stderr); exit(1)
}

func render(_ size: Int, scale: Int, name: String) {
    let px = size * scale
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: content occupies ~82% of the canvas, squircle corner ~22.5%.
    let inset = CGFloat(px) * 0.09
    let rect = CGRect(x: inset, y: inset, width: CGFloat(px) - 2*inset, height: CGFloat(px) - 2*inset)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(square, in: rect)
    let out = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    render(size, scale: 1, name: "icon_\(size)x\(size).png")
    render(size, scale: 2, name: "icon_\(size)x\(size)@2x.png")
}
print("iconset written to \(outDir.path)")
