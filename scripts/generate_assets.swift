import Cocoa
import CoreText

// Run from the repository root with Xcode 27 selected: swift scripts/generate_assets.swift

/// A drawing context backed by exactly `width` x `height` pixels. NSImage.lockFocus
/// draws at the main screen's backing scale, which doubled every size on Retina
/// Macs and left the icon without its 16 and 128 px images.
func makeBitmap(width: Int, height: Int) throws -> (rep: NSBitmapImageRep, context: NSGraphicsContext) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { throw AssetError.renderFailed }
    return (rep, context)
}

func createDMGBackground() throws {
    let width: CGFloat = 660
    let height: CGFloat = 400
    let scale: CGFloat = 2.0

    let bitmap = try makeBitmap(width: Int(width * scale), height: Int(height * scale))
    let context = bitmap.context.cgContext
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = bitmap.context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let fontURL = URL(fileURLWithPath: "Sources/Resources/DotGothic16-Regular.ttf")
    CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    guard let titleFont = NSFont(name: "DotGothic16-Regular", size: 18),
          let labelFont = NSFont(name: "DotGothic16-Regular", size: 11) else {
        throw AssetError.renderFailed
    }

    let background = CGColor(red: 0.985, green: 0.985, blue: 0.98, alpha: 1)
    let ink = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    let secondary = NSColor(calibratedRed: 0.28, green: 0.28, blue: 0.30, alpha: 1)
    let accent = CGColor(red: 0.78, green: 0.08, blue: 0.11, alpha: 1)
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    func label(_ string: String, at point: CGPoint, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
        NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .kern: tracking
        ]).draw(at: point)
    }

    // Finder places the app and Applications icons around x=170 and x=490.
    // Keep their labels and hit targets unobstructed; the red arrow occupies
    // only the gap between them.
    label("DRAG ISOLATE INTO APPLICATIONS", at: CGPoint(x: 35, y: 340),
          font: titleFont, color: ink, tracking: 0.35)
    context.setFillColor(CGColor(red: 0.76, green: 0.76, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 35, y: 324, width: 590, height: 0.5))

    context.setFillColor(accent)
    context.fill(CGRect(x: 292, y: 204, width: 72, height: 4))
    context.move(to: CGPoint(x: 374, y: 206))
    context.addLine(to: CGPoint(x: 357, y: 218))
    context.addLine(to: CGPoint(x: 357, y: 194))
    context.closePath()
    context.fillPath()

    context.setFillColor(CGColor(red: 0.76, green: 0.76, blue: 0.75, alpha: 1))
    context.fill(CGRect(x: 35, y: 133, width: 590, height: 0.5))
    label("APPLE SILICON (M1+)  /  macOS 14 OR LATER", at: CGPoint(x: 35, y: 108),
          font: labelFont, color: ink, tracking: 0.1)
    label("macOS 26+ RECOMMENDED FOR SEPARATION  /  MODEL INCLUDED", at: CGPoint(x: 35, y: 87),
          font: labelFont, color: secondary, tracking: 0.1)
    bitmap.context.flushGraphics()

    // 144 dpi, so Finder draws these pixels into the 660 x 400 pt window.
    bitmap.rep.size = NSSize(width: width, height: height)
    guard let pngData = bitmap.rep.representation(using: .png, properties: [:]) else { throw AssetError.renderFailed }
    let outDir = URL(fileURLWithPath: "Assets")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let outURL = outDir.appendingPathComponent("dmg_background.png")
    try pngData.write(to: outURL, options: .atomic)
    print("Generated DMG background at \(outURL.path)")
}

func createAppIcon() throws {
    let iconSpecs: [(name: String, pixelSize: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    
    let iconsetDir = FileManager.default.temporaryDirectory.appendingPathComponent("Isolate-\(UUID().uuidString).iconset")
    defer { try? FileManager.default.removeItem(at: iconsetDir) }
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    
    // Icon Composer applies the system enclosure, depth and highlights. Keep
    // vector layers in AppIcon.icon; do not bake a second mask into the artwork.
    let developer = try run("/usr/bin/xcode-select", ["-p"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let renderer = URL(fileURLWithPath: developer).deletingLastPathComponent()
        .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool")
    for spec in iconSpecs {
        _ = try run(renderer.path, [
            URL(fileURLWithPath: "Sources/Resources/AppIcon.icon").path,
            "--export-image", "--output-file", iconsetDir.appendingPathComponent(spec.name).path,
            "--platform", "macOS", "--rendition", "Default",
            "--width", String(spec.pixelSize), "--height", String(spec.pixelSize),
            "--scale", "1", "--design-generation", "27"
        ])
        if spec.pixelSize == 1024 {
            let data = try Data(contentsOf: iconsetDir.appendingPathComponent(spec.name))
            try data.write(to: URL(fileURLWithPath: "Assets/AppIcon-macOS27.png"), options: .atomic)
        }
    }

    let temporaryIcon = iconsetDir.appendingPathComponent("AppIcon.icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconsetDir.path, "-o", temporaryIcon.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AssetError.iconConversionFailed }
    let data = try Data(contentsOf: temporaryIcon)
    try data.write(to: URL(fileURLWithPath: "Assets/AppIcon.icns"), options: .atomic)
    try data.write(to: URL(fileURLWithPath: "Sources/Resources/AppIcon.icns"), options: .atomic)
    print("Generated macOS 27 icon preview and legacy/DMG ICNS from AppIcon.icon")
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AssetError.iconConversionFailed }
    return String(decoding: output, as: UTF8.self)
}

enum AssetError: Error { case renderFailed, iconConversionFailed }
try createDMGBackground()
if !CommandLine.arguments.contains("--dmg-only") { try createAppIcon() }
