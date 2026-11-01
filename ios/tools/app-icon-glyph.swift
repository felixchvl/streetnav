// Renders the app icon's glyph, an SF Symbol in white on a transparent 1024 px canvas, into AppIcon.icon/Assets.
// Icon Composer recolours it (navy on white, white on navy in dark mode). The PNG is not committed: SF Symbols
// may not be redistributed. Run once after cloning: swift ios/tools/app-icon-glyph.swift [symbol] [output]
import AppKit

let arguments = CommandLine.arguments
let symbol = arguments.count > 1 ? arguments[1] : "bicycle"
let output = arguments.count > 2 ? arguments[2] : "ios/Streetnav/AppIcon.icon/Assets/Glyph.png"
let canvas = 1024.0
let longestSide = 740.0

guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
      let image = base.withSymbolConfiguration(.init(pointSize: 400, weight: .semibold).applying(.init(paletteColors: [.white]))) else {
    fatalError("Unknown SF Symbol: \(symbol)")
}
let scale = longestSide / max(image.size.width, image.size.height)
let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height))
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: output)
try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
print("\(symbol) → \(output)")
