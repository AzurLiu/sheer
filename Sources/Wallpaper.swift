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
        case file(URL, dark: Bool, solar: Bool = false)   // can be rebuilt exactly from a file; solar: follow the sun
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

    private struct Key: Equatable { let url: URL; let opts: String; let frame: Int; let size: CGSize; let scale: CGFloat }
    private var fileCache: [CGDirectDisplayID: (Key, CGImage)] = [:]   // touched only on `queue`
    private let queue = DispatchQueue(label: "sheer.wallpaper", qos: .utility)

    private(set) var lastSource = "none"
    /// Whether the current wallpaper can only be obtained by capture (updated on every fetch).
    private(set) var needsCapture = false
    /// A Dynamic wallpaper following the sun: its frame changes through the day.
    private(set) var followsSun = false

    /// Wallpaper strip covering the top `barHeight` points of the screen, in pixels.
    /// nil means it can't be obtained accurately — the caller then shows the system menu bar
    /// rather than a wrong picture.
    func strip(for screen: NSScreen, barHeight: CGFloat, dark: Bool, completion: @escaping (CGImage?) -> Void) {
        let source = Self.resolve(dark: dark)
        if case .needsCapture = source { needsCapture = true } else { needsCapture = false }
        if case .file(_, _, true) = source { followsSun = true } else { followsSun = false }
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

        // Configuration.style. Dynamic (multi-image) wallpapers follow the sun for 0 and 1 (both confirmed
        // in light mode: frame 4 at 4° with style 1, frame 2 at -11° with style 0), 2 = light, 3 = dark.
        // Other wallpapers: 1 = light, 2 = dark, otherwise automatic (follows the appearance).
        var dark = systemDark, solar = false
        let style = (choice["Configuration"] as? Data)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["style"] as? Int
        if provider == "com.apple.wallpaper.choice.dynamic" {
            if style == 2 { dark = false } else if style == 3 { dark = true } else { solar = true }
        } else if style == 1 { dark = false } else if style == 2 { dark = true }

        // Picture wallpapers list their file.
        if let first = (choice["Files"] as? [Any])?.first {
            let str = (first as? [String: Any])?["relative"] as? String ?? first as? String
            if let str, let url = URL(string: str), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                return .file(url, dark: dark, solar: solar)
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
                if let heic = files.first(where: { $0.hasSuffix(".heic") }) { return .file(dir.appendingPathComponent(heic), dark: dark, solar: solar) }
                // Video-only folders: the desktop rests on the still of the same name when there is one
                // (verified: Sonoma → Desktop Pictures/Sonoma.heic, light/dark by appearance), else on frame 0.
                let still = systemPictures.appendingPathComponent(folder + ".heic")
                if fm.fileExists(atPath: still.path) { return .file(still, dark: dark) }
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
        let url: URL, dark: Bool, solar: Bool
        switch source {
        case .file(let u, let d, let sol): url = u; dark = d; solar = sol
        case .systemDefault:
            guard let u = screen.defaultURL else { return nil }
            url = u; dark = systemDark; solar = false
        case .needsCapture: return nil
        }
        let opts = screen.opts
        let frame = Self.frameIndex(url, dark: dark, solar: solar)
        let key = Key(url: url, opts: String(describing: opts), frame: frame,
                      size: CGSize(width: screen.size.width, height: barHeight), scale: screen.scale)
        if let (k, img) = fileCache[screen.id], k == key { return img }

        guard let full = Self.loadImage(url, frame: frame) else { return nil }

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

        // The desktop shows a wallpaper's own values unconverted on the display's gamut: sRGB images look
        // more saturated than a colour-managed copy, Display P3 ones (e.g. Ventura) look as authored.
        // So keep the image's numbers — render in its own RGB space — and tag the result with the display's.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = full.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? sRGB
        let scale = screen.scale
        let W = Int((sw * scale).rounded()), H = Int((barHeight * scale).rounded())
        guard W > 0, H > 0,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let fillSRGB = (fill.usingColorSpace(.sRGB) ?? .black).cgColor
        ctx.setFillColor(CGColor(colorSpace: space, components: fillSRGB.components ?? [0, 0, 0, 1]) ?? fillSRGB)
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
        guard let made = ctx.makeImage() else { return nil }
        let img = screen.colorSpace.flatMap { made.copy(colorSpace: $0) } ?? made
        fileCache[screen.id] = (key, img)
        return img
    }

    private static func loadImage(_ url: URL, frame: Int) -> CGImage? {
        if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            return try? gen.copyCGImage(at: .zero, actualTime: nil)
        }
        let lazy = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url.resolvingSymlinksInPath() as CFURL, lazy),
              CGImageSourceGetCount(src) > frame else { return nil }
        return CGImageSourceCreateImageAtIndex(src, frame, lazy)
    }

    /// Which image of a (possibly dynamic) HEIC the desktop shows.
    static func frameIndex(_ url: URL, dark: Bool, solar: Bool) -> Int {
        guard url.pathExtension.lowercased() == "heic",
              let src = CGImageSourceCreateWithURL(url.resolvingSymlinksInPath() as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 1, let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return 0 }
        let count = CGImageSourceGetCount(src)
        func plist(_ tagName: String) -> [String: Any]? {
            guard let tag = CGImageMetadataCopyTagWithPath(md, nil, "apple_desktop:\(tagName)" as CFString),
                  let b64 = CGImageMetadataTagCopyValue(tag) as? String, let data = Data(base64Encoded: b64) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        if solar, let si = plist("solar")?["si"] as? [[String: Any]], let i = Solar.frame(si), i < count { return i }
        for tagName in ["apr", "solar", "h24"] {
            guard let p = plist(tagName) else { continue }
            let ap = (p["ap"] as? [String: Any]) ?? p
            if let i = ap[dark ? "d" : "l"] as? Int, i < count { return i }
        }
        return 0
    }
}

/// Where the sun is, for Dynamic (sun-following) wallpapers. Location comes from the time zone (its
/// city in the system's zone.tab), which is what the desktop falls back to without Location Services.
enum Solar {
    /// The frame for now: walking the sun's daily path, the image of the last listed sun position
    /// passed — rising in the morning, setting in the afternoon. Matches the desktop: frame 0 (25°)
    /// at 16° in the afternoon, frame 4 (10°) at 4°.
    static func frame(_ si: [[String: Any]], at date: Date = Date()) -> Int? {
        guard let loc = location else { return nil }
        let entries: [(a: Double, z: Double, i: Int)] = si.compactMap {
            guard let a = ($0["a"] as? NSNumber)?.doubleValue, let z = ($0["z"] as? NSNumber)?.doubleValue,
                  let i = ($0["i"] as? NSNumber)?.intValue else { return nil }
            return (a, z, i)
        }
        guard !entries.isEmpty else { return nil }
        let sun = position(date, lat: loc.lat, lon: loc.lon)
        let morning = sun.az < 180
        let half = entries.filter { ($0.z < 180) == morning }
        guard !half.isEmpty else { return nil }
        if morning {   // rising: highest listed altitude already reached
            return (half.filter { $0.a <= sun.alt }.max { $0.a < $1.a } ?? half.min { $0.a < $1.a })?.i
        } else {       // setting: lowest listed altitude not yet gone below
            return (half.filter { $0.a >= sun.alt }.min { $0.a < $1.a } ?? half.max { $0.a < $1.a })?.i
        }
    }

    /// Latitude/longitude of the current time zone's city, from /usr/share/zoneinfo/zone.tab.
    static var location: (lat: Double, lon: Double)? {
        let id = TimeZone.current.identifier
        if let cached, cached.id == id { return cached.loc }
        guard let tab = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return nil }
        for line in tab.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3, cols[2] == id, let loc = parse(String(cols[1])) else { continue }
            cached = (id, loc)
            return loc
        }
        return nil
    }
    private static var cached: (id: String, loc: (lat: Double, lon: Double))?

    /// "+5024-10439" or "+404251-0740023" (±DDMM[SS]±DDDMM[SS]).
    private static func parse(_ s: String) -> (lat: Double, lon: Double)? {
        guard let split = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func deg(_ part: Substring, _ degDigits: Int) -> Double? {
            let sign: Double = part.first == "-" ? -1 : 1
            let d = part.dropFirst()
            guard d.count >= degDigits + 2, let dd = Double(d.prefix(degDigits)),
                  let mm = Double(d.dropFirst(degDigits).prefix(2)) else { return nil }
            let ss = d.count >= degDigits + 4 ? Double(d.dropFirst(degDigits + 2).prefix(2)) ?? 0 : 0
            return sign * (dd + mm / 60 + ss / 3600)
        }
        guard let lat = deg(s[..<split], 2), let lon = deg(s[split...], 3) else { return nil }
        return (lat, lon)
    }

    /// NOAA solar position: altitude above the horizon and azimuth clockwise from north, in degrees.
    static func position(_ date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double) {
        let r = Double.pi / 180
        let t = (date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545) / 36525
        let l0 = (280.46646 + t * (36000.76983 + 0.0003032 * t)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(m * r) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * m * r) * (0.019993 - 0.000101 * t) + sin(3 * m * r) * 0.000289
        let omega = 125.04 - 1934.136 * t
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(omega * r)
        let eps = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60 + 0.00256 * cos(omega * r)
        let decl = asin(sin(eps * r) * sin(lambda * r))
        let y = pow(tan(eps * r / 2), 2)
        let eqTime = 4 / r * (y * sin(2 * l0 * r) - 2 * e * sin(m * r) + 4 * e * y * sin(m * r) * cos(2 * l0 * r)
                              - 0.5 * y * y * sin(4 * l0 * r) - 1.25 * e * e * sin(2 * m * r))
        let utcMinutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        var ha = (utcMinutes + eqTime + 4 * lon) / 4 - 180
        if ha < -180 { ha += 360 }
        let cosZen = sin(lat * r) * sin(decl) + cos(lat * r) * cos(decl) * cos(ha * r)
        let zen = acos(max(-1, min(1, cosZen)))
        var az = atan2(sin(ha * r), cos(ha * r) * sin(lat * r) - tan(decl) * cos(lat * r)) / r + 180
        az = az.truncatingRemainder(dividingBy: 360)
        return (90 - zen / r, az)
    }
}
