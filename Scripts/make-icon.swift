import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let n = CGFloat(side), inset = n * 0.07
        let shape = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: n-2*inset, height: n-2*inset), xRadius: n*0.20, yRadius: n*0.20)
        let gradient = NSGradient(starting: NSColor(red: 0.48, green: 0.43, blue: 1, alpha: 1), ending: NSColor(red: 0.26, green: 0.21, blue: 0.86, alpha: 1))!
        gradient.draw(in: shape, angle: -75)
        let paper = NSBezierPath(roundedRect: NSRect(x: n*0.28, y: n*0.22, width: n*0.43, height: n*0.56), xRadius: n*0.055, yRadius: n*0.055)
        NSColor.white.setFill(); paper.fill()
        let ink = NSBezierPath(); ink.lineCapStyle = .round; ink.lineWidth = max(1, n*0.034)
        for (y,width) in [(0.64,0.23),(0.53,0.18),(0.42,0.22)] { ink.move(to: NSPoint(x: n*0.38,y: n*y)); ink.line(to: NSPoint(x: n*(0.38+width),y: n*y)) }
        NSColor(red: 0.35,green: 0.30,blue: 0.89,alpha: 1).setStroke(); ink.stroke()
        let badge = NSBezierPath(ovalIn: NSRect(x: n*0.60,y: n*0.17,width: n*0.23,height: n*0.23))
        NSColor(red: 1,green: 0.69,blue: 0.34,alpha: 1).setFill(); badge.fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
