import AppKit
import Foundation

// MARK: - Bolt Path Definition (Authored in 24x24 box)

let boltPathData = """
M5.66953 9.91436 L8.73167 5.77133
C10.711 3.09327 11.7007 1.75425 12.6241 2.03721
C13.5474 2.32018 13.5474 3.96249 13.5474 7.24712
V7.55682
C13.5474 8.74151 13.5474 9.33386 13.926 9.70541
L13.946 9.72466
C14.3327 10.0884 14.9492 10.0884 16.1822 10.0884
C18.4011 10.0884 19.5106 10.0884 19.8855 10.7613
C19.8917 10.7724 19.8977 10.7837 19.9036 10.795
C20.2576 11.4784 19.6152 12.3475 18.3304 14.0857
L15.2683 18.2287
C13.2889 20.9067 12.2992 22.2458 11.3758 21.9628
C10.4525 21.6798 10.4525 20.0375 10.4525 16.7528
L10.4526 16.4433
C10.4526 15.2585 10.4526 14.6662 10.074 14.2946
L10.054 14.2754
C9.6673 13.9117 9.05079 13.9117 7.81775 13.9117
C5.59888 13.9117 4.48945 13.9117 4.1145 13.2387
C4.10829 13.2276 4.10225 13.2164 4.09639 13.205
C3.74244 12.5217 4.3848 11.6526 5.66953 9.91436
Z
"""

func makeBoltPath() -> CGPath {
    let path = CGMutablePath()
    var tokens: [String] = []
    var current = ""
    for character in boltPathData {
        if character.isLetter {
            if !current.isEmpty { tokens.append(current) }
            tokens.append(String(character))
            current = ""
        } else if character.isWhitespace || character == "," {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { tokens.append(current) }

    var index = 0
    func next() -> Double {
        guard index < tokens.count, let value = Double(tokens[index]) else { return 0 }
        index += 1
        return value
    }
    func command() -> String {
        guard index < tokens.count else { return "" }
        let token = tokens[index]
        index += 1
        return token
    }

    var cursor = CGPoint.zero
    while index < tokens.count {
        switch command() {
        case "M":
            cursor = CGPoint(x: next(), y: next())
            path.move(to: cursor)
        case "L":
            cursor = CGPoint(x: next(), y: next())
            path.addLine(to: cursor)
        case "V":
            let y = next()
            cursor = CGPoint(x: cursor.x, y: y)
            path.addLine(to: cursor)
        case "C":
            let c1 = CGPoint(x: next(), y: next())
            let c2 = CGPoint(x: next(), y: next())
            let end = CGPoint(x: next(), y: next())
            path.addCurve(to: end, control1: c1, control2: c2)
            cursor = end
        case "Z", "z":
            path.closeSubpath()
        default:
            return path
        }
    }
    return path
}

// MARK: - Color Palette

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: 1.0
    )
}

// Squircle background gradient (Dark theme matching JXServer / JXCode)
let baseColor   = rgb(0x0E1116)
let layer2Color = rgb(0x1B222B)

// JXRouter Signature Lightning: Electric Violet / Bright Lavender (#8B5CF6 / #A78BFA)
let boltBase   = rgb(0x8B5CF6) // Deep electric violet
let boltTop    = rgb(0xA78BFA) // Bright lavender hover / top highlight

// MARK: - Icon Renderer (Dock / AppIcon)

func renderAppIcon(size: CGFloat, inset: CGFloat, boltScale: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip context so SVG y-down coords render correctly
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let tileInset = size * inset
    let tile = CGRect(
        x: tileInset, y: tileInset,
        width: size - tileInset * 2,
        height: size - tileInset * 2
    )
    let radius = tile.width * 0.2237 // Apple continuous-corner squircle proportion

    // Draw squircle tile
    ctx.saveGState()
    let tileShape = CGPath(
        roundedRect: tile,
        cornerWidth: radius, cornerHeight: radius,
        transform: nil
    )
    ctx.addPath(tileShape)
    ctx.clip()

    let fill = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [layer2Color.cgColor, baseColor.cgColor] as CFArray,
        locations: [0.0, 1.0]
    )
    if let fill = fill {
        ctx.drawLinearGradient(
            fill,
            start: CGPoint(x: tile.midX, y: tile.minY),
            end: CGPoint(x: tile.midX, y: tile.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    // Draw lightning bolt
    let draw = tile.width * boltScale
    let origin = CGPoint(
        x: tile.midX - draw / 2,
        y: tile.midY - draw / 2
    )
    let scale = draw / 24.0

    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: scale, y: scale)

    let bolt = makeBoltPath()
    ctx.addPath(bolt)
    ctx.setFillColor(boltBase.cgColor)
    ctx.fillPath()

    // Top highlight pass
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let bounds = bolt.boundingBox
    ctx.setFillColor(boltTop.withAlphaComponent(0.6).cgColor)
    ctx.fill(CGRect(
        x: bounds.minX, y: bounds.minY,
        width: bounds.width, height: bounds.height / 2
    ))
    ctx.restoreGState()

    ctx.restoreGState()
    return image
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return }
    try? png.write(to: url)
}

// MARK: - Execute Generation

let appIconDir = URL(fileURLWithPath: "Sources/JXRouter/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)

let iconSizes: [(String, CGFloat, CGFloat, CGFloat)] = [
    ("icon_16x16.png",       16,   0.00, 0.88),
    ("icon_16x16@2x.png",    32,   0.00, 0.76),
    ("icon_32x32.png",       32,   0.00, 0.76),
    ("icon_32x32@2x.png",    64,   0.02, 0.66),
    ("icon_128x128.png",     128,  0.06, 0.60),
    ("icon_128x128@2x.png",  256,  0.08, 0.56),
    ("icon_256x256.png",     256,  0.08, 0.56),
    ("icon_256x256@2x.png",  512,  0.10, 0.54),
    ("icon_512x512.png",     512,  0.10, 0.54),
    ("icon_512x512@2x.png",  1024, 0.10, 0.54)
]

for (filename, size, inset, scale) in iconSizes {
    let img = renderAppIcon(size: size, inset: inset, boltScale: scale)
    let url = appIconDir.appendingPathComponent(filename)
    writePNG(img, to: url)
    print("Wrote AppIcon: \(filename) (\(Int(size))x\(Int(size)))")
}

// Also build AppIcon.iconset for iconutil -> AppIcon.icns
let tmpIconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: tmpIconset, withIntermediateDirectories: true)

for (filename, size, inset, scale) in iconSizes {
    let img = renderAppIcon(size: size, inset: inset, boltScale: scale)
    let url = tmpIconset.appendingPathComponent(filename)
    writePNG(img, to: url)
}

print("AppIcon generation complete.")

