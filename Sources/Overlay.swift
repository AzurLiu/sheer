// The overlay that replaces the menu bar's background, and the soft legibility gradient.
//
// macOS 15 draws the menu bar background and the app-menu titles in one WindowServer window
// ("Menubar", level 24); status items are separate windows at level 25. Sheer puts a click-through
// window at level 24, sublevel 1 — above the system menu bar, below the status items — that paints
// the wallpaper strip plus the menu titles at their exact positions.

import AppKit
import ColorSync

// MARK: - Legibility gradient (like macOS 26/27: a faint gradient at the top of the wallpaper)

enum Scrim {
    /// Total gradient height = menu bar height × spread. The part below the bar lives in a
    /// desktop-level window, so it only ever shows over the wallpaper.
    static let spread: CGFloat = 2.4
    /// Always-on faint base (as on macOS 26/27) and the ceiling for busy/bright wallpapers.
    static let base: CGFloat = 0.12
    static let maxTop: CGFloat = 0.38

    /// Ease-out: a0 at the top, decaying as (1-t)^2.2 to zero — no visible edge.
    static func gradient(top a0: CGFloat, dark: Bool) -> NSGradient? {
        let c = dark ? NSColor.black : NSColor.white
        let n = 16
        var colors: [NSColor] = []
        var locs: [CGFloat] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            colors.append(c.withAlphaComponent(a0 * pow(1 - t, 2.2)))
            locs.append(t)
        }
        return locs.withUnsafeBufferPointer { NSGradient(colors: colors, atLocations: $0.baseAddress, colorSpace: .sRGB) }
    }

    /// Attenuation at the vertical centre of the menu titles.
    static var textFactor: CGFloat { pow(1 - 0.5 / spread, 2.2) }

    /// Draw in a flipped view whose top edge is `offset` points below the top of the screen.
    static func draw(top a0: CGFloat, dark: Bool, barHeight: CGFloat, offset: CGFloat) {
        guard a0 > 0.005 else { return }
        gradient(top: a0, dark: dark)?.draw(from: NSPoint(x: 0, y: -offset),
                                             to: NSPoint(x: 0, y: barHeight * spread - offset), options: [])
    }
}

final class DesktopScrimView: NSView {
    var a0: CGFloat = 0 { didSet { if a0 != oldValue { needsDisplay = true } } }
    var dark = false { didSet { if dark != oldValue { needsDisplay = true } } }
    var barHeight: CGFloat = 37 { didSet { if barHeight != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Scrim.draw(top: a0, dark: dark, barHeight: barHeight, offset: barHeight)
    }
}

/// The part of the gradient below the menu bar: above the wallpaper, below desktop icons and all windows.
final class DesktopScrimWindow: NSPanel {
    let view = DesktopScrimView()
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = OverlayWindow.allSpaces
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        title = "Sheer Scrim"
        contentView = view
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Menu bar view

struct WindowShadow: Equatable {
    var rect: CGRect      // window frame in the bar view's (flipped) coordinates
    var active: Bool      // key window: larger, darker shadow
}

final class BarView: NSView {
    var wallpaper: CGImage? {
        didSet {
            // Crossfade like the system's own wallpaper transition.
            if oldValue != nil, wallpaper != nil, window?.isVisible == true, let layer {
                let t = CATransition()
                t.type = .fade
                t.duration = 0.45
                t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(t, forKey: "wallpaperFade")
            }
            measureWallpaper()
            needsDisplay = true
        }
    }
    var titles: [MenuTitle] = [] { didSet { if titles != oldValue { needsDisplay = true } } }
    /// Offset from global menu-title coordinates to this view's coordinates.
    var origin: CGPoint = .zero { didSet { if origin != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    /// Windows whose top edge is just below the bar: their shadows reach up under the menu bar.
    var shadows: [WindowShadow] = [] { didSet { if shadows != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    /// Light text on a dark gradient (true) or dark text on a light one. Like macOS 26, the text follows
    /// the wallpaper: whichever colour reads with less gradient wins, so a bright wallpaper isn't muddied
    /// by a dark gradient. On a near tie it follows the system menu bar.
    var isDark: Bool {
        let system = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard wallpaper != nil else { return system }
        let light = scrimAlpha(darkText: false), dark = scrimAlpha(darkText: true)
        return system ? !(dark + 0.05 < light) : light + 0.05 < dark
    }

    // Luminance of the parts of the wallpaper least favourable to text (90th / 10th percentile, linear 0…1).
    private var lumBright: CGFloat = 0
    private var lumDark: CGFloat = 1

    private func measureWallpaper() {
        guard let img = wallpaper,
              let ctx = CGContext(data: nil, width: 128, height: 4, bitsPerComponent: 8, bytesPerRow: 128 * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 128, height: 4))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        func lin(_ v: UInt8) -> CGFloat { let c = CGFloat(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var lums: [CGFloat] = []
        for i in 0..<(128 * 4) {
            lums.append(0.2126 * lin(d[i * 4]) + 0.7152 * lin(d[i * 4 + 1]) + 0.0722 * lin(d[i * 4 + 2]))
        }
        lums.sort()
        lumBright = lums[Int(Double(lums.count) * 0.9)]
        lumDark = lums[Int(Double(lums.count) * 0.1)]
    }

    /// Opacity at the top of the gradient: a faint base, deepened only when the wallpaper is too
    /// bright/busy for the text to reach 4.5:1 contrast.
    var scrimTop: CGFloat {
        guard wallpaper != nil else { return 0 }
        let need = scrimAlpha(darkText: !isDark) / Scrim.textFactor
        return min(Scrim.maxTop, max(Scrim.base, need))
    }

    /// Backing opacity needed at the text for a 4.5:1 contrast ratio (0 = none), capped at 0.3.
    func scrimAlpha(darkText: Bool) -> CGFloat {
        let target: CGFloat = 4.5
        let a: CGFloat
        if darkText {
            let need: CGFloat = target * 0.05 - 0.05            // background luminance ≥ 0.175
            a = lumDark >= need ? 0 : (need - lumDark) / (1 - lumDark)
        } else {
            let need: CGFloat = 1.05 / target - 0.05            // background luminance ≤ ~0.183
            a = lumBright <= need ? 0 : 1 - need / lumBright
        }
        return min(0.3, max(0, a))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Wallpaper
        if let wallpaper {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(wallpaper, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        } else {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }

        let dark = isDark
        Scrim.draw(top: scrimTop, dark: dark, barHeight: bounds.height, offset: 0)

        // Window shadows. On the desktop they fall on the wallpaper right below the bar; without this
        // they'd stop dead at the bar's edge and leave a line. Fitted to macOS 15 (measured against white,
        // alpha of black above the top edge): a soft shadow, ~0.067 at 1.5 pt fading to 0 by ~25 pt
        // (≈ blur 28, 0.14; background windows a touch lighter), plus a tight contact line (~0.16 within 0.5 pt, ~0.03 at 1 pt).
        for s in shadows {
            for (blur, alpha) in [(28.0, s.active ? 0.14 : 0.13), (1.0, 0.5)] as [(CGFloat, CGFloat)] {
                NSGraphicsContext.saveGraphicsState()
                // Only the shadow above the window's top edge; never the shape itself.
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: max(0, s.rect.minY))).addClip()
                let sh = NSShadow()
                sh.shadowBlurRadius = blur
                sh.shadowOffset = .zero
                sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
                sh.set()
                NSColor.black.setFill()
                NSBezierPath(roundedRect: s.rect, xRadius: 10, yRadius: 10).fill()   // the fill itself is clipped away
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // 2. Menu titles — metrics measured from the native macOS 15 menu bar (37 pt notch bar):
        //    13 pt text, baseline = midline + capHeight/2 (cap height centred);
        //    Apple logo ink 15 pt tall, centred 1 pt above the midline;
        //    selection: 3 pt-radius rounded rect inset 6 pt (1 pt on 24 pt bars), white 26% / black 12%.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let baseFont = NSFont.menuBarFont(ofSize: 0)
        let tall = bounds.height >= 30
        let midY = bounds.height / 2

        for item in titles {
            let f = item.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            guard f.intersects(bounds) else { continue }

            if item.selected && !dimmed {
                let inset: CGFloat = tall ? 6 : 1
                let hl = NSRect(x: f.minX, y: inset, width: f.width, height: bounds.height - inset * 2)
                (dark ? NSColor.white.withAlphaComponent(0.26) : NSColor.black.withAlphaComponent(0.12)).setFill()
                NSBezierPath(roundedRect: hl, xRadius: 3, yRadius: 3).fill()
            }

            var alpha: CGFloat = item.enabled ? 1 : 0.35
            if dimmed { alpha *= 0.5 }
            let color = dark ? NSColor.white.withAlphaComponent(alpha) : NSColor.black.withAlphaComponent(alpha * 0.85)

            let text: String, font: NSFont
            switch item.kind {
            case .apple:   text = "\u{F8FF}"; font = NSFont.systemFont(ofSize: tall ? 19.8 : 16.5)
            case .appName: text = item.title; font = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
            case .normal:  text = item.title; font = baseFont
            }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            ]))

            let x: CGFloat, baseline: CGFloat
            if item.kind == .apple {
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                x = px(f.midX - ink.midX)
                baseline = px(midY - (tall ? 1 : 0.5) + ink.midY)
            } else {
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                x = px(f.midX - width / 2)
                baseline = px(midY + font.capHeight / 2)
            }

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: x, y: baseline)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }
}

// MARK: - Window placement

/// Private SkyLight call to set a window's sublevel. Only ever applied to Sheer's own windows.
enum SkyLight {
    private typealias MainConn = @convention(c) () -> Int32
    private typealias SetSub = @convention(c) (Int32, UInt32, Int32) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let conn: MainConn? = dlsym(handle, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConn.self) }
    private static let setSub: SetSub? = dlsym(handle, "SLSSetWindowSubLevel").map { unsafeBitCast($0, to: SetSub.self) }

    static var isAvailable: Bool { conn != nil && setSub != nil }

    @discardableResult
    static func setSubLevel(_ windowNumber: Int, _ sub: Int32) -> Bool {
        guard windowNumber > 0, let conn, let setSub else { return false }
        return setSub(conn(), UInt32(windowNumber), sub) == 0
    }

    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    private static let currentSpace: CurrentSpace? = dlsym(handle, "SLSManagedDisplayGetCurrentSpace").map { unsafeBitCast($0, to: CurrentSpace.self) }
    private static let spaceType: SpaceType? = dlsym(handle, "SLSSpaceGetType").map { unsafeBitCast($0, to: SpaceType.self) }
    private static var uuids: [CGDirectDisplayID: CFString] = [:]

    /// True when the display is showing a full-screen app's Space (type 4). Read-only query.
    static func isFullScreenSpace(_ display: CGDirectDisplayID) -> Bool {
        guard let conn, let currentSpace, let spaceType else { return false }
        if uuids[display] == nil, let u = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() {
            uuids[display] = CFUUIDCreateString(nil, u)
        }
        guard let uuid = uuids[display] else { return false }
        let c = conn()
        let sid = currentSpace(c, uuid)
        return sid != 0 && spaceType(c, sid) == 4
    }

    // Space membership of Sheer's own windows. A window that joins all Spaces stays put while the
    // Spaces slide during a switch, so it has to be hidden for full-screen apps and the system bar shows
    // through mid-animation. Placing the windows on the display's desktop Spaces only (never full-screen
    // ones) lets them slide away with the desktop like the real menu bar.
    private typealias CopyArray = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias WindowsSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private static let copySpaces: CopyArray? = dlsym(handle, "SLSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyArray.self) }
    private static let copyForWindows: CopyForWindows? = dlsym(handle, "SLSCopySpacesForWindows").map { unsafeBitCast($0, to: CopyForWindows.self) }
    private static let addToSpaces: WindowsSpaces? = dlsym(handle, "SLSAddWindowsToSpaces").map { unsafeBitCast($0, to: WindowsSpaces.self) }
    private static let removeFromSpaces: WindowsSpaces? = dlsym(handle, "SLSRemoveWindowsFromSpaces").map { unsafeBitCast($0, to: WindowsSpaces.self) }

    static var canPlaceInSpaces: Bool {
        conn != nil && copySpaces != nil && copyForWindows != nil && addToSpaces != nil && removeFromSpaces != nil
    }

    /// The desktop (non-full-screen) Spaces of a display.
    private static func desktopSpaces(of display: CGDirectDisplayID) -> [UInt64]? {
        guard let conn, let copySpaces,
              let list = copySpaces(conn())?.takeRetainedValue() as? [[String: Any]], !list.isEmpty else { return nil }
        if uuids[display] == nil, let u = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() {
            uuids[display] = CFUUIDCreateString(nil, u)
        }
        let uuid = uuids[display] as String?
        // With "Displays have separate Spaces" off there is one entry ("Main") for all displays.
        guard let entry = list.first(where: { ($0["Display Identifier"] as? String) == uuid }) ?? (list.count == 1 ? list[0] : nil),
              let spaces = entry["Spaces"] as? [[String: Any]] else { return nil }
        let ids = spaces.compactMap { s -> UInt64? in
            guard (s["type"] as? Int) == 0 else { return nil }
            return (s["id64"] as? NSNumber)?.uint64Value ?? (s["ManagedSpaceID"] as? NSNumber)?.uint64Value
        }
        return ids.isEmpty ? nil : ids
    }

    /// Whether a window (any app's; read-only query) is on the Space the display is showing.
    static func isOnCurrentSpace(_ windowID: CGWindowID, display: CGDirectDisplayID) -> Bool {
        guard let conn, let currentSpace, let copyForWindows else { return true }
        if uuids[display] == nil, let u = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() {
            uuids[display] = CFUUIDCreateString(nil, u)
        }
        guard let uuid = uuids[display] else { return true }
        let c = conn()
        let current = currentSpace(c, uuid)
        guard current != 0,
              let spaces = copyForWindows(c, 0x7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return true }
        return spaces.contains { $0.uint64Value == current }
    }

    /// Put the windows on exactly the display's desktop Spaces. Returns false if that didn't take.
    @discardableResult
    static func placeOnDesktopSpaces(_ windowNumbers: [Int], display: CGDirectDisplayID) -> Bool {
        guard canPlaceInSpaces, let conn, let copyForWindows, let addToSpaces, let removeFromSpaces,
              let wanted = desktopSpaces(of: display) else { return false }
        let c = conn()
        let want = Set(wanted)
        for wid in windowNumbers where wid > 0 {
            let w = [NSNumber(value: UInt32(wid))] as CFArray
            let have = Set(((copyForWindows(c, 0x7, w)?.takeRetainedValue() as? [NSNumber]) ?? []).map(\.uint64Value))
            if have == want { continue }
            let add = want.subtracting(have), remove = have.subtracting(want)
            if !add.isEmpty { addToSpaces(c, w, add.map { NSNumber(value: $0) } as CFArray) }
            if !remove.isEmpty { removeFromSpaces(c, w, remove.map { NSNumber(value: $0) } as CFArray) }
            let now = Set(((copyForWindows(c, 0x7, w)?.takeRetainedValue() as? [NSNumber]) ?? []).map(\.uint64Value))
            if now != want { return false }
        }
        return true
    }
}

final class OverlayWindow: NSPanel {
    let bar = BarView()
    let scrim = DesktopScrimWindow()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .mainMenu          // 24, plus sublevel 1 in show()
        ignoresMouseEvents = true  // clicks go through to the real menu bar
        hasShadow = false
        isOpaque = true
        backgroundColor = .clear
        collectionBehavior = OverlayWindow.allSpaces
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        title = "Sheer Overlay"
        bar.wantsLayer = true
        bar.layerContentsRedrawPolicy = .onSetNeedsDisplay
        contentView = bar
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Mission Control slide (in step with the system menu bar)

    private(set) var sliding = false

    func slideOut() {
        guard isVisible, !sliding else { return }
        sliding = true
        scrim.orderOut(nil)
        let f = frame
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(f.offsetBy(dx: 0, dy: f.height), display: true)
        }, completionHandler: {
            self.orderOut(nil)
            self.setFrame(f, display: false)
            self.sliding = false
        })
    }

    func slideIn() {
        guard !sliding else { return }
        sliding = true
        let f = frame
        setFrame(f.offsetBy(dx: 0, dy: f.height), display: false)
        show()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.3
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(f, display: true)
        }, completionHandler: {
            self.setFrame(f, display: false)
            self.sliding = false
            self.syncScrim()
        })
    }

    func show() {
        orderFrontRegardless()
        SkyLight.setSubLevel(windowNumber, 1)
        orderFrontRegardless()
        syncScrim()
        if let display { placeInSpaces(display: display) }
    }

    // MARK: Spaces

    static let allSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    static let ownSpaces: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

    var display: CGDirectDisplayID?
    /// On the display's desktop Spaces only, so it slides with them and full-screen Spaces never see it.
    private(set) var onDesktopSpacesOnly = false
    private var placementFailures = 0

    func placeInSpaces(display: CGDirectDisplayID) {
        guard SkyLight.canPlaceInSpaces, placementFailures < 3, isVisible else { return }
        if !onDesktopSpacesOnly { collectionBehavior = Self.ownSpaces; scrim.collectionBehavior = Self.ownSpaces }
        let wins = scrim.isVisible ? [windowNumber, scrim.windowNumber] : [windowNumber]
        if SkyLight.placeOnDesktopSpaces(wins, display: display) {
            onDesktopSpacesOnly = true
            placementFailures = 0
        } else {
            placementFailures += 1
            onDesktopSpacesOnly = false
            collectionBehavior = Self.allSpaces; scrim.collectionBehavior = Self.allSpaces
        }
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        scrim.orderOut(sender)
    }

    /// Keep the below-the-bar part of the gradient in step with the part drawn in the bar.
    func syncScrim() {
        let a0 = bar.scrimTop
        scrim.view.a0 = a0
        scrim.view.dark = bar.isDark
        scrim.view.barHeight = frame.height
        if isVisible && !sliding && a0 > 0.005 {
            if !scrim.isVisible {
                scrim.orderFrontRegardless()
                if onDesktopSpacesOnly, let display { placeInSpaces(display: display) }
            }
        } else if scrim.isVisible {
            scrim.orderOut(nil)
        }
    }

    func layout(screenFrame: NSRect, barHeight: CGFloat) {
        guard !sliding else { return }
        let f = NSRect(x: screenFrame.minX, y: screenFrame.maxY - barHeight, width: screenFrame.width, height: barHeight)
        if frame != f {
            #if SHEER_DEBUG
            Debug.append(String(format: "%.3f layout %@ -> %@\n", Date().timeIntervalSince1970, NSStringFromRect(frame), NSStringFromRect(f)), "layout.txt")
            #endif
            setFrame(f, display: true)
        }
        let h = barHeight * (Scrim.spread - 1)
        let s = NSRect(x: screenFrame.minX, y: screenFrame.maxY - barHeight - h, width: screenFrame.width, height: h)
        if scrim.frame != s { scrim.setFrame(s, display: true) }
    }
}

// MARK: - The system menu bar window

struct SystemMenuBar {
    let windowID: CGWindowID
    let bounds: CGRect   // global CG coordinates
    let onScreen: Bool
}

enum SystemMenuBars {
    static func all() -> [SystemMenuBar] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    static func refresh(_ ids: [CGWindowID]) -> [SystemMenuBar] {
        guard !ids.isEmpty else { return [] }
        var ptrs: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: Int($0)) }
        guard let arr = CFArrayCreate(nil, &ptrs, ptrs.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    private static func parse(_ w: [String: Any]) -> SystemMenuBar? {
        guard (w[kCGWindowName as String] as? String) == "Menubar",
              (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.mainMenuWindow)),
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        return SystemMenuBar(windowID: id, bounds: rect, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}
