// Draws the Screencorder logo: a dashed selection frame around a record dot.
// Usage: swift scripts/make-icon.swift <output.png> [size]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: make-icon.swift <output.png> [size]")
    exit(1)
}
let size = arguments.count >= 3 ? Int(arguments[2]) ?? 1024 : 1024
let s = CGFloat(size) / 1024

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// The plate, in the proportions of a macOS app icon.
let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186 * s, cornerHeight: 186 * s,
                       transform: nil)
context.saveGState()
context.addPath(platePath)
context.clip()
let gradient = CGGradient(colorsSpace: space,
                          colors: [color(46, 46, 52), color(18, 18, 22)] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
context.restoreGState()

// The dashed selection frame.
let frame = plate.insetBy(dx: 170 * s, dy: 215 * s)
context.setStrokeColor(color(255, 255, 255, 0.92))
context.setLineWidth(30 * s)
context.setLineCap(.round)
context.setLineDash(phase: 0, lengths: [62 * s, 62 * s])
context.addPath(CGPath(roundedRect: frame, cornerWidth: 44 * s, cornerHeight: 44 * s,
                       transform: nil))
context.strokePath()

// The record dot.
let radius = 96 * s
context.setFillColor(color(255, 59, 48))
context.fillEllipse(in: CGRect(x: frame.midX - radius, y: frame.midY - radius,
                               width: radius * 2, height: radius * 2))

let image = context.makeImage()!
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: arguments[1]))
