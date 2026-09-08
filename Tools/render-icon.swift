import AppKit

// Native vector rendering of Assets/AppIcon.svg, preserving transparent corners.
// Keep the geometry and colors identical to the editable SVG master.
let output = CommandLine.arguments[1]
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let cg = context.cgContext
cg.translateBy(x: 0, y: 1024)
cg.scaleBy(x: 1, y: -1)
cg.setFillColor(NSColor.white.cgColor)
cg.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
    cornerWidth: 200, cornerHeight: 200, transform: nil))
cg.fillPath()
cg.saveGState()
cg.addPath(CGPath(roundedRect: CGRect(x: 244, y: 272, width: 536, height: 480),
    cornerWidth: 52, cornerHeight: 52, transform: nil))
cg.clip()
let colors = [
    CGColor(red: 57/255.0, green: 149/255.0, blue: 246/255.0, alpha: 1),
    CGColor(red: 20/255.0, green: 102/255.0, blue: 222/255.0, alpha: 1)
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: 244, y: 272),
    end: CGPoint(x: 672.8, y: 752), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
cg.setFillColor(NSColor.white.cgColor)
cg.fill(CGRect(x: 244, y: 400, width: 536, height: 20))
cg.fill(CGRect(x: 244, y: 566, width: 536, height: 20))
cg.fill(CGRect(x: 432, y: 420, width: 20, height: 332))
cg.restoreGState()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
