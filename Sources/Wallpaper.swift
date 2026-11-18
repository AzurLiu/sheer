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
import CoreLocation
import ScreenCaptureKit
import VideoToolbox

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
    /// The desktop may change image any moment (near a computed change, or out of step with the
    /// computation): the caller should fetch every few seconds instead of every minute.
    private(set) var checkSoon = false

    /// How close to a frame change, at any of the positions the desktop may be using, counts as "near".
    private static let nearChange: TimeInterval = 10 * 60
    /// How often to look at the desktop while a change may be due.
    private static let soonInterval: TimeInterval = 5
    /// How often to look at it otherwise (the desktop may still be using a position nobody predicted).
    private static let idleInterval: TimeInterval = 3 * 60

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

        // A sun-following wallpaper: the computed frame is right as long as the desktop works from the
        // inputs Sheer can see. It doesn't always (it keeps a position it was once given, for one), so
        // with Screen Recording allowed, look at which image the desktop actually shows: a tiny
        // capture, when the computed frame changes, every few minutes, and every few seconds while
        // the desktop's change may be due.
        checkSoon = false
        if case .file(let url, _, true) = source, CGPreflightScreenCaptureAccess() {
            let now = Date()
            let computed = Self.frameIndex(url, dark: false, solar: true, observed: false, at: now)
            // Which position the desktop times its frames by can't always be known, so look every few
            // seconds whenever any of the candidates is within minutes of a change: the bar then follows
            // within seconds whichever it is. Same while the desktop doesn't agree with the computation.
            Self.observedLock.lock(); let seen = Self.observed; Self.observedLock.unlock()
            let trusted = seen == nil || seen!.url != url || seen!.frame == computed
            let near = Solar.candidates.contains { place in
                let at = { (dt: TimeInterval) in
                    Self.frameIndex(url, dark: false, solar: true, observed: false, at: now.addingTimeInterval(dt), place: place)
                }
                let here = at(0)
                return at(-Self.nearChange) != here || at(Self.nearChange) != here
            }
            checkSoon = near || !trusted
            let due = computed != lastComputedFrame
                || now.timeIntervalSince(lastVerified) > (checkSoon ? Self.soonInterval - 0.5 : Self.idleInterval)
            lastComputedFrame = computed
            if due {
                lastVerified = Date()
                verifyFrame(url: url, screen: screen) { decode("file \(source)") }
                return
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

    func invalidate() { queue.async { self.fileCache.removeAll() }; lastVerified = .distantPast }

    // MARK: Which image a Dynamic wallpaper shows

    private var lastComputedFrame = -1
    private var lastVerified = Date.distantPast
    /// The frame seen on the desktop, for this file. Read on `queue` (frameIndex), written on main.
    private static let observedLock = NSLock()
    private static var observed: (url: URL, frame: Int)?
    private var frameThumbs: (url: URL, grids: [[Double]])?   // touched only on `queue`

    private func verifyFrame(url: URL, screen: NSScreen, then: @escaping () -> Void) {
        let aspect = Double(screen.frame.width / screen.frame.height)
        let displaySpace = screen.colorSpace?.cgColorSpace
        let display = screen.displayID
        let compare: ([Double]?) -> Void = { [weak self] seen in
            self?.queue.async { [weak self] in
                guard let self else { return }
                var frame: Int?
                if let seen {
                    if self.frameThumbs?.url != url {
                        self.frameThumbs = (url, Self.frameGrids(url, aspect: aspect))
                    }
                    let d: [Double] = self.frameThumbs!.grids.map { g in Self.distance(g, seen) }
                    // Accept a clear match only: the nearest frame close, the next one well apart.
                    let order = d.indices.sorted { d[$0] < d[$1] }
                    if let best = order.first, d[best] < 12, order.count < 2 || d[order[1]] > d[best] * 2 + 6 { frame = best }
                    Debug.write("\(Date()) desktop frame distances \(d.map { Int($0) }) -> \(frame.map(String.init) ?? "unclear")\n", "frame.txt")
                }
                Self.observedLock.lock(); Self.observed = frame.map { (url, $0) }; Self.observedLock.unlock()
                DispatchQueue.main.async { then() }
            }
        }
        // Captures are the display's own values: tag them so (see onDisplay).
        func tagged(_ shot: CGImage) -> CGImage { displaySpace.flatMap { shot.copy(colorSpace: $0) } ?? shot }
        if #available(macOS 14, *) {
            Task {
                var grid: [Double]?
                if let win = try? await Self.wallpaperWindow(for: screen) {
                    let cfg = SCStreamConfiguration()
                    cfg.width = 256; cfg.height = max(1, Int(256 / aspect)); cfg.showsCursor = false
                    if let shot = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg) {
                        grid = Self.grid(tagged(shot), aspect: aspect)
                    }
                }
                compare(grid)
            }
        } else {
            // Before macOS 14 (no SCScreenshotManager, and no ScreenCaptureKit at all before 12.3).
            DispatchQueue.global(qos: .utility).async {
                compare(Self.legacyCapture(display, rows: nil).map { Self.grid(tagged($0), aspect: aspect) })
            }
        }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        var sum = 0.0
        for i in a.indices { sum += abs(a[i] - b[i]) }
        return sum / Double(a.count)
    }

    /// 16×16 colour grid of the image, cropped to the screen's shape the way the desktop fills it.
    private static func grid(_ img: CGImage, aspect: Double) -> [Double] {
        let w = Double(img.width), h = Double(img.height)
        var r = CGRect(x: 0, y: 0, width: w, height: h)
        if w / h > aspect { let nw = h * aspect; r = CGRect(x: (w - nw) / 2, y: 0, width: nw, height: h) }
        else { let nh = w / aspect; r = CGRect(x: 0, y: (h - nh) / 2, width: w, height: nh) }
        guard let c = img.cropping(to: r.integral) else { return [] }
        let n = 16
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: n, height: n))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(n * n * 4)).filter { $0 % 4 != 3 }.map { Double(p[$0]) }
    }

    private static func frameGrids(_ url: URL, aspect: Double) -> [[Double]] {
        guard let src = CGImageSourceCreateWithURL(url.resolvingSymlinksInPath() as CFURL, nil) else { return [] }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary
        return (0..<CGImageSourceGetCount(src)).map { i in
            CGImageSourceCreateThumbnailAtIndex(src, i, opts).map { grid($0, aspect: aspect) } ?? []
        }
    }

    private func done(_ img: CGImage?, _ source: String, _ completion: (CGImage?) -> Void) {
        lastSource = source
        Debug.write("\(Date()) \(source) \(img.map { "\($0.width)x\($0.height)" } ?? "nil")\n", "wallpaper.txt")
        Debug.write(img, "wallpaper.png")
        completion(img)
    }

    // MARK: Capture

    /// The Dock's wallpaper window on this display.
    @available(macOS 12.3, *)
    private static func wallpaperWindow(for screen: NSScreen) async throws -> SCWindow? {
        let displayBounds = CGDisplayBounds(screen.displayID)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.first(where: {
            isWallpaperTitle($0.title) &&
            $0.owningApplication?.bundleIdentifier == "com.apple.dock" &&
            abs($0.frame.minX - displayBounds.minX) < 1 && abs($0.frame.minY - displayBounds.minY) < 1
        })
    }

    /// The Dock titles its wallpaper windows "Wallpaper-…" from macOS 14 on, "Desktop Picture - …" before
    /// (on macOS 12 and 13; not yet seen there).
    private static func isWallpaperTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        if title.hasPrefix("Wallpaper") { return true }
        if #unavailable(macOS 14) { return title.hasPrefix("Desktop Picture") }
        return false
    }

    /// macOS 12 and 13 have no SCScreenshotManager: capture the Dock's wallpaper window on this display
    /// through CGWindowList. `rows`: the top rows only, at full resolution; nil: the whole window at
    /// nominal resolution (to tell which image a Dynamic wallpaper shows).
    @available(macOS, deprecated: 14, message: "SCScreenshotManager from macOS 14 on")
    private static func legacyCapture(_ display: CGDirectDisplayID, rows: CGFloat?) -> CGImage? {
        let bounds = CGDisplayBounds(display)
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let candidates = list.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == dock,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            return abs(b.minX - bounds.minX) < 1 && abs(b.minY - bounds.minY) < 1 && abs(b.width - bounds.width) < 1
        }
        // By its title; failing that, the Dock's window at the desktop level.
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        guard let info = candidates.first(where: { isWallpaperTitle($0[kCGWindowName as String] as? String) })
                ?? candidates.first(where: { ($0[kCGWindowLayer as String] as? Int) == desktopLevel }),
              let id = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }) else { return nil }
        let rect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: rows ?? bounds.height)
        return CGWindowListCreateImage(rect, .optionIncludingWindow, id,
                                       rows == nil ? [.boundsIgnoreFraming, .nominalResolution] : [.boundsIgnoreFraming, .bestResolution])
    }

    /// Captures come back as untagged device RGB, which drawing treats as sRGB and converts — shifting
    /// the colours away from the desktop. They are the display's own values: tag them so.
    static func onDisplay(_ img: CGImage, _ screen: NSScreen) -> CGImage {
        screen.colorSpace?.cgColorSpace.flatMap { img.copy(colorSpace: $0) } ?? img
    }

    @available(macOS 12.3, *)
    static func mirrorWindow(for screen: NSScreen) async throws -> SCWindow? { try await wallpaperWindow(for: screen) }
    @available(macOS 12.3, *)
    static func mirrorConfig(_ win: SCWindow, barHeight: CGFloat, scale: CGFloat) -> SCStreamConfiguration {
        stripConfig(win, barHeight: barHeight, scale: scale)
    }

    @available(macOS 12.3, *)
    private static func stripConfig(_ win: SCWindow, barHeight: CGFloat, scale: CGFloat) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: 0, y: 0, width: win.frame.width, height: barHeight)
        cfg.width = Int(win.frame.width * scale)
        cfg.height = Int(barHeight * scale)
        cfg.showsCursor = false
        if #available(macOS 14, *) { cfg.ignoreShadowsSingleWindow = true }
        return cfg
    }

    private func captureStrip(for screen: NSScreen, barHeight: CGFloat, completion: @escaping (CGImage?) -> Void) {
        let scale = screen.backingScaleFactor
        let display = screen.displayID
        guard #available(macOS 14, *) else {
            // Before macOS 14 (no SCScreenshotManager, and no ScreenCaptureKit at all before 12.3).
            let space = screen.colorSpace?.cgColorSpace   // read NSScreen here, on the main thread
            DispatchQueue.global(qos: .utility).async {
                let image = Self.legacyCapture(display, rows: barHeight).map { shot in space.flatMap { shot.copy(colorSpace: $0) } ?? shot }
                DispatchQueue.main.async { completion(image) }
            }
            return
        }
        Task {
            var image: CGImage?
            do {
                if let win = try await Self.wallpaperWindow(for: screen) {
                    let shot = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: win),
                        configuration: Self.stripConfig(win, barHeight: barHeight, scale: scale))
                    image = Self.onDisplay(shot, screen)
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
        guard let root = storeRoot() else {
            if #unavailable(macOS 14) { return resolveLegacy(dark: systemDark) }
            return .systemDefault
        }

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

    /// macOS 12 and 13 have no wallpaper store; NSWorkspace reports each display's picture there.
    private static func resolveLegacy(dark: Bool) -> Source {
        let urls = NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        // A folder ("Change picture" every so often): which of its pictures shows isn't reported.
        if urls.contains(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) {
            return .needsCapture("picture folder")
        }
        // A Dynamic wallpaper (images timed by the sun) set to its default, "Dynamic", follows the sun.
        // Its Light and Dark (Still) settings aren't reported; with Screen Recording allowed, Sheer
        // looks at which image the desktop shows (see verifyFrame).
        if let url = urls.first, urls.allSatisfy({ $0 == url }), isSunTimed(url) { return .file(url, dark: dark, solar: true) }
        return .systemDefault
    }

    /// A HEIC with several images and a sun schedule (apple_desktop:solar).
    private static func isSunTimed(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "heic",
              let src = CGImageSourceCreateWithURL(url.resolvingSymlinksInPath() as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 1, let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return false }
        return CGImageMetadataCopyTagWithPath(md, nil, "apple_desktop:solar" as CFString) != nil
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
    static func frameIndex(_ url: URL, dark: Bool, solar: Bool, observed useObserved: Bool = true, at date: Date = Date(),
                           place: (lat: Double, lon: Double)? = nil) -> Int {
        if solar && useObserved {
            observedLock.lock(); let seen = observed; observedLock.unlock()
            if let seen, seen.url == url { return seen.frame }
        }
        guard url.pathExtension.lowercased() == "heic",
              let src = CGImageSourceCreateWithURL(url.resolvingSymlinksInPath() as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 1, let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return 0 }
        let count = CGImageSourceGetCount(src)
        func plist(_ tagName: String) -> [String: Any]? {
            guard let tag = CGImageMetadataCopyTagWithPath(md, nil, "apple_desktop:\(tagName)" as CFString),
                  let b64 = CGImageMetadataTagCopyValue(tag) as? String, let data = Data(base64Encoded: b64) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }
        if solar, let si = plist("solar")?["si"] as? [[String: Any]], let i = Solar.frame(si, at: date, place: place), i < count { return i }
        for tagName in ["apr", "solar", "h24"] {
            guard let p = plist(tagName) else { continue }
            let ap = (p["ap"] as? [String: Any]) ?? p
            if let i = ap[dark ? "d" : "l"] as? Int, i < count { return i }
        }
        return 0
    }
}

/// Which image of a Dynamic (sun-following) wallpaper the desktop shows. This mirrors the system's own
/// choice (SolarDesktop in DynamicDesktop.framework; compared with it at 66,816 moments over a year
/// and eight places, with no difference): the listed image nearest in altitude to the sun, among
/// those listed for the same half of the day (sun rising: azimuth below 180°).
enum Solar {
    /// `place`: where to stand instead of `location` (to see when another candidate position changes frame).
    static func frame(_ si: [[String: Any]], at date: Date = Date(), place: (lat: Double, lon: Double)? = nil) -> Int? {
        let entries: [(a: Double, z: Double, i: Int)] = si.compactMap {
            guard let a = ($0["a"] as? NSNumber)?.doubleValue, let z = ($0["z"] as? NSNumber)?.doubleValue,
                  let i = ($0["i"] as? NSNumber)?.intValue else { return nil }
            return (a, z, i)
        }
        guard !entries.isEmpty else { return nil }
        let loc = place ?? location
        let sun = systemPosition(date, lat: loc.lat, lon: loc.lon) ?? position(date, lat: loc.lat, lon: loc.lon)
        let half = entries.filter { ($0.z < 180) == (sun.az < 180) }
        return (half.isEmpty ? entries : half).min { abs($0.a - sun.alt) < abs($1.a - sun.alt) }?.i
    }

    /// Where the desktop places the sun's observer. Allowed to use Location Services (the "Setting
    /// time zone" system service), it takes the Mac's real position: Sheer uses the same once it has
    /// been allowed to (see Location), and until then the time zone's city stands in.
    /// With the service off, the desktop was seen standing at the time zone's city (a Mac set to
    /// America/Regina but actually near Edmonton changed frames on Regina's times, minutes to half an hour
    /// away from Edmonton's or the meridian point's, on two days). The other candidates still decide
    /// when Sheer looks at the desktop closely (see `candidates`).
    static var location: (lat: Double, lon: Double) {
        if desktopUsesRealLocation, let place = Location.shared.coordinate ?? zoneCity { return place }
        return zoneCity ?? meridianPoint
    }

    /// Every position the desktop might be timing its frames by: the one Sheer computes with, the Mac's
    /// last known real position (a desktop may keep it after the service is switched off), the time
    /// zone's city, and the equator at the time zone's meridian (standard offset × Earth's rotation rate).
    static var candidates: [(lat: Double, lon: Double)] {
        var all: [(lat: Double, lon: Double)] = [location]
        for p in [Location.shared.lastKnown, zoneCity, meridianPoint] {
            if let p, !all.contains(where: { abs($0.lat - p.lat) < 0.01 && abs($0.lon - p.lon) < 0.01 }) { all.append(p) }
        }
        return all
    }

    private static var meridianPoint: (lat: Double, lon: Double) {
        let zone = TimeZone.current
        let standardOffset = Double(zone.secondsFromGMT()) - zone.daylightSavingTimeOffset()
        return (0, standardOffset * 7.292115e-5 * 180 / .pi)
    }

    /// The wallpaper extensions locate the Mac on behalf of TimeZone.bundle, the "Setting time zone"
    /// system service: whether that is switched on is in locationd's client list. (CoreLocation's own
    /// status calls answer "not determined" for it whatever the switch says. Seen on a Mac where
    /// turning the service on moved the desktop to the real position's frame within the second.)
    static var desktopUsesRealLocation: Bool {
        #if SHEER_DEBUG
        if UserDefaults.standard.bool(forKey: "pretendDesktopLocation") { return true }   // to try the location flow
        #endif
        if let checked, Date().timeIntervalSince(checked.at) < 60 { return checked.real }
        var real = false
        if CLLocationManager.locationServicesEnabled(),
           let data = try? Data(contentsOf: URL(fileURLWithPath: "/var/db/locationd/clients.plist")),
           let clients = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            real = clients.values.contains {
                guard let c = $0 as? [String: Any], (c["BundlePath"] as? String) == "/System/Library/LocationBundles/TimeZone.bundle" else { return false }
                return (c["Authorized"] as? NSNumber)?.boolValue == true
            }
        }
        checked = (Date(), real)
        return real
    }
    private static var checked: (at: Date, real: Bool)?

    /// The sun as the system computes it (GeoServices, the desktop's own source), so frames change at
    /// the same moment. nil if that class ever goes away; the NOAA formula below then takes over.
    private static func systemPosition(_ date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double)? {
        typealias InitFn = @convention(c) (UnsafeRawPointer, Selector, CLLocationCoordinate2D, UnsafeRawPointer, Int) -> UnsafeRawPointer?
        typealias GetFn = @convention(c) (UnsafeRawPointer, Selector) -> Double
        let initSel = NSSelectorFromString("initWithLocation:date:body:")
        let altSel = NSSelectorFromString("altitude"), azSel = NSSelectorFromString("azimuth")
        guard let cls = celestialClass, let initM = class_getInstanceMethod(cls, initSel),
              let altM = class_getInstanceMethod(cls, altSel), let azM = class_getInstanceMethod(cls, azSel),
              let raw = class_createInstance(cls, 0) else { return nil }
        let allocated = Unmanaged.passRetained(raw as AnyObject).toOpaque()   // init consumes this reference
        let nsDate = date as NSDate
        guard let sun = unsafeBitCast(method_getImplementation(initM), to: InitFn.self)(
            allocated, initSel, CLLocationCoordinate2D(latitude: lat, longitude: lon),
            Unmanaged.passUnretained(nsDate).toOpaque(), 0 /* the sun */) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(sun).release() }
        let alt = unsafeBitCast(method_getImplementation(altM), to: GetFn.self)(sun, altSel)
        let az = unsafeBitCast(method_getImplementation(azM), to: GetFn.self)(sun, azSel)
        return alt.isFinite && az.isFinite ? (alt, az) : nil
    }
    private static let celestialClass: AnyClass? = {
        dlopen("/System/Library/PrivateFrameworks/GeoServices.framework/GeoServices", RTLD_LAZY)
        return NSClassFromString("GEOHorizontalCelestialBodyData")
    }()

    /// Latitude/longitude of the current time zone's city, from /usr/share/zoneinfo/zone.tab.
    private static var zoneCity: (lat: Double, lon: Double)? {
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

    /// NOAA solar position (fallback): altitude above the horizon and azimuth clockwise from north, in degrees.
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


// MARK: - Live mirror

/// Streams the strip of a live-rendered wallpaper while it moves (it plays a short animation as the
/// screen unlocks), so the bar moves with it instead of catching up with crossfades afterwards.
/// Needs ScreenCaptureKit's streams (macOS 12.3); before that the bar catches up with crossfades.
@available(macOS 12.3, *)
final class LiveMirror: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "sheer.mirror")
    private let onFrame: (CGImage) -> Void
    private var screen: NSScreen?

    init(onFrame: @escaping (CGImage) -> Void) { self.onFrame = onFrame }

    static func start(for screen: NSScreen, barHeight: CGFloat, seconds: TimeInterval,
                      onFrame: @escaping (CGImage) -> Void) -> LiveMirror {
        let m = LiveMirror(onFrame: onFrame)
        m.screen = screen
        let scale = screen.backingScaleFactor
        Task {
            guard let win = try? await WallpaperProvider.mirrorWindow(for: screen) else { return }
            let cfg = WallpaperProvider.mirrorConfig(win, barHeight: barHeight, scale: scale)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.queueDepth = 3
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
            do {
                try s.addStreamOutput(m, type: .screen, sampleHandlerQueue: m.queue)
                try await s.startCapture()
                m.stream = s
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { m.stop() }
            } catch {
                NSLog("Sheer: live mirror failed: \(error)")
            }
        }
        return m
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
        guard let img else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onFrame(self.screen.map { WallpaperProvider.onDisplay(img, $0) } ?? img)
        }
    }
}
