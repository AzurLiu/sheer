// Shared helpers: localisation, screen IDs, image utilities.

import AppKit

/// Localised string from Resources/<lang>.lproj/Localizable.strings
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Debug-only tooling (self-check snapshots, diagnostic files) is compiled in only for `./build.sh --dev`.
enum Debug {
    #if SHEER_DEBUG
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "debug") }
    #else
    static let enabled = false
    #endif

    static func path(_ name: String) -> String { NSTemporaryDirectory() + "Sheer-" + name }

    static func write(_ text: String, _ name: String) {
        guard enabled else { return }
        try? text.write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    static func write(_ img: CGImage?, _ name: String) {
        guard enabled, let img else { return }
        writePNG(img, path(name))
    }
}

func writePNG(_ img: CGImage, _ path: String) {
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum ImageCompare {
    /// Downsample both strips to 96×2 and compare; mean difference < 1.5/255 counts as identical.
    static func looksSame(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, let x = tiny(a), let y = tiny(b) else { return false }
        var sum = 0
        for i in 0..<x.count where i % 4 != 3 { sum += abs(Int(x[i]) - Int(y[i])) }
        return Double(sum) / Double(96 * 2 * 3) < 1.5
    }

    private static func tiny(_ img: CGImage) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: 96, height: 2, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 96, height: 2))
        guard let d = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self), count: 96 * 2 * 4))
    }
}
