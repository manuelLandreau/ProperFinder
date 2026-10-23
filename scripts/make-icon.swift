import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Apple's icon grid: an 824 pt body centered in the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let light = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.62, green: 0.86, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.36, green: 0.70, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

    let profile = CGMutablePath()
    profile.move(to: CGPoint(x: 560, y: 924))
    profile.addCurve(to: CGPoint(x: 470, y: 520), control1: CGPoint(x: 540, y: 760), control2: CGPoint(x: 470, y: 640))
    profile.addLine(to: CGPoint(x: 545, y: 505))
    profile.addCurve(to: CGPoint(x: 600, y: 100), control1: CGPoint(x: 520, y: 380), control2: CGPoint(x: 560, y: 220))
    profile.addLine(to: CGPoint(x: 924, y: 100))
    profile.addLine(to: CGPoint(x: 924, y: 924))
    profile.closeSubpath()
    ctx.addPath(profile)
    ctx.clip()
    let dark = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.20, green: 0.52, blue: 0.95, alpha: 1).cgColor,
        NSColor(srgbRed: 0.09, green: 0.33, blue: 0.82, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(dark, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    ctx.setStrokeColor(NSColor(srgbRed: 0.05, green: 0.17, blue: 0.40, alpha: 1).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(46)
    for x in [350.0, 700.0] {
        ctx.move(to: CGPoint(x: x, y: 700))
        ctx.addLine(to: CGPoint(x: x, y: 600))
    }
    ctx.strokePath()

    ctx.setLineWidth(30)
    ctx.move(to: CGPoint(x: 280, y: 330))
    ctx.addCurve(to: CGPoint(x: 760, y: 330), control1: CGPoint(x: 400, y: 220), control2: CGPoint(x: 640, y: 220))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try render(size: 512).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "build/AppIcon-preview.png"))
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
