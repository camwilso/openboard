import AppKit
import CoreGraphics
import Foundation
import OpenBoardKit

/*
 Render the app icon.

 The icon is the PARTY keycap's confetti glyph — the same artwork that sits on the
 physical key, so the thing in your Dock and the thing under your hand are recognisably
 the same product.

 Drawn from the catalog's vector paths rather than shipped as a PNG for the same reason
 the keycaps are: there is no asset catalog here (actool is an Xcode tool), and a vector
 re-renders cleanly at every size macOS asks for, from 16pt in a permissions list to
 1024pt in Finder.

 Usage: openboard-icon <output.iconset-directory>
 */

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "OpenBoard.iconset"

guard let icon = KeycapCatalog.icon(forCap: "PARTY") else {
    FileHandle.standardError.write(Data("no PARTY cap in the catalog\n".utf8))
    exit(1)
}

/// Claude orange. The accent everywhere else in the app.
let accent = (r: 0.851, g: 0.467, b: 0.341)

func render(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS icons sit inside their canvas rather than filling it; the squircle is
    // about 80% of the bounds with the rest as breathing room.
    let inset = dimension * 0.10
    let plate = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = plate.width * 0.2237   // Apple's continuous-corner ratio

    let squircle = CGPath(
        roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    // A soft vertical gradient: flat color reads as a placeholder at large sizes.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(srgbRed: accent.r * 1.12, green: accent.g * 1.12, blue: accent.b * 1.12, alpha: 1),
            CGColor(srgbRed: accent.r * 0.86, green: accent.g * 0.86, blue: accent.b * 0.86, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: plate.maxY),
        end: CGPoint(x: 0, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // The glyph, centred and scaled into the plate.
    let glyphBox = plate.insetBy(dx: plate.width * 0.24, dy: plate.height * 0.24)
    let scale = min(glyphBox.width / icon.width, glyphBox.height / icon.height)
    // Flip: SVG's origin is top-left, Core Graphics' is bottom-left.
    var transform = CGAffineTransform(translationX: glyphBox.minX, y: glyphBox.maxY)
        .scaledBy(x: scale, y: -scale)

    context.setLineCap(.round)
    context.setLineJoin(.round)
    for spec in icon.paths {
        let raw = SVGPath.parse(spec.d)
        guard let path = raw.copy(using: &transform) else { continue }
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        if spec.filled {
            context.fillPath(using: spec.evenOdd ? .evenOdd : .winding)
        } else {
            context.setLineWidth(max(1, spec.strokeWidth * scale))
            context.strokePath()
        }
    }

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

let directory = URL(fileURLWithPath: outputPath)
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// The exact set `iconutil` expects; a missing size makes it refuse the whole iconset.
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let png = render(size: variant.size) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: directory.appendingPathComponent("\(variant.name).png"))
}

print("wrote \(variants.count) sizes to \(directory.path)")
