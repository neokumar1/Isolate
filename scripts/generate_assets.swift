import Cocoa

// Run from the repository root: swift scripts/generate_assets.swift

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

    // Clean Pure White Background matching reference screenshot
    context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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
    
    for spec in iconSpecs {
        let s = CGFloat(spec.pixelSize)
        let bitmap = try makeBitmap(width: spec.pixelSize, height: spec.pixelSize)
        let ctx = bitmap.context.cgContext

        let bounds = CGRect(x: 0, y: 0, width: s, height: s)
        
        // 1. Dark hardware background
        ctx.setFillColor(CGColor(red: 0.055, green: 0.055, blue: 0.06, alpha: 1.0))
        ctx.fill(bounds)
        
        // Very subtle radial depth gradient from center to edges
        let colors = [
            CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0),
            CGColor(red: 0.04, green: 0.04, blue: 0.045, alpha: 1.0)
        ] as CFArray
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            let center = CGPoint(x: s / 2.0, y: s / 2.0)
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.7, options: [])
        }
        
        // 2. Nothing Tech Micro Dot Matrix Texture (Full Bleed Grid)
        let dotStep = max(3.0, s * 0.04)
        let dotW = max(0.8, s * 0.009)
        ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.045))
        for gx in stride(from: dotStep, through: s - dotStep / 2.0, by: dotStep) {
            for gy in stride(from: dotStep, through: s - dotStep / 2.0, by: dotStep) {
                ctx.fill(CGRect(x: gx - dotW / 2.0, y: gy - dotW / 2.0, width: dotW, height: dotW))
            }
        }
        
        // 3. Center Hardware Graphic: 4 Dot-Matrix Pixel Stems (Vocals, Drums, Bass, Other)
        // Scaled up for bold readability in modern macOS Dock & App Switcher
        let stemPixelCounts = [5, 8, 10, 6]
        let maxDots = 10
        
        let pixelW = max(1.5, s * 0.088)
        let pixelH = max(1.5, s * 0.072)
        let pixelGap = max(0.8, s * 0.014)
        let colSpacing = max(1.5, s * 0.052)
        
        let totalW = CGFloat(4) * pixelW + CGFloat(3) * colSpacing
        let startX = (s - totalW) / 2.0
        
        let totalMaxH = CGFloat(maxDots) * pixelH + CGFloat(maxDots - 1) * pixelGap
        let startY = (s - totalMaxH) / 2.0
        
        for (colIndex, count) in stemPixelCounts.enumerated() {
            let colX = startX + CGFloat(colIndex) * (pixelW + colSpacing)
            let colH = CGFloat(count) * pixelH + CGFloat(count - 1) * pixelGap
            let colStartY = startY + (totalMaxH - colH) / 2.0 // vertically centered
            
            // Stem Colors: Bar 1 (Pure White), Bar 2 (Nothing Red), Bar 3 (Nothing Red), Bar 4 (Pure White)
            let isRed = (colIndex == 1 || colIndex == 2)
            let color: CGColor = isRed
                ? CGColor(red: 1.0, green: 0.16, blue: 0.16, alpha: 1.0)
                : CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1.0)
            
            ctx.setFillColor(color)
            
            for dotIndex in 0..<count {
                let dotY = colStartY + CGFloat(dotIndex) * (pixelH + pixelGap)
                let dotRect = CGRect(x: colX, y: dotY, width: pixelW, height: pixelH)
                let dotRadius = max(0.5, min(pixelW, pixelH) * 0.22) // subtle rounded square/bar pixel
                let dotPath = CGPath(roundedRect: dotRect, cornerWidth: dotRadius, cornerHeight: dotRadius, transform: nil)
                ctx.addPath(dotPath)
                ctx.fillPath()
            }
        }
        
        // 4. Red Corner LED Status Indicator Dot (Top-Right of Stems)
        let dotSize = max(2.5, s * 0.068)
        let col3X = startX + CGFloat(3) * (pixelW + colSpacing)
        let col3TopY = startY + (totalMaxH - (CGFloat(6) * pixelH + CGFloat(5) * pixelGap)) / 2.0 + CGFloat(6) * pixelH + CGFloat(5) * pixelGap
        let dotX = col3X + pixelW * 0.7
        let dotY = col3TopY + pixelGap * 1.6
        
        if dotX + dotSize <= s * 0.92 && dotY + dotSize <= s * 0.92 {
            // Outer faint glow
            ctx.setFillColor(CGColor(red: 1.0, green: 0.16, blue: 0.16, alpha: 0.28))
            ctx.fillEllipse(in: CGRect(x: dotX - dotSize * 0.35, y: dotY - dotSize * 0.35, width: dotSize * 1.7, height: dotSize * 1.7))
            
            // Solid LED
            ctx.setFillColor(CGColor(red: 1.0, green: 0.16, blue: 0.16, alpha: 1.0))
            ctx.fillEllipse(in: CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize))
        }
        
        bitmap.context.flushGraphics()

        guard let png = bitmap.rep.representation(using: .png, properties: [:]) else { throw AssetError.renderFailed }
        try png.write(to: iconsetDir.appendingPathComponent(spec.name))
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
    print("Generated Nothing-inspired dot-matrix AppIcon.icns")
}

enum AssetError: Error { case renderFailed, iconConversionFailed }
try createDMGBackground()
try createAppIcon()
