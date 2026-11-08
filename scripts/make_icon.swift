import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.30, blue: 0.95, alpha: 1)])?.draw(in: path, angle: -60)
    // stylised folder
    let folder = NSBezierPath(roundedRect: NSRect(x: size * 0.25, y: size * 0.27, width: size * 0.5, height: size * 0.36), xRadius: size * 0.04, yRadius: size * 0.04)
    NSColor.white.withAlphaComponent(0.95).setFill()
    folder.fill()
    let tab = NSBezierPath(roundedRect: NSRect(x: size * 0.25, y: size * 0.58, width: size * 0.2, height: size * 0.09), xRadius: size * 0.03, yRadius: size * 0.03)
    tab.fill()
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size * 0.22, weight: .bold)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(calibratedRed: 0.45, green: 0.36, blue: 0.97, alpha: 1).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = size * 0.24, h = w * symbol.size.height / max(symbol.size.width, 1)
        tinted.draw(in: NSRect(x: size * 0.5 - w / 2, y: size * 0.45 - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        if let data = render(px) { try? data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name)) }
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: out).appendingPathComponent("Contents.json"))
