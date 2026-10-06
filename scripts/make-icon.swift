// Renders the Lumen app icon (1024×1024 PNG) following the macOS icon grid:
// a deep purple rounded-square plate with a white lowercase "l" and a beam of light fanning out of it.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
}

/// A polygon with rounded corners.
func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = points.count
    path.move(to: CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2))
    for i in 0..<n {
        path.addArc(tangent1End: points[i], tangent2End: points[(i + 1) % n], radius: radius)
    }
    path.closeSubpath()
    return path
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

let pink = rgb(0xFF5C8D)
let orange = rgb(0xFFA24C)

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // Plate: 824pt rounded square centred on the 1024 canvas (Apple's macOS grid).
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x1E1250, 0.35))
    ctx.addPath(platePath)
    ctx.setFillColor(rgb(0x4A2BC0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(platePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x5E3ADB), rgb(0x3A2199)], [0, 1]),
                           start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let stemX: CGFloat = 262
    let stemWidth: CGFloat = 140

    // The beam fans out of the "l" and fades into the plate.
    let beam = CGMutablePath()
    beam.move(to: CGPoint(x: stemX + 120, y: 540))
    beam.addLine(to: CGPoint(x: 960, y: 780))
    beam.addLine(to: CGPoint(x: 960, y: 200))
    beam.addLine(to: CGPoint(x: stemX + 120, y: 420))
    beam.closeSubpath()
    ctx.saveGState()
    ctx.addPath(beam)
    ctx.clip()
    // Its own layer, so the fade only affects the beam and not the plate behind it.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.drawLinearGradient(gradient([pink, orange], [0, 1]), start: CGPoint(x: 0, y: 780), end: CGPoint(x: 0, y: 200), options: [])
    ctx.setBlendMode(.destinationIn)
    ctx.drawLinearGradient(gradient([rgb(0, 1), rgb(0, 0.55), rgb(0, 0)], [0, 0.4, 1]),
                           start: CGPoint(x: stemX + stemWidth, y: 0), end: CGPoint(x: 900, y: 0), options: [.drawsAfterEndLocation])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // The "l": a rounded stem with a slanted cut on top.
    let stem = roundedPolygon([CGPoint(x: stemX, y: 230), CGPoint(x: stemX + stemWidth, y: 230),
                               CGPoint(x: stemX + stemWidth, y: 800), CGPoint(x: stemX, y: 745)], radius: 30)
    ctx.addPath(stem)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()

    // A soft fold on the stem where the light comes out.
    let edgeX = stemX + stemWidth
    let fold = CGMutablePath()
    fold.move(to: CGPoint(x: edgeX, y: 530))
    fold.addQuadCurve(to: CGPoint(x: edgeX, y: 430), control: CGPoint(x: edgeX - 30, y: 480))
    fold.closeSubpath()
    ctx.addPath(fold)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xDCD6F2), rgb(0xFFFFFF)], [0, 1]),
                           start: CGPoint(x: edgeX, y: 0), end: CGPoint(x: edgeX - 18, y: 0), options: [.drawsAfterEndLocation])
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
