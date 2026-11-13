// App lifecycle: status menu, overlay management, event handling.

import AppKit
import ApplicationServices
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var overlays: [CGDirectDisplayID: OverlayWindow] = [:]
    var menuBarIDs: [CGWindowID] = []
    let reader = MenuBarReader()
    let wallpapers = WallpaperProvider()
    private var pollTimer: Timer?
    private var slowTimer: Timer?
    private var tick = 0
    private var observations: [NSKeyValueObservation] = []
    private var trusted = AXIsProcessTrusted()
    private var setup: SetupWindowController?
    private var storeWatcher: DispatchSourceFileSystemObject?
    private var storeChangePending = false

    /// Set when the overlay can't be placed above the system menu bar on this macOS build.
    /// Sheer then stays out of the way and the system menu bar shows as usual.
    private(set) var unsupported = false
    private var orderingFailures: [CGDirectDisplayID: Int] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        // macOS 26+ already has a transparent menu bar (and changed how it's drawn).
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            alert(L("alert.newer-macos.title"), L("alert.newer-macos.body"))
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        reader.onChange = { [weak self] in self?.applyTitles() }
        handleCommandLine()

        let ws = NSWorkspace.shared
        observations.append(ws.observe(\.menuBarOwningApplication, options: [.initial, .new]) { [weak self] ws, _ in
            DispatchQueue.main.async { self?.reader.attach(to: ws.menuBarOwningApplication) }
        })
        if let button = statusItem.button {
            // The menu bar's appearance (light/dark text) follows the wallpaper; status items report it.
            observations.append(button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.syncAppearance(); self?.reloadWallpapers() }
            })
        }

        let nc = ws.notificationCenter
        nc.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(wakeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(wallpaperChanged), name: NSNotification.Name("com.apple.desktop"), object: "BackgroundChanged")
        dnc.addObserver(self, selector: #selector(wakeUp), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        #if SHEER_DEBUG
        dnc.addObserver(self, selector: #selector(selfCheck), name: NSNotification.Name("sheer.selfcheck"), object: nil)
        #endif
        watchWallpaperStore()

        if !SkyLight.isAvailable { markUnsupported() }
        if !AXIsProcessTrusted() { showSetup() }

        rebuildOverlays()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        pollTimer?.tolerance = 0.05
        RunLoop.main.add(pollTimer!, forMode: .common)
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.slowPoll() }
        slowTimer?.tolerance = 0.2
        RunLoop.main.add(slowTimer!, forMode: .common)
    }

    /// `open Sheer.app --args --enable-login-item` registers the login item (used by install scripts).
    private func handleCommandLine() {
        guard CommandLine.arguments.contains("--enable-login-item") else { return }
        try? SMAppService.mainApp.unregister()
        let result: String
        do { try SMAppService.mainApp.register(); result = "ok" } catch { result = "error: \(error.localizedDescription)" }
        Debug.write("\(result) status=\(SMAppService.mainApp.status.rawValue) path=\(Bundle.main.bundlePath)\n", "login.txt")
    }

    private func showSetup() {
        if setup == nil {
            setup = SetupWindowController()
            setup?.onGranted = { [weak self] in
                self?.trusted = true
                self?.reader.attach(to: NSWorkspace.shared.menuBarOwningApplication)
            }
        }
        setup?.present()
    }

    private func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    private func markUnsupported() {
        guard !unsupported else { return }
        unsupported = true
        for w in overlays.values { w.orderOut(nil) }
        alert(L("alert.unsupported.title"), L("alert.unsupported.body"))
    }

    // MARK: Status menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Sheer")
            img?.isTemplate = true
            button.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?, on: Bool = false) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            menu.addItem(it)
        }
        let header = NSMenuItem(title: "Sheer", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if unsupported {
            let note = NSMenuItem(title: L("menu.unsupported"), action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())
        if !AXIsProcessTrusted() { add(L("menu.grant-accessibility"), #selector(openSetup)) }
        if wallpapers.needsCapture && !CGPreflightScreenCaptureAccess() {
            add(L("menu.grant-screen-recording"), #selector(openScreenRecording))
        }
        add(L("menu.launch-at-login"), #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add(L("menu.about"), #selector(showAbout))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSetup() { showSetup() }

    @objc private func openScreenRecording() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert(L("alert.login-item.title"), L("alert.login-item.body") + "\n\n" + error.localizedDescription)
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: L("about.credits"),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    // MARK: Events

    @objc private func screensChanged() { rebuildOverlays() }
    @objc private func wakeUp() {
        rebuildOverlays()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.reloadWallpapers() }
    }
    @objc private func spaceChanged() {
        reloadWallpapers(); reader.scheduleRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reloadWallpapers() }
    }
    @objc private func wallpaperChanged() {
        wallpapers.invalidate(); reloadWallpapers()
        for delay in [1.0, 3.0] {   // the system crossfades wallpapers; fetch again once it settles
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.wallpapers.invalidate(); self?.reloadWallpapers()
            }
        }
    }

    /// Watch the system wallpaper store so a change in System Settings is picked up immediately.
    private func watchWallpaperStore() {
        let dir = WallpaperProvider.storeIndexURL.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.storeChangePending else { return }
            self.storeChangePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.storeChangePending = false
                self.wallpaperChanged()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        storeWatcher = src
    }

    // MARK: Overlays

    private func rebuildOverlays() {
        let bars = SystemMenuBars.all()
        menuBarIDs = bars.map(\.windowID)
        let ids = Set(NSScreen.screens.map(\.displayID))
        for (id, w) in overlays where !ids.contains(id) { w.orderOut(nil); overlays[id] = nil }
        for screen in NSScreen.screens where overlays[screen.displayID] == nil {
            overlays[screen.displayID] = OverlayWindow()
        }
        syncAppearance()
        layoutOverlays(bars)
        reloadWallpapers()
        applyTitles()
        updateVisibility(bars)
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { $0.displayID == id } }

    private func menuBar(for id: CGDirectDisplayID, in bars: [SystemMenuBar]) -> SystemMenuBar? {
        let db = CGDisplayBounds(id)
        return bars.first { abs($0.bounds.minX - db.minX) < 1 && abs($0.bounds.width - db.width) < 2 }
    }

    private func barHeight(for screen: NSScreen, bars: [SystemMenuBar]) -> CGFloat {
        if let b = menuBar(for: screen.displayID, in: bars), b.bounds.height > 0 { return b.bounds.height }
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : NSStatusBar.system.thickness
    }

    private func layoutOverlays(_ bars: [SystemMenuBar]) {
        for (id, w) in overlays {
            guard let screen = screen(for: id) else { continue }
            w.layout(screenFrame: screen.frame, barHeight: barHeight(for: screen, bars: bars))
        }
    }

    private func syncAppearance() {
        let ap = statusItem.button?.effectiveAppearance
        for w in overlays.values { w.appearance = ap; w.bar.appearance = ap }
    }

    private func reloadWallpapers() {
        let bars = SystemMenuBars.refresh(menuBarIDs)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (id, w) in overlays {
            guard let screen = screen(for: id) else { continue }
            wallpapers.strip(for: screen, barHeight: barHeight(for: screen, bars: bars), dark: dark) { [weak self] img in
                if let img, let old = w.bar.wallpaper, ImageCompare.looksSame(img, old) { return }   // unchanged
                w.bar.wallpaper = img
                self?.updateVisibility()
            }
        }
        // Live-rendered wallpapers need Screen Recording: ask once (the system only prompts once).
        if wallpapers.needsCapture && !CGPreflightScreenCaptureAccess()
            && !UserDefaults.standard.bool(forKey: "askedScreenRecording") {
            UserDefaults.standard.set(true, forKey: "askedScreenRecording")
            CGRequestScreenCaptureAccess()
        }
    }

    private func applyTitles() {
        let items = reader.items
        let activeID: CGDirectDisplayID? = items.first.flatMap { first in
            NSScreen.screens.first { CGDisplayBounds($0.displayID).contains(CGPoint(x: first.frame.midX, y: first.frame.midY)) }?.displayID
        }
        let activeOrigin = activeID.map { CGDisplayBounds($0).origin } ?? .zero
        for (id, w) in overlays {
            let db = CGDisplayBounds(id)
            if id == activeID {
                w.bar.origin = db.origin
                w.bar.dimmed = false
                w.bar.titles = filterNotch(items, screen: screen(for: id), origin: db.origin)
            } else {
                // Inactive menu bars on other displays show the same menus, dimmed.
                w.bar.origin = activeOrigin
                w.bar.dimmed = true
                w.bar.titles = items.map { MenuTitle(title: $0.title, frame: $0.frame, kind: $0.kind, selected: false, enabled: $0.enabled) }
            }
        }
        updateVisibility()
    }

    /// On notched displays menus that don't fit are hidden by the system; don't draw them behind the notch.
    private func filterNotch(_ items: [MenuTitle], screen: NSScreen?, origin: CGPoint) -> [MenuTitle] {
        guard let screen, let left = screen.auxiliaryTopLeftArea else { return items }
        let limit = origin.x + (left.maxX - screen.frame.minX) + 1
        return items.filter { $0.frame.maxX <= limit }
    }

    // MARK: Polling: follow the system menu bar (full screen, auto-hide)

    private func poll() { updateVisibility(SystemMenuBars.refresh(menuBarIDs)) }

    private func slowPoll() {
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted != trusted {
            trusted = nowTrusted
            reader.attach(to: NSWorkspace.shared.menuBarOwningApplication)
        }
        reader.refresh()
        tick += 1
        let period = wallpapers.needsCapture ? 300 : 900   // live/dynamic wallpapers change over time
        if tick % period == 0 { wallpapers.invalidate(); reloadWallpapers() }

        let current = SystemMenuBars.refresh(menuBarIDs)
        if current.count != menuBarIDs.count || current.isEmpty { rebuildOverlays(); return }
        layoutOverlays(current)
        ensureOrdering(current)
    }

    /// If the system menu bar ends up above the overlay, re-apply the sublevel. If that keeps failing
    /// (e.g. a macOS update changed the private API), give up and leave the system menu bar alone.
    private func ensureOrdering(_ bars: [SystemMenuBar]) {
        for (id, w) in overlays where w.isVisible {
            guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(w.windowNumber)) as? [[String: Any]]
            else { continue }
            let covered = above.contains { d in bars.contains { $0.windowID == d[kCGWindowNumber as String] as? CGWindowID } }
            if covered {
                orderingFailures[id, default: 0] += 1
                if orderingFailures[id, default: 0] >= 3 { markUnsupported(); return }
                w.show()
            } else {
                orderingFailures[id] = 0
            }
        }
    }

    private func updateVisibility(_ bars: [SystemMenuBar]? = nil) {
        let bars = bars ?? SystemMenuBars.refresh(menuBarIDs)
        let drawable = reader.isDrawable
        for (id, w) in overlays {
            let db = CGDisplayBounds(id)
            let barAtTop = menuBar(for: id, in: bars).map { $0.onScreen && abs($0.bounds.minY - db.minY) < 0.5 } ?? false
            let show = !unsupported && AXIsProcessTrusted() && drawable && barAtTop && w.bar.wallpaper != nil
            if show && !w.isVisible { w.show() }
            else if !show && w.isVisible { w.orderOut(nil) }
            w.syncScrim()
        }
    }
}
