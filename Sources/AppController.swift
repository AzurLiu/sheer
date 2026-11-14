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
    private var lastFullScreen: [CGDirectDisplayID: Bool] = [:]
    /// Until then a Space switch may still be animating (the system menu bars are in motion).
    private var switchingUntil = Date.distantPast
    private var warnedUnsupported = false
    let updates = UpdateChecker()

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
            DispatchQueue.main.async {
                self?.reader.attach(to: ws.menuBarOwningApplication)
                // The key window (bigger shadow) changes; new windows often open now too.
                for d in [0.05, 0.4] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { self?.scanWindows() } }
            }
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
        dnc.addObserver(self, selector: #selector(testUnsupported), name: NSNotification.Name("sheer.test-unsupported"), object: nil)
        dnc.addObserver(self, selector: #selector(spaceChanged), name: NSNotification.Name("sheer.test-space"), object: nil)
        dnc.addObserver(self, selector: #selector(testSwitch(_:)), name: NSNotification.Name("sheer.test-switch"), object: nil)
        dnc.addObserver(self, selector: #selector(testLevel(_:)), name: NSNotification.Name("sheer.test-level"), object: nil)
        dnc.addObserver(self, selector: #selector(testMirror), name: NSNotification.Name("sheer.test-mirror"), object: nil)
        #endif
        watchWallpaperStore()
        observeDock()

        if !SkyLight.isAvailable { markUnsupported() }
        updates.onChange = { [weak self] in self?.updateStatusIcon() }
        updates.start()
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
        if !warnedUnsupported {   // once per launch; Sheer keeps retrying quietly (see retrySupport)
            warnedUnsupported = true
            alert(L("alert.unsupported.title"), L("alert.unsupported.body"))
        }
    }

    #if SHEER_DEBUG
    @objc private func testUnsupported() { warnedUnsupported = true; markUnsupported() }
    /// Animated Space switch (Control-Left/Right), so Space transitions can be tested unattended.
    @objc private func testSwitch(_ n: Notification) {
        let key: CGKeyCode = (n.object as? String) == "left" ? 123 : 124
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e?.post(tap: .cghidEventTap)
        }
    }
    @objc private func testMirror() { mirrorWhileSettling() }
    /// "level:sublevel" for the overlay windows, to try out orderings.
    @objc private func testLevel(_ n: Notification) {
        let parts = ((n.object as? String) ?? "").split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        for w in overlays.values {
            w.level = NSWindow.Level(rawValue: parts[0])
            SkyLight.setSubLevel(w.windowNumber, Int32(parts[1]))
            w.orderFrontRegardless()
        }
        Debug.write("level \(parts)\n", "level.txt")
    }
    /// Menu titles as they'd appear right now (for the self-check).
    func menuTitlesForTesting() -> [String] {
        let m = NSMenu(); menuNeedsUpdate(m); return m.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }
    #endif

    /// Give the overlay another chance after something that reshuffles windows (Space switch, wake,
    /// display change) and every 10 minutes, so a one-off glitch doesn't switch Sheer off for good.
    private func retrySupport() {
        guard unsupported, SkyLight.isAvailable else { return }
        unsupported = false
        orderingFailures = [:]
        updateVisibility()
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
        if let v = updates.available {
            add(String(format: L("menu.update-available"), v), #selector(openReleases))
        }
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

    @objc private func openReleases() { NSWorkspace.shared.open(UpdateChecker.releasesPage) }

    /// A small dot on the status icon while an update is available.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        guard let base = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "Sheer") else { return }
        var img = base
        if updates.available != nil {
            let size = NSSize(width: base.size.width + 3, height: base.size.height)
            img = NSImage(size: size, flipped: false) { _ in
                base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
                NSBezierPath(ovalIn: NSRect(x: size.width - 6, y: size.height - 6, width: 6, height: 6)).fill()
                return true
            }
        }
        img.isTemplate = true
        button.image = img
    }

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

    @objc private func screensChanged() { retrySupport(); rebuildOverlays() }
    @objc private func wakeUp() {
        track(for: 2)   // the menu bar slides in as the screen unlocks: follow it frame by frame
        quietUntil = Date() + 1.5
        #if SHEER_DEBUG
        Debug.append(String(format: "%.3f wakeUp\n", Date().timeIntervalSince1970), "vis.txt")
        #endif
        retrySupport()
        rebuildOverlays()   // its wallpaper reload waits for quietUntil
        mirrorWhileSettling()
    }

    /// A live-rendered wallpaper plays a few seconds of motion as the screen unlocks. Stream it into the
    /// bar meanwhile, frame by frame, so the bar moves with the desktop instead of catching up later.
    private var mirrors: [LiveMirror] = []
    private func mirrorWhileSettling() {
        guard wallpapers.needsCapture, CGPreflightScreenCaptureAccess() else { return }
        let seconds = 5.0
        quietUntil = max(quietUntil, Date() + seconds + 0.3)
        mirrors.forEach { $0.stop() }
        let bars = SystemMenuBars.refresh(menuBarIDs)
        mirrors = overlays.compactMap { id, w in
            guard let screen = screen(for: id) else { return nil }
            return LiveMirror.start(for: screen, barHeight: barHeight(for: screen, bars: bars), seconds: seconds) { [weak w] img in
                guard let w else { return }
                w.bar.live = true
                w.bar.wallpaper = img
                w.bar.live = false
                w.syncScrim()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.mirrors = [] }
    }
    @objc private func spaceChanged() {
        switchingUntil = Date() + 1.5
        placeInSpaces()   // picks up newly created desktop Spaces
        retrySupport()
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
            let w = OverlayWindow()
            w.display = screen.displayID
            overlays[screen.displayID] = w
        }
        syncAppearance()
        layoutOverlays(bars)
        reloadWallpapers()
        applyTitles()
        updateVisibility(bars)
    }

    private func placeInSpaces() {
        for (id, w) in overlays where w.isVisible { w.placeInSpaces(display: id) }
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { $0.displayID == id } }

    private func menuBar(for id: CGDirectDisplayID, in bars: [SystemMenuBar]) -> SystemMenuBar? {
        let db = CGDisplayBounds(id)
        // A full-screen app in another Space keeps its own (off-screen) "Menubar" window with the
        // same frame, so prefer the one that is actually on screen.
        let matches = bars.filter { abs($0.bounds.minX - db.minX) < 1 && abs($0.bounds.width - db.width) < 2 }
        return matches.first(where: \.onScreen) ?? matches.first
    }

    private func barHeight(for screen: NSScreen, bars: [SystemMenuBar]) -> CGFloat {
        if let b = menuBar(for: screen.displayID, in: bars), b.bounds.height > 0 { return b.bounds.height }
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 0 ? h : NSStatusBar.system.thickness
    }

    private func layoutOverlays(_ bars: [SystemMenuBar]) {
        for (id, w) in overlays {
            guard let screen = screen(for: id) else { continue }
            // A full-screen Space has its own menu bar window (38 pt, not 37); mid-switch none sits at
            // the top. Keep the desktop's layout then rather than resizing back and forth.
            if w.frame.height > 0, SkyLight.isFullScreenSpace(id) || Date() < switchingUntil
                || menuBar(for: id, in: bars).map({ !$0.onScreen || $0.bounds.minY != CGDisplayBounds(id).minY }) ?? true { continue }
            w.layout(screenFrame: screen.frame, barHeight: barHeight(for: screen, bars: bars))
        }
    }

    private func syncAppearance() {
        let ap = statusItem.button?.effectiveAppearance
        for w in overlays.values { w.appearance = ap; w.bar.appearance = ap; w.syncScrim() }
    }

    /// While locked, and until the desktop has settled after unlocking, the screen shows the lock
    /// screen or its fade: a live wallpaper captured then comes out different each time, and every
    /// change crossfades the bar. Hold reloads until then and do a single one.
    private var quietUntil = Date.distantPast
    private var deferredReload = false
    private var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func reloadWallpapers() {
        let wait = quietUntil.timeIntervalSinceNow
        if wait > 0 || screenLocked {
            if !deferredReload {
                deferredReload = true
                DispatchQueue.main.asyncAfter(deadline: .now() + max(wait, 1)) { [weak self] in
                    self?.deferredReload = false
                    self?.reloadWallpapers()
                }
            }
            return
        }
        let bars = SystemMenuBars.refresh(menuBarIDs)
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (id, w) in overlays {
            guard let screen = screen(for: id) else { continue }
            wallpapers.strip(for: screen, barHeight: barHeight(for: screen, bars: bars), dark: dark) { [weak self] img in
                if let img, let old = w.bar.wallpaper, ImageCompare.looksSame(img, old) { return }   // unchanged
                #if SHEER_DEBUG
                Debug.append(String(format: "%.3f wallpaper applied (changed)\n", Date().timeIntervalSince1970), "vis.txt")
                #endif
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
            // A full-screen app's menus aren't shown on the desktop Spaces the overlay lives in; keep the
            // desktop's titles so they're right while the desktop slides back in.
            if w.onDesktopSpacesOnly && SkyLight.isFullScreenSpace(id) { continue }
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

    private func poll() {
        scanWindows()
        updateVisibility(SystemMenuBars.refresh(menuBarIDs))
        // Follow windows closely only while the mouse is held (dragging, resizing); otherwise 4 Hz is
        // plenty and keeps the idle cost down.
        if NSEvent.pressedMouseButtons & 1 != 0 && fastTimer == nil {
            fastTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.scanWindows()
                if NSEvent.pressedMouseButtons & 1 == 0 { self.fastTimer?.invalidate(); self.fastTimer = nil }
            }
            RunLoop.main.add(fastTimer!, forMode: .common)
        }
    }

    /// Follow the system menu bar at display rate for a while (it is sliding in or out).
    private var trackTimer: Timer?
    private var trackUntil = Date.distantPast
    private func track(for seconds: TimeInterval) {
        trackUntil = max(trackUntil, Date() + seconds)
        guard trackTimer == nil else { return }
        trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateVisibility()
            if Date() > self.trackUntil { self.trackTimer?.invalidate(); self.trackTimer = nil }
        }
        RunLoop.main.add(trackTimer!, forMode: .common)
    }

    // MARK: Mission Control
    //
    // Mission Control replaces the menu bar with its Spaces strip, sliding it back down on exit.
    // The overlay turns to frosted glass and fades into the strip, then slides back with the bar. Entry: the Dock's
    // AXExposeShowAllWindows notification (or, as a fallback, its full-screen layer-18 window in the
    // window scan). Exit: the Dock's "Mission Control" AX group disappears as the exit animation starts
    // (its window lingers until the end), so it's watched at 20 Hz while Mission Control is up.

    private(set) var missionControl = false
    private var mcTimer: Timer?
    private var dockObserver: AXObserver?
    private var observedDock: pid_t?
    private var dockPIDCache: pid_t?
    private var slideInNext = false
    private var dockPID: pid_t? { dockPIDCache }

    /// (Re)attach to the Dock; called at launch and every 30 s in case the Dock restarted.
    private func observeDock() {
        dockPIDCache = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        guard let pid = dockPID, pid != observedDock else { return }
        if let old = dockObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode) }
        dockObserver = nil; observedDock = pid
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, ctx in
            guard let ctx else { return }
            let me = Unmanaged<AppController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.enterMissionControl() }
        }, &obs) == .success, let obs else { return }
        let dock = AXUIElementCreateApplication(pid)
        for n in ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"] {
            AXObserverAddNotification(obs, dock, n as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        dockObserver = obs
    }

    /// The Dock's AX tree has a group (besides the Dock list) only while Mission Control is shown.
    private func dockShowsMissionControl() -> Bool {
        guard let pid = dockPID else { return false }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return false }
        return kids.contains { k in
            var r: CFTypeRef?
            AXUIElementCopyAttributeValue(k, kAXRoleAttribute as CFString, &r)
            return (r as? String) == kAXGroupRole
        }
    }

    private func enterMissionControl() {
        #if SHEER_DEBUG
        Debug.append(String(format: "%.3f enterMC shows=%d\n", Date().timeIntervalSince1970, dockShowsMissionControl() ? 1 : 0), "vis.txt")
        #endif
        guard !missionControl, dockShowsMissionControl() else { return }
        missionControl = true
        updateVisibility()
        mcTimer?.invalidate()
        mcTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, !self.dockShowsMissionControl() else { return }
            self.exitMissionControl()
        }
        RunLoop.main.add(mcTimer!, forMode: .common)
    }

    private func exitMissionControl() {
        mcTimer?.invalidate(); mcTimer = nil
        guard missionControl else { return }
        missionControl = false
        slideInNext = true
        updateVisibility()
        slideInNext = false
    }

    // MARK: Window scan

    private var fastTimer: Timer?

    /// One pass over the on-screen windows: Mission Control (the Dock shows a full-screen layer-18
    /// window only then) and windows whose top edge sits just below a menu bar, for their shadows.
    func scanWindows() {
        let shown = overlays.filter { $0.value.isVisible && $0.value.isOnActiveSpace }
        guard !overlays.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as NSArray?
        else { clearShadows(); return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var sawFront = false, mc = false
        let dock = dockPID
        var windows: [(CGRect, Bool, CGWindowID)] = []
        for case let info as NSDictionary in list {   // front to back; NSDictionary avoids bridging every key
            let layer = info[kCGWindowLayer] as? Int
            if layer == 18, let dock, (info[kCGWindowOwnerPID] as? Int).map({ pid_t($0) }) == dock { mc = true }
            guard layer == 0,
                  ((info[kCGWindowAlpha] as? Double) ?? 1) > 0.05,
                  let b = info[kCGWindowBounds] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 40, r.height > 40 else { continue }
            let pid = (info[kCGWindowOwnerPID] as? Int).map { pid_t($0) }
            windows.append((r, pid == front && !sawFront, (info[kCGWindowNumber] as? Int).map { CGWindowID($0) } ?? 0))
            if pid == front { sawFront = true }
        }
        if mc && !missionControl { enterMissionControl() }   // fallback if the notification was missed
        // Mid-switch, windows of the Space sliding in (e.g. a full-screen app) count as on screen with
        // their resting frames; keep the current shadows until the switch is over.
        if Date() < switchingUntil { return }
        for (id, w) in overlays {
            guard shown[id] != nil else { w.bar.shadows = []; continue }
            let db = CGDisplayBounds(id)
            let barBottom = db.minY + w.frame.height
            w.bar.shadows = windows.compactMap { r, active, wid in
                guard r.minY >= barBottom - 0.5, r.minY < barBottom + 30, r.maxX > db.minX, r.minX < db.maxX,
                      SkyLight.isOnCurrentSpace(wid, display: id) else { return nil }
                return WindowShadow(rect: r.offsetBy(dx: -db.minX, dy: -db.minY), active: active)
            }
        }
    }

    private func clearShadows() {
        for w in overlays.values { w.bar.shadows = [] }
    }

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
        else if wallpapers.followsSun && tick % 60 == 0 { reloadWallpapers() }   // redraws only if the frame changed
        if tick % 600 == 0 { retrySupport() }
        if tick % 30 == 0 { observeDock() }
        if tick % 5 == 0 { placeInSpaces() }

        let current = SystemMenuBars.refresh(menuBarIDs)
        if current.count != menuBarIDs.count || current.isEmpty { rebuildOverlays(); return }
        layoutOverlays(current)
        ensureOrdering(current)
    }

    /// If the system menu bar ends up above the overlay, re-apply the sublevel. If that keeps failing
    /// (e.g. a macOS update changed the private API), give up and leave the system menu bar alone.
    private func ensureOrdering(_ bars: [SystemMenuBar]) {
        for (id, w) in overlays where w.isVisible && w.isOnActiveSpace {
            guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(w.windowNumber)) as? [[String: Any]]
            else { continue }
            // Only this display's on-screen menu bar counts; Space switches can briefly reorder windows.
            guard let bar = menuBar(for: id, in: bars), bar.onScreen, !SkyLight.isFullScreenSpace(id) else {
                orderingFailures[id] = 0; continue
            }
            let covered = above.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == bar.windowID }
            if covered {
                orderingFailures[id, default: 0] += 1
                if orderingFailures[id, default: 0] >= 10 { markUnsupported(); return }
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
            let fullScreen = SkyLight.isFullScreenSpace(id)
            // Placed on desktop Spaces only, the overlay isn't in full-screen ones anyway; keeping it
            // ordered in lets it slide in and out with the desktop instead of popping.
            // Mid-switch the system menu bars slide sideways, so none sits on this display: keep the
            // overlay as it is rather than popping it out and back in.
            if missionControl {
                if w.isVisible { w.dissolveIntoMissionControl() }
                continue
            }
            let bar = menuBar(for: id, in: bars)
            if fullScreen != lastFullScreen[id] { lastFullScreen[id] = fullScreen; switchingUntil = Date() + 1.5 }
            let switching = bar == nil || (bar?.onScreen != true && Date() < switchingUntil)
            if w.onDesktopSpacesOnly && w.isVisible && (fullScreen || switching) { w.syncScrim(); continue }
            let db = CGDisplayBounds(id)
            // How far the system bar sits above the top of the screen: 0 at rest; part of its height while
            // it slides in or out (unlocking, an auto-hiding bar), when the overlay rides along.
            let raised = bar.flatMap { b in !fullScreen && b.onScreen ? db.minY - b.bounds.minY : nil }
            let barAtTop = raised.map { abs($0) < 0.5 } ?? false
            let sliding = raised.map { $0 >= 0.5 && $0 < (bar?.bounds.height ?? 0) - 0.5 } ?? false
            if sliding { track(for: 0.3) }   // keep up with the rest of the slide
            let show = !unsupported && AXIsProcessTrusted() && drawable && (barAtTop || sliding) && w.bar.wallpaper != nil
            w.raise = sliding ? (raised ?? 0) : 0
            #if SHEER_DEBUG
            if show != w.isVisible {
                let mb = bar
                Debug.append("\(Date().timeIntervalSince1970) show=\(show) visible=\(w.isVisible) active=\(w.isOnActiveSpace) fs=\(fullScreen) drawable=\(drawable) bar=\(mb.map { "\($0.windowID) on=\($0.onScreen) y=\($0.bounds.minY)" } ?? "nil") all=\(bars.map { "\($0.windowID):\($0.onScreen):\($0.bounds.minY)" })\n", "vis.txt")
            }
            #endif
            if show && !w.isVisible { slideInNext ? w.slideIn() : w.show() }
            else if !show && w.isVisible { w.orderOut(nil) }
            w.syncScrim()
        }
    }
}
