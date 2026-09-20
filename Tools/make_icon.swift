import AppKit
import Foundation

// 生成 Resources/AppIcon.icns。用法：swift Tools/make_icon.swift
// 这里不用位图素材，全部用 Core Graphics 画，保证可复现且不依赖外部文件。

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
let icnsURL = outputDirectory.appendingPathComponent("AppIcon.icns")

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 选一个可用的 SF Symbol 当作光盘图形。
func symbolImage(pointSize: CGFloat) -> (NSImage, String)? {
    let candidates = ["opticaldisc.fill", "opticaldisc", "opticaldiscdrive.fill", "record.circle.fill", "record.circle"]
    for name in candidates {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            if let configured = image.withSymbolConfiguration(configuration) {
                return (configured, name)
            }
            return (image, name)
        }
    }
    return nil
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // macOS 图标惯例：留出边距的圆角矩形
    let inset = size * 0.085
    let bodyRect = rect.insetBy(dx: inset, dy: inset)
    let radius = bodyRect.width * 0.225
    let path = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
    path.addClip()

    let colors = [
        NSColor(calibratedRed: 0.11, green: 0.25, blue: 0.62, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.72, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
        end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
        options: []
    )

    // 高光
    context.saveGState()
    let shine = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(white: 1, alpha: 0.30).cgColor,
            NSColor(white: 1, alpha: 0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        shine,
        startCenter: CGPoint(x: bodyRect.minX + bodyRect.width * 0.28, y: bodyRect.maxY - bodyRect.height * 0.18),
        startRadius: 0,
        endCenter: CGPoint(x: bodyRect.minX + bodyRect.width * 0.28, y: bodyRect.maxY - bodyRect.height * 0.18),
        endRadius: bodyRect.width * 0.85,
        options: []
    )
    context.restoreGState()

    // 中间的光盘图形
    if let (symbol, _) = symbolImage(pointSize: size * 0.52) {
        let symbolSize = symbol.size
        let scale = min(size * 0.62 / symbolSize.width, size * 0.62 / symbolSize.height)
        let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
        let origin = NSPoint(
            x: (size - drawSize.width) / 2,
            y: (size - drawSize.height) / 2 - size * 0.01
        )
        NSColor.white.set()
        symbol.isTemplate = true
        symbol.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    } else {
        // 找不到 SF Symbol 时的兜底：画一个简单的圆环
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.28, dy: size * 0.28))
        ring.lineWidth = size * 0.07
        ring.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let rep = drawIcon(size: CGFloat(variant.pixels))
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("生成 \(variant.name) 失败\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

let symbolName = symbolImage(pointSize: 64)?.1 ?? "无（已用兜底圆环）"
print("使用图形：\(symbolName)")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}

let attributes = try? FileManager.default.attributesOfItem(atPath: icnsURL.path)
let size = (attributes?[.size] as? Int) ?? 0
print("已生成 \(icnsURL.path)（\(size) 字节）")
