// Renders Volumio's icon into an .iconset folder: swift scripts/make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background squircle (macOS icon grid: 824/1024 body with margins).
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(red: 0.10, green: 0.62, blue: 0.98, alpha: 1)])!.draw(in: path, angle: -60)

    // Three mixer faders.
    let levels: [CGFloat] = [0.70, 0.35, 0.55]
    let trackW = body.width * 0.07
    let top = body.minY + body.height * 0.80, bottom = body.minY + body.height * 0.20
    for (i, level) in levels.enumerated() {
        let x = body.minX + body.width * (0.28 + 0.22 * CGFloat(i))
        let track = NSRect(x: x - trackW / 2, y: bottom, width: trackW, height: top - bottom)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackW / 2, yRadius: trackW / 2).fill()
        let filled = NSRect(x: track.minX, y: bottom, width: trackW, height: (top - bottom) * level)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackW / 2, yRadius: trackW / 2).fill()
        let knobW = body.width * 0.17, knobH = body.width * 0.085
        let knob = NSRect(x: x - knobW / 2, y: bottom + (top - bottom) * level - knobH / 2, width: knobW, height: knobH)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knob, xRadius: knobH / 2, yRadius: knobH / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
