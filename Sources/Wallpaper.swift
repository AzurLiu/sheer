// Produces the strip of desktop wallpaper that sits behind the menu bar.
//
// Two sources:
//   1. The wallpaper file, resolved from the system wallpaper store (no permission needed).
//      Covers still images, dynamic HEICs and Apple's video wallpapers (their resting frame is frame 0).
//   2. A one-off capture of the real wallpaper window (needs Screen Recording). Used only when the
//      wallpaper has no file: live-rendered wallpapers (Macintosh, Aerials), shuffling wallpapers,
//      or different wallpapers per display / Space.

import AppKit
import AVFoundation
import ScreenCaptureKit

final class WallpaperProvider {
    enum Source: Equatable {
        case file(URL, dark: Bool)   // can be rebuilt exactly from a file
        case systemDefault           // the default picture reported by NSWorkspace
        case needsCapture(String)    // no file: only a capture is accurate
    }

    /// Screen properties collected on the main thread for background decoding.
    private struct ScreenInfo {
        let id: CGDirectDisplayID
        let size: CGSize
        let scale: CGFloat
        let colorSpace: CGColorSpace?
        let defaultURL: URL?
        let opts: [NSWorkspace.DesktopImageOptionKey: Any]
        init(_ screen: NSScreen) {
            id = screen.displayID
            size = screen.frame.size
            scale = screen.backingScaleFactor
            colorSpace = screen.colorSpace?.cgColorSpace
            defaultURL = NSWorkspace.shared.desktopImageURL(for: screen)
            opts = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        }
    }

    private struct Key: Equatable { let url: URL; let opts: String; let dark: Bool; let size: CGSize; let scale: CGFloat }
    private var fileCache: [CGDirectDisplayID: (Key, CGImage)] = [:]   // touched only on `queue`
    private let queue = DispatchQueue(label: "sheer.wallpaper", qos: .utility)

    private(set) var lastSource = "none"
    /// Whether the current wallpaper can only be obtained by capture (updated on every fetch).
    private(set) var needsCapture = false

    /// Wallpaper strip covering the top `barHeight` points of the screen, in pixels.
    /// nil means it can't be obtained accurately — the caller then shows the system menu bar
    /// rather than a wrong picture.
    func strip(for screen: NSScreen, barHeight: CGFloat, dark: Bool, completion: @escaping (CGImage?) -> Void) {
        let source = Self.resolve(dark: dark)
        if case .needsCapture = source { needsCapture = true } else { needsCapture = false }
        let info = ScreenInfo(screen)

        let decode = { [weak self] (label: String) in
            guard let self else { return }
            self.queue.async {
                let img = self.fileStrip(source, info, barHeight: barHeight, dark: dark)
                DispatchQueue.main.async { self.done(img, label, completion) }
            }
        }

        if needsCapture && CGPreflightScreenCaptureAccess() {
            captureStrip(for: screen, barHeight: barHeight) { [weak self] img in
                self?.done(img, img == nil ? "capture failed" : "capture", completion)
            }
            return
        }
        if case .needsCapture(let why) = source {
            done(nil, "needs Screen Recording (\(why))", completion)
        } else {
            decode("file \(source)")
        }
    }

    func invalidate() { queue.async { self.fileCache.removeAll() } }

    private func done(_ img: CGImage?, _ source: String, _ completion: (CGImage?) -> Void) {
        lastSource = source
        Debug.write("\(Date()) \(source) \(img.map { "\($0.width)x\($0.height)" } ?? "nil")\n", "wallpaper.txt")
        Debug.write(img, "wallpaper.png")
        completion(img)
    }

    // MARK: Capture

    private func captureStrip(for screen: NSScreen, barHeight: CGFloat, completion: @escaping (CGImage?) -> Void) {
        let displayBounds = CGDisplayBounds(screen.displayID)
        let scale = screen.backingScaleFactor
        Task {
            var image: CGImage?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let win = content.windows.first(where: {
                    ($0.title ?? "").hasPrefix("Wallpaper") &&
                    $0.owningApplication?.bundleIdentifier == "com.apple.dock" &&
                    abs($0.frame.minX - displayBounds.minX) < 1 && abs($0.frame.minY - displayBounds.minY) < 1
                }) {
                    let cfg = SCStreamConfiguration()
                    cfg.sourceRect = CGRect(x: 0, y: 0, width: win.frame.width, height: barHeight)
                    cfg.width = Int(win.frame.width * scale)
                    cfg.height = Int(barHeight * scale)
                    cfg.showsCursor = false
                    cfg.ignoreShadowsSingleWindow = true
                    image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg)
                }
            } catch {
                NSLog("Sheer: wallpaper capture failed: \(error)")
            }
            let result = image
            await MainActor.run { completion(result) }
        }
    }

    // MARK: Resolving the wallpaper from the system store

    static let storeIndexURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    private static let systemPictures = URL(fileURLWithPath: "/System/Library/Desktop Pictures")

    private static func storeRoot() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeIndexURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// macOS 14+ keeps the wallpaper choice in Index.plist; NSWorkspace.desktopImageURL often still
    /// reports the old default picture there.
    static func resolve(dark systemDark: Bool) -> Source {
        guard let root = storeRoot() else { return .systemDefault }

        // Different wallpapers per display or per Space: one global file can't be right everywhere.
        if let displays = root["Displays"] as? [String: Any], !displays.isEmpty { return .needsCapture("per-display wallpaper") }
        if let spaces = root["Spaces"] as? [String: Any], !spaces.isEmpty { return .needsCapture("per-Space wallpaper") }

        guard let all = root["AllSpacesAndDisplays"] as? [String: Any],
              let linked = (all["Linked"] ?? all["Desktop"]) as? [String: Any],
              let content = linked["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first,
              let provider = choice["Provider"] as? String else { return .systemDefault }

        if let shuffle = content["Shuffle"] as? String, shuffle != "$null" { return .needsCapture("shuffle") }
        if content["Shuffle"] is [String: Any] { return .needsCapture("shuffle") }
        if provider == "default" { return .systemDefault }

        // Appearance: Configuration.style 1 = light, 2 = dark, otherwise follow the system.
        var dark = systemDark
        if let cfg = choice["Configuration"] as? Data,
           let c = try? PropertyListSerialization.propertyList(from: cfg, format: nil) as? [String: Any],
           let style = c["style"] as? Int {
            if style == 1 { dark = false } else if style == 2 { dark = true }
        }

        // Picture wallpapers list their file.
        if let first = (choice["Files"] as? [Any])?.first {
            let str = (first as? [String: Any])?["relative"] as? String ?? first as? String
            if let str, let url = URL(string: str), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                return .file(url, dark: dark)
            }
        }

        // Built-in wallpapers: com.apple.wallpaper.choice.<name> → /System/Library/Desktop Pictures/.wallpapers/<Name>
        if provider.hasPrefix("com.apple.wallpaper.choice.") {
            let key = provider.replacingOccurrences(of: "com.apple.wallpaper.choice.", with: "").lowercased()
            let fm = FileManager.default
            let wallDir = systemPictures.appendingPathComponent(".wallpapers")
            let folders = ((try? fm.contentsOfDirectory(atPath: wallDir.path)) ?? []).filter {
                $0.lowercased().replacingOccurrences(of: " ", with: "-") == key ||
                $0.lowercased().replacingOccurrences(of: " ", with: "") == key.replacingOccurrences(of: "-", with: "")
            }
            for folder in folders {
                let dir = wallDir.appendingPathComponent(folder)
                let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                if let heic = files.first(where: { $0.hasSuffix(".heic") }) { return .file(dir.appendingPathComponent(heic), dark: dark) }
                // Video-only wallpapers (e.g. Sonoma): the desktop rests on frame 0 (verified pixel-by-pixel).
                let movs = files.filter { $0.hasSuffix(".mov") && !$0.contains("Portrait") }
                if let mov = movs.first(where: { $0.contains(dark ? "Dark" : "Light") }) ?? movs.first {
                    return .file(dir.appendingPathComponent(mov), dark: dark)
                }
            }
        }
        return .needsCapture(provider)
    }

    // MARK: Decoding a file (background queue)

    private func fileStrip(_ source: Source, _ screen: ScreenInfo, barHeight: CGFloat, dark systemDark: Bool) -> CGImage? {
        let url: URL, dark: Bool
        switch source {
        case .file(let u, let d): url = u; dark = d
        case .systemDefault:
            guard let u = screen.defaultURL else { return nil }
            url = u; dark = systemDark
        case .needsCapture: return nil
        }
        let opts = screen.opts
        let key = Key(url: url, opts: String(describing: opts), dark: dark,
                      size: CGSize(width: screen.size.width, height: barHeight), scale: screen.scale)
        if let (k, img) = fileCache[screen.id], k == key { return img }

        guard let full = Self.loadImage(url, dark: dark) else { return nil }

        let scaling = (opts[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let allowClipping = (opts[.allowClipping] as? NSNumber)?.boolValue ?? true
        let fill = (opts[.fillColor] as? NSColor) ?? .black

        let sw = screen.size.width, sh = screen.size.height
        let iw = CGFloat(full.width), ih = CGFloat(full.height)
        let drawn: CGRect   // screen coordinates, top-left origin
        switch scaling {
        case .scaleAxesIndependently:
            drawn = CGRect(x: 0, y: 0, width: sw, height: sh)
        case .scaleNone:
            drawn = CGRect(x: (sw - iw / screen.scale) / 2, y: (sh - ih / screen.scale) / 2,
                           width: iw / screen.scale, height: ih / screen.scale)
        default:
            let s = allowClipping ? max(sw / iw, sh / ih) : min(sw / iw, sh / ih)
            drawn = CGRect(x: (sw - iw * s) / 2, y: (sh - ih * s) / 2, width: iw * s, height: ih * s)
        }

        let scale = screen.scale
        let W = Int((sw * scale).rounded()), H = Int((barHeight * scale).rounded())
        guard W > 0, H > 0,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor((fill.usingColorSpace(.sRGB) ?? .black).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // Decode only the rows under the menu bar (tiled HEICs decode just their top tiles: ~¼ the memory).
        let k = ih / drawn.height
        let y0 = max(0, floor((0 - drawn.minY) * k) - 2)
        let y1 = min(ih, ceil((barHeight - drawn.minY) * k) + 2)
        guard y1 > y0, let part = full.cropping(to: CGRect(x: 0, y: y0, width: iw, height: y1 - y0)) else { return nil }
        let top = drawn.minY + y0 / k
        let h = (y1 - y0) / k
        ctx.draw(part, in: CGRect(x: drawn.minX * scale, y: (barHeight - top - h) * scale,
                                  width: drawn.width * scale, height: h * scale))
        // The desktop shows a wallpaper's sRGB values unconverted on the display's own (wider) gamut,
        // so it looks more saturated than a colour-managed copy. Tag the strip the same way to match it.
        guard let made = ctx.makeImage() else { return nil }
        let img = screen.colorSpace.flatMap { made.copy(colorSpace: $0) } ?? made
        fileCache[screen.id] = (key, img)
        return img
    }

    private static func loadImage(_ url: URL, dark: Bool) -> CGImage? {
        if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return try? gen.copyCGImage(at: .zero, actualTime: nil)
        }
        let lazy = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url.resolvingSymlinksInPath() as CFURL, lazy),
              CGImageSourceGetCount(src) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, dynamicIndex(src, dark: dark), lazy)
    }

    /// Dynamic HEIC wallpapers contain several images; pick the light or dark one.
    private static func dynamicIndex(_ src: CGImageSource, dark: Bool) -> Int {
        guard CGImageSourceGetCount(src) > 1, let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return 0 }
        for tagName in ["apr", "solar", "h24"] {
            guard let tag = CGImageMetadataCopyTagWithPath(md, nil, "apple_desktop:\(tagName)" as CFString),
                  let b64 = CGImageMetadataTagCopyValue(tag) as? String,
                  let data = Data(base64Encoded: b64),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let ap = (plist["ap"] as? [String: Any]) ?? plist
            if let i = ap[dark ? "d" : "l"] as? Int, i < CGImageSourceGetCount(src) { return i }
        }
        return 0
    }
}
