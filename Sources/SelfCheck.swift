// Development-only self-check (compiled in only with `./build.sh --dev`).
// Run `defaults write io.github.sheer.Sheer debug -bool true`, then post the distributed
// notification "sheer.selfcheck". Sheer writes a report and two snapshots of the top of the
// screen (with and without its own windows) to $TMPDIR/Sheer-selfcheck-*.

#if SHEER_DEBUG
import AppKit
import ScreenCaptureKit

extension AppController {
    @objc func selfCheck() {
        guard Debug.enabled else { return }
        var report = "time: \(Date())\n"
        report += "accessibility: \(AXIsProcessTrusted())  screenRecording: \(CGPreflightScreenCaptureAccess())\n"
        report += "unsupported: \(unsupported)  wallpaperSource: \(wallpapers.lastSource)\n"
        report += "menus: \(reader.items.count) drawable: \(reader.isDrawable)  overlaysVisible: \(overlays.values.filter(\.isVisible).count)\n"
        for (_, w) in overlays {
            let above = (CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(w.windowNumber)) as? [[String: Any]]) ?? []
            let menubarAbove = above.contains { ($0[kCGWindowName as String] as? String) == "Menubar" }
            report += "overlay \(w.windowNumber): visible=\(w.isVisible) menubarAbove=\(menubarAbove) scrimTop=\(w.bar.scrimTop)\n"
        }
        report += "update: \(updates.available ?? "none")  icon: \(statusItem.button?.image?.size ?? .zero)\n"
        report += "menu: \(menuTitlesForTesting())\n"
        Debug.write(report, "selfcheck.txt")

        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.screens.first else { return }
        let own = Set(overlays.values.flatMap { [CGWindowID($0.windowNumber), CGWindowID($0.scrim.windowNumber)] })
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
}
#endif
