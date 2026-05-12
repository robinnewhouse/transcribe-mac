import AppKit

let sizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let iconset = "Transcribe.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(size pixels: Int) -> Data {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)

    // Rounded-rect background
    let radius = CGFloat(pixels) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.30, green: 0.45, blue: 0.95, alpha: 1),
        NSColor(red: 0.15, green: 0.25, blue: 0.75, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // Mic glyph from SF Symbols
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * 0.55, weight: .semibold)
    if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tint = NSImage(size: mic.size)
        tint.lockFocus()
        NSColor.white.set()
        let micRect = NSRect(origin: .zero, size: mic.size)
        mic.draw(in: micRect)
        micRect.fill(using: .sourceIn)
        tint.unlockFocus()

        let drawW = CGFloat(pixels) * 0.55
        let drawH = drawW * (mic.size.height / mic.size.width)
        let drawRect = NSRect(
            x: (CGFloat(pixels) - drawW) / 2,
            y: (CGFloat(pixels) - drawH) / 2,
            width: drawW, height: drawH
        )
        tint.draw(in: drawRect)
    }

    image.unlockFocus()
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])!
}

for (base, scale) in sizes {
    let pixels = base * scale
    let data = render(size: pixels)
    let suffix = scale == 1 ? "" : "@2x"
    let name = "\(iconset)/icon_\(base)x\(base)\(suffix).png"
    try! data.write(to: URL(fileURLWithPath: name))
    print("Wrote \(name)")
}
