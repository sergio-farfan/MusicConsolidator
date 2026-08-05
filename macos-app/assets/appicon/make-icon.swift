// make-icon.swift — programmatic app icon generator for AppleMusicConsolidator.
// Draws a Big Sur-style squircle with a gradient and composes SF Symbols as
// the mark. Run: swift make-icon.swift <variant 1|2|3> <output.png> [size]
// Variants:
//   1  music.note over the Apple Music red-pink gradient, with a small
//      merge-arrows glyph at the lower left (merge/consolidate motif).
//   2  music.note.list (playlist) large, with a bold checkmark.seal at the
//      lower right (guarded/verified motif), same gradient.
//   3  darker crimson gradient, one large music.note, three small dots
//      converging into the stem via drawn curves (many tracks -> one).

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3, let variant = Int(args[1]) else {
    fputs("usage: swift make-icon.swift <1|2|3> <output.png> [size]\n", stderr)
    exit(2)
}
let outputPath = args[2]
let size = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
let s = CGFloat(size)
let scale = s / 1024.0

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("context failed\n", stderr); exit(1) }

NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Big Sur canvas: artwork squircle inset ~100/1024 with soft shadow.
let inset: CGFloat = 100 * scale
let artRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
let corner: CGFloat = 185 * scale
let squircle = CGPath(roundedRect: artRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

// Soft drop shadow beneath the squircle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 36 * scale,
              color: rgba(0, 0, 0, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgba(250, 35, 59))
ctx.fillPath()
ctx.restoreGState()

// Gradient fill clipped to the squircle.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors: [CGColor]
switch variant {
case 3:  colors = [rgba(255, 94, 105), rgba(160, 8, 32)]   // crimson depth
default: colors = [rgba(252, 108, 133), rgba(250, 35, 59)] // Apple Music pink->red
}
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: s / 2, y: s - inset),
                       end: CGPoint(x: s / 2, y: inset), options: [])
// Subtle top sheen.
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [rgba(255, 255, 255, 0.18), rgba(255, 255, 255, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: s / 2, y: s - inset),
                       end: CGPoint(x: s / 2, y: s / 2), options: [])
ctx.restoreGState()

/// Draw an SF Symbol tinted `white` centered in `rect` (fitted, keeping aspect).
func drawSymbol(_ name: String, in rect: CGRect, weight: NSFont.Weight = .semibold,
                alpha: CGFloat = 1.0) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        fputs("missing symbol \(name)\n", stderr); exit(1)
    }
    let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
    guard let symbol = base.withSymbolConfiguration(config) else { exit(1) }
    let aspect = symbol.size.width / symbol.size.height
    var target = rect
    if target.width / target.height > aspect {
        let w = target.height * aspect
        target.origin.x += (target.width - w) / 2
        target.size.width = w
    } else {
        let h = target.width / aspect
        target.origin.y += (target.height - h) / 2
        target.size.height = h
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
    ctx.setBlendMode(.sourceAtop)
    ctx.setFillColor(rgba(255, 255, 255, alpha))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()
}

switch variant {
case 1:
    drawSymbol("music.note",
               in: CGRect(x: s * 0.30, y: s * 0.24, width: s * 0.48, height: s * 0.52))
    drawSymbol("arrow.triangle.merge",
               in: CGRect(x: s * 0.17, y: s * 0.17, width: s * 0.24, height: s * 0.26),
               weight: .bold, alpha: 0.92)
case 2:
    drawSymbol("music.note.list",
               in: CGRect(x: s * 0.22, y: s * 0.26, width: s * 0.52, height: s * 0.48))
    drawSymbol("checkmark.seal.fill",
               in: CGRect(x: s * 0.58, y: s * 0.16, width: s * 0.22, height: s * 0.22),
               weight: .bold)
case 3:
    drawSymbol("music.note",
               in: CGRect(x: s * 0.34, y: s * 0.22, width: s * 0.44, height: s * 0.56))
    // Three dots converging into the note stem: many tracks -> one.
    ctx.setStrokeColor(rgba(255, 255, 255, 0.85))
    ctx.setLineWidth(16 * scale)
    ctx.setLineCap(.round)
    let stemTarget = CGPoint(x: s * 0.585, y: s * 0.52)
    let dotOrigins = [CGPoint(x: s * 0.20, y: s * 0.70),
                      CGPoint(x: s * 0.17, y: s * 0.52),
                      CGPoint(x: s * 0.21, y: s * 0.34)]
    for origin in dotOrigins {
        ctx.setFillColor(rgba(255, 255, 255, 0.95))
        ctx.fillEllipse(in: CGRect(x: origin.x - 22 * scale, y: origin.y - 22 * scale,
                                   width: 44 * scale, height: 44 * scale))
        ctx.move(to: CGPoint(x: origin.x + 24 * scale, y: origin.y))
        ctx.addQuadCurve(to: stemTarget,
                         control: CGPoint(x: (origin.x + stemTarget.x) / 2 + 30 * scale,
                                          y: origin.y))
        ctx.strokePath()
    }
default:
    fputs("unknown variant\n", stderr); exit(2)
}

guard let cgImage = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(size)x\(size), variant \(variant))")
