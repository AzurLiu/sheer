// Draws the Sheer app icon (.iconset → .icns). 生成 Sheer 的 App 图标
// 用法：swift make_icon.swift <输出 .iconset 目录> [预览 PNG]
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// macOS 图标外形：超椭圆 |x|^n + |y|^n = 1（n≈5），曲率连续，比普通圆角更柔和
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let n: CGFloat = 5.2
    let p = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)   // Apple 图标网格：824 主体 + 投影留白
    let shape = squircle(body, 185)

    // Shadows are in device pixels, not scaled with the drawing: scale them by hand, or at small sizes the
    // blur runs past the canvas and is cut off in a visible square around the icon.
    // 投影的偏移和模糊不随坐标缩放，要手动乘上比例，否则小尺寸下投影超出画布、被裁成一圈方框
    let k = ctx.userSpaceToDeviceSpaceTransform.a
    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: color(0x000000, 0.28))
    ctx.addPath(shape); ctx.setFillColor(color(0x000000)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()

    // 背景：黑白主题，石墨灰 → 近黑的竖向渐变，顶部一圈极淡的柔光
    let bg = CGGradient(colorsSpace: space, colors: [color(0x3C3C40), color(0x1C1C1E), color(0x0A0A0B)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.midX, y: body.maxY - 200), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY - 200), endRadius: 520, options: [])

    do {
        // 极简：一道渐变 + 一条悬浮的玻璃菜单栏
        let bar = CGRect(x: body.minX + 120, y: body.maxY - 250, width: body.width - 240, height: 96)
        let path = CGPath(roundedRect: bar, cornerWidth: 48, cornerHeight: 48, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 30 * k, color: color(0x000000, 0.45))
        ctx.addPath(path); ctx.setFillColor(color(0xFFFFFF, 0.32)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0.0)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: bar.midY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: 1, dy: 1), cornerWidth: 47, cornerHeight: 47, transform: nil))
        ctx.setStrokeColor(color(0xFFFFFF, 0.55)); ctx.setLineWidth(2.5); ctx.strokePath()
    }
    ctx.restoreGState()

    // 细边：极淡的白色描边
    ctx.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5), 184))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    save(render(base), "\(outDir)/icon_\(base)x\(base).png")
    save(render(base * 2), "\(outDir)/icon_\(base)x\(base)@2x.png")
}
if CommandLine.arguments.count > 2 { save(render(1024), CommandLine.arguments[2]) }
