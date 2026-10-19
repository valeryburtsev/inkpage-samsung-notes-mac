// Draws the app icon: a sheet of paper with a pen stroke on a warm rounded square.
//   swift tools/icon/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let side = 1024
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// The plate: macOS icons sit in a rounded square inset from the canvas.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.28))
context.addPath(platePath)
context.setFillColor(color(1, 0.42, 0.32))
context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(platePath)
context.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(1.0, 0.55, 0.36), color(0.96, 0.27, 0.30)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A soft highlight along the top, as glass catches light.
let shine = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.34), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
context.drawRadialGradient(shine, startCenter: CGPoint(x: 360, y: 980), startRadius: 0, endCenter: CGPoint(x: 360, y: 980), endRadius: 620, options: [])
context.restoreGState()

// The sheet, tilted a little.
context.saveGState()
context.translateBy(x: 512, y: 512)
context.rotate(by: -0.07)
let sheet = CGRect(x: -236, y: -286, width: 472, height: 572)
let sheetPath = CGPath(roundedRect: sheet, cornerWidth: 54, cornerHeight: 54, transform: nil)
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0.45, 0.05, 0.08, 0.38))
context.addPath(sheetPath)
context.setFillColor(color(1, 1, 1))
context.fillPath()
context.setShadow(offset: .zero, blur: 0, color: nil)
// Two lines of "text".
context.setLineCap(.round)
context.setStrokeColor(color(0.84, 0.86, 0.9))
context.setLineWidth(26)
for (y, width) in [(176.0, 300.0), (104.0, 220.0)] {
    context.move(to: CGPoint(x: -160, y: y))
    context.addLine(to: CGPoint(x: -160 + width, y: y))
    context.strokePath()
}
// The pen stroke: a handwritten flourish.
let stroke = CGMutablePath()
stroke.move(to: CGPoint(x: -168, y: -96))
stroke.addCurve(to: CGPoint(x: -70, y: 6), control1: CGPoint(x: -150, y: -20), control2: CGPoint(x: -100, y: 30))
stroke.addCurve(to: CGPoint(x: -28, y: -128), control1: CGPoint(x: -40, y: -20), control2: CGPoint(x: -60, y: -120))
stroke.addCurve(to: CGPoint(x: 62, y: -10), control1: CGPoint(x: 0, y: -136), control2: CGPoint(x: 30, y: -30))
stroke.addCurve(to: CGPoint(x: 104, y: -138), control1: CGPoint(x: 96, y: 10), control2: CGPoint(x: 70, y: -136))
stroke.addCurve(to: CGPoint(x: 178, y: -76), control1: CGPoint(x: 130, y: -140), control2: CGPoint(x: 150, y: -110))
context.addPath(stroke)
context.setStrokeColor(color(0.13, 0.36, 0.96))
context.setLineWidth(34)
context.setLineJoin(.round)
context.strokePath()
context.restoreGState()

let image = context.makeImage()!
let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
