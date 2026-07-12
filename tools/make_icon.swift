import Cocoa
import CoreGraphics

// CallBrain app icon — violet squircle + a clean white voice waveform. Run: swift tools/make_icon.swift <out.png>
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let S = CGFloat(size)
let margin: CGFloat = 96
let rect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// violet → indigo gradient (macOS adds its own shadow when it displays the icon — keep the art flat)
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [c(0.54, 0.44, 0.99), c(0.33, 0.23, 0.76)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// top sheen
let hi = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.20), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY + 40), options: [])
ctx.restoreGState()

// white voice waveform — symmetric rounded bars
ctx.saveGState()
let heights: [CGFloat] = [0.30, 0.55, 0.82, 1.0, 0.82, 0.55, 0.30]
let barW: CGFloat = 56, gap: CGFloat = 36
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = rect.midX - totalW / 2
let maxH = rect.height * 0.46
ctx.setFillColor(c(1, 1, 1, 0.97))
for h in heights {
    let bh = maxH * h
    let bar = CGRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.fillPath()
    x += barW + gap
}
ctx.restoreGState()

guard let img = ctx.makeImage() else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
