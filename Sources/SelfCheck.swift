// Development-only self-check (compiled in only with `./build.sh --dev`).
// Run `defaults write io.github.sheer.Sheer debug -bool true`, then post the distributed
// notification "sheer.selfcheck". Sheer writes a report and two snapshots of the top of the
// screen (with and without its own windows) to $TMPDIR/Sheer-selfcheck-*.

#if SHEER_DEBUG
import AppKit
import ScreenCaptureKit

extension AppController {
    /// "sheer.test-click" with object "x,y" (global points, top-left origin): move the pointer there and
    /// click; "move:x,y" only moves it. For driving Stage Manager's strip while testing.
    @objc func testClick(_ n: Notification) {
        guard Debug.enabled, var s = n.object as? String else { return }
        let moveOnly = s.hasPrefix("move:")
        if moveOnly { s.removeFirst(5) }
        let v = s.split(separator: ",").compactMap { Double($0) }
        guard v.count == 2 else { return }
        let p = CGPoint(x: v[0], y: v[1])
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        guard !moveOnly else { return }
        StageShiftFollower.shared.follow(for: 1.5)   // as a real click would (the click monitor doesn't see Sheer's own events)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// "sheer.test-update": check for an update now (see the "updateAPI" default) and announce it again.
    @objc func testUpdate() {
        guard Debug.enabled else { return }
        UserDefaults.standard.removeObject(forKey: "announcedVersion")
        updates.checkNow()
    }

    /// "sheer.test-follow" with "0" or "1": turn undoing Stage Manager's shift off or on.
    @objc func testFollow(_ n: Notification) {
        guard Debug.enabled else { return }
        StageShiftFollower.shared.enabled = (n.object as? String) != "0"
    }

    @objc func selfCheck() {
        guard Debug.enabled else { return }
        var report = "time: \(Date())\n"
        report += "accessibility: \(AXIsProcessTrusted())  screenRecording: \(CGPreflightScreenCaptureAccess())\n"
        report += "unsupported: \(unsupported)  wallpaperSource: \(wallpapers.lastSource)\n"
        report += "menus: \(reader.items.count) drawable: \(reader.isDrawable)  overlaysVisible: \(overlays.values.filter(\.isVisible).count)\n"
        for (_, w) in overlays {
            let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(w.windowNumber)) as? [[String: Any]]) ?? []
            let menubarAbove = above.contains { ($0[kCGWindowName as String] as? String) == "Menubar" }
            report += "overlay \(w.windowNumber): visible=\(w.isVisible) desktopSpacesOnly=\(w.onDesktopSpacesOnly) onActiveSpace=\(w.isOnActiveSpace) menubarAbove=\(menubarAbove) scrimTop=\(w.bar.scrimTop)\n"
        }
        report += "update: \(updates.available ?? "none")  icon: \(statusItem.button?.image?.size ?? .zero)\n"
        report += "menu: \(menuTitlesForTesting())\n"
        Debug.write(report, "selfcheck.txt")

        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first else { return }
        let own = Set(overlays.values.flatMap { [CGWindowID($0.windowNumber), CGWindowID($0.scrim.windowNumber)] })
        guard #available(macOS 14, *) else {
            for (name, excluded) in [("on", Set<CGWindowID>()), ("off", own)] {
                Debug.write(Self.legacySnapshot(screen.displayID, excluding: excluded), "selfcheck-\(name).png")
            }
            return
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
                let ownWindows = content.windows.filter { own.contains($0.windowID) }
                for (name, excluded) in [("on", [SCWindow]()), ("off", ownWindows)] {
                    let cfg = SCStreamConfiguration()
                    cfg.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: 120)
                    cfg.width = display.width * 2
                    cfg.height = 240
                    cfg.showsCursor = false
                    let img = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(display: display, excludingWindows: excluded), configuration: cfg)
                    Debug.write(img, "selfcheck-\(name).png")
                }
            } catch {
                Debug.write(report + "capture error: \(error)\n", "selfcheck.txt")
            }
        }
    }

    /// macOS 12 and 13: the same snapshot through CGWindowList.
    @available(macOS, deprecated: 14, message: "SCScreenshotManager from macOS 14 on")
    private static func legacySnapshot(_ display: CGDirectDisplayID, excluding excluded: Set<CGWindowID>) -> CGImage? {
        let db = CGDisplayBounds(display)
        let rect = CGRect(x: db.minX, y: db.minY, width: db.width, height: 120)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var ids: [UnsafeRawPointer?] = list.compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } }
            .filter { !excluded.contains($0) }
            .map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &ids, ids.count, nil) else { return nil }
        return CGImage(windowListFromArrayScreenBounds: rect, windowArray: array, imageOption: [.bestResolution])
    }
}
#endif
