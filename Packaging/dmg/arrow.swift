// Draws the Sheer.dmg window's only decoration: a hand-drawn looping arrow from Sheer to Applications, on a
// transparent background so the window keeps the system's light or dark colour. 安装包窗口里的手绘绕圈箭头（透明背景）
// Usage: arrow <output.png> <scale>   (1 for the 1x image, 2 for Retina)
// Layout must match Packaging/dmg/make_template.sh: a 520×300 pt window, 128 pt icons centred at
// (140, 140) and (380, 140).
import AppKit

let size = CGSize(width: 520, height: 300)
let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else { print("usage: arrow <out.png> <scale>"); exit(1) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.translateBy(x: 0, y: size.height)   // top-left origin, like Finder's icon positions
ctx.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
ctx.clear(CGRect(origin: .zero, size: size))

// Mid grey: readable on both the light and the dark window background.
let grey = CGColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)
ctx.setStrokeColor(grey)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// In the gap between the icons (they end at x = 204 and start at x = 316): out of Sheer, a little loop,
// then into the Applications folder.
let path = CGMutablePath()
path.move(to: CGPoint(x: 212, y: 150))
path.addCurve(to: CGPoint(x: 262, y: 118), control1: CGPoint(x: 230, y: 150), control2: CGPoint(x: 268, y: 140))
path.addCurve(to: CGPoint(x: 250, y: 104), control1: CGPoint(x: 258, y: 100), control2: CGPoint(x: 246, y: 98))
path.addCurve(to: CGPoint(x: 300, y: 136), control1: CGPoint(x: 254, y: 118), control2: CGPoint(x: 284, y: 140))
ctx.addPath(path)
ctx.strokePath()

// Arrowhead, along the stroke's last direction.
let end = CGPoint(x: 300, y: 136), before = CGPoint(x: 290, y: 133)
let angle = atan2(end.y - before.y, end.x - before.x), head: CGFloat = 11, spread: CGFloat = .pi / 5
ctx.move(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
ctx.addLine(to: end)
ctx.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
