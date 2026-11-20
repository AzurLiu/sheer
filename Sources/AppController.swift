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
                DispatchQueue.main.async { self?.syncAppearance(); self?.reloadWallpapers(); DesktopLog.shared.readSoon() }
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
        dnc.addObserver(self, selector: #selector(openSetup), name: NSNotification.Name("sheer.test-setup"), object: nil)
        dnc.addObserver(self, selector: #selector(testClick(_:)), name: NSNotification.Name("sheer.test-click"), object: nil)
        dnc.addObserver(self, selector: #selector(testFollow(_:)), name: NSNotification.Name("sheer.test-follow"), object: nil)
        dnc.addObserver(self, selector: #selector(testUpdate), name: NSNotification.Name("sheer.test-update"), object: nil)
        dnc.addObserver(self, selector: #selector(checkForUpdates), name: NSNotification.Name("sheer.test-check"), object: nil)
        #endif
        watchWallpaperStore()
        observeDock()

        if !SkyLight.isAvailable { markUnsupported() }
        updates.onChange = { [weak self] in self?.updateStatusIcon(); self?.announceUpdate() }
        updates.start()
        if !AXIsProcessTrusted() { showSetup() }
        Location.shared.onChange = { [weak self] in self?.reloadWallpapers(); DesktopLog.shared.readSoon() }
        // A sun-following wallpaper: the desktop's own notes say which image it shows, and when it
        // chooses again. It also chooses anew when the clock or the time zone changes.
        DesktopLog.shared.onChange = { [weak self] in self?.reloadWallpapers() }
        wallpapers.onLookAgain = { [weak self] in self?.reloadWallpapers() }
        for name in [NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DesktopLog.shared.readSoon(); self?.reloadWallpapers()
            }
        }
        Location.shared.start()

        rebuildOverlays()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        pollTimer?.tolerance = 0.05
        RunLoop.main.add(pollTimer!, forMode: .common)
        slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.slowPoll() }
        slowTimer?.tolerance = 0.2
        RunLoop.main.add(slowTimer!, forMode: .common)
        watchClicks()
    }

    /// `open Sheer.app --args --enable-login-item` registers the login item (used by install scripts).
    private func handleCommandLine() {
        guard CommandLine.arguments.contains("--enable-login-item") else { return }
        guard #available(macOS 13, *) else { Debug.write("unsupported before macOS 13\n", "login.txt"); return }
        try? SMAppService.mainApp.unregister()
        let result: String
        do { try SMAppService.mainApp.register(); result = "ok" } catch { result = "error: \(error.localizedDescription)" }
        Debug.write("\(result) status=\(SMAppService.mainApp.status.rawValue) path=\(Bundle.main.bundlePath)\n", "login.txt")
    }

    private func showSetup() {
        if setup == nil {
            setup = SetupWindowController()
            setup?.needsScreenRecording = { [weak self] in self?.wallpapers.needsCapture ?? false }
            setup?.usesLocation = { [weak self] in self?.sunNeedsLocation ?? false }
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
        #if SHEER_DEBUG
        // With `testUpdateButton` set (see announceUpdate), plain alerts close themselves after 2 s too.
        if UserDefaults.standard.object(forKey: "testUpdateButton") != nil {
            let t = Timer(timeInterval: 2, repeats: false) { _ in a.buttons.first?.performClick(nil) }
            RunLoop.main.add(t, forMode: .common)
        }
        #endif
        a.runModal()
    }

    /// A newer version: say so once per version, with what it changes. The menu item and the dot on
    /// the status icon stay for those who choose Later.
    /// `force`: show it even if this version was announced before (the user asked).
    private func announceUpdate(force: Bool = false) {
        guard let version = updates.available,
              force || UserDefaults.standard.string(forKey: "announcedVersion") != version else { return }
        UserDefaults.standard.set(version, forKey: "announcedVersion")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = String(format: L("alert.update.title"), version)
        let inPlace = updates.canInstall
        a.informativeText = [updates.notes, L(inPlace ? "alert.update.body.auto" : "alert.update.body")].compactMap { $0 }.joined(separator: "\n\n")
        a.addButton(withTitle: L(inPlace ? "alert.update.install" : "alert.update.download"))
        a.addButton(withTitle: L("alert.update.later"))
        #if SHEER_DEBUG
        // `defaults write io.github.sheer.Sheer testUpdateButton -int 0|1` clicks that button after 2 s.
        if let i = UserDefaults.standard.object(forKey: "testUpdateButton") as? Int, a.buttons.indices.contains(i) {
            let t = Timer(timeInterval: 2, repeats: false) { _ in a.buttons[i].performClick(nil) }
            RunLoop.main.add(t, forMode: .common)
        }
        #endif
        let download = a.runModal() == .alertFirstButtonReturn
        Debug.write("\(Date()) update alert for \(version): \(download ? "download" : "later")\n", "update-alert.txt")
        if download { installUpdate() }
    }

    /// "Check for Updates…": ask GitHub now and always say what came of it.
    @objc private func checkForUpdates() {
        let announcedBefore = UserDefaults.standard.string(forKey: "announcedVersion")
        updates.checkNow { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.alert(L("alert.check-failed.title"), L("alert.check-failed.body"))
                return
            }
            if updates.available != nil {
                // A version not announced before was just announced by the regular path (onChange);
                // one announced earlier is shown again, since the user asked.
                if UserDefaults.standard.string(forKey: "announcedVersion") == announcedBefore { announceUpdate(force: true) }
            } else {
                alert(L("alert.up-to-date.title"), String(format: L("alert.up-to-date.body"), updates.currentVersion))
            }
        }
    }

    /// Update in place when Sheer can (see Updater.swift), otherwise open the download page.
    @objc private func installUpdate() {
        guard updates.canInstall else { openReleases(); return }
        updates.install { [weak self] result in
            switch result {
            case .success(let app): self?.relaunch(app)
            case .failure(let why): self?.updateFailed(why)
            }
        }
    }

    /// Open the new version once this one has quit.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"", app.path]
        try? sh.run()
        NSApp.terminate(nil)
    }

    private func updateFailed(_ why: UpdateChecker.InstallError) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("alert.update-failed.title")
        let reason: String
        switch why {
        case .download: reason = L("update.fail.download")
        case .check: reason = L("update.fail.check")
        case .replace: reason = L("update.fail.replace")
        }
        a.informativeText = String(format: L("alert.update-failed.body"), reason)
        a.addButton(withTitle: L("alert.update.download"))
        a.addButton(withTitle: L("alert.update.later"))
        if a.runModal() == .alertFirstButtonReturn { openReleases() }
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
            if updates.installing {
                let item = NSMenuItem(title: String(format: L("menu.updating"), v), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                add(String(format: L("menu.update-available"), v), #selector(installUpdate))
            }
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
        // macOS 12 has no SMAppService: Sheer is added under Users & Groups → Login Items there.
        if #available(macOS 13, *) {
            add(L("menu.launch-at-login"), #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        }
        // While an update is waiting, its own item ("Update Available…") takes this place.
        if updates.available == nil { add(L("menu.check-updates"), #selector(checkForUpdates)) }
        add(L("menu.about"), #selector(showAbout))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSetup() { showSetup() }

    @objc private func openReleases() {
        let opened = NSWorkspace.shared.open(UpdateChecker.releasesPage)
        Debug.write("\(Date()) opened \(UpdateChecker.releasesPage): \(opened)\n", "update-open.txt")
    }

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

    @available(macOS 13, *)
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
        DesktopLog.shared.readSoon()
        rebuildOverlays()   // its wallpaper reload waits for quietUntil
        mirrorWhileSettling()
    }

    /// A live-rendered wallpaper plays a few seconds of motion as the screen unlocks. Stream it into the
    /// bar meanwhile, frame by frame, so the bar moves with the desktop instead of catching up later.
    private var mirrors: [AnyObject] = []   // LiveMirror (macOS 12.3+)
    private func mirrorWhileSettling() {
        guard #available(macOS 12.3, *) else { return }   // no streams before: the bar catches up afterwards
        guard wallpapers.needsCapture, CGPreflightScreenCaptureAccess() else { return }
        let seconds = 5.0
        quietUntil = max(quietUntil, Date() + seconds + 0.3)
        mirrors.forEach { ($0 as? LiveMirror)?.stop() }
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
        updateShiftFollowing()
        placeInSpaces()   // picks up newly created desktop Spaces
        retrySupport()
        reloadWallpapers(); reader.scheduleRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reloadWallpapers() }
    }
    @objc private func wallpaperChanged() {
        DesktopLog.shared.readSoon()
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
        for (id, w) in overlays where !ids.contains(id) { w.orderOut(nil); StageShiftFollower.shared.remove(w); overlays[id] = nil }
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
        // Live-rendered wallpapers need Screen Recording. Without it Sheer steps aside for the system
        // menu bar, which looks broken unless it says why: show the permissions window, once each time
        // such a wallpaper comes up (at launch, or when the wallpaper changes to one).
        if wallpapers.needsCapture && !CGPreflightScreenCaptureAccess() {
            if !askedForRecording { askedForRecording = true; showSetup() }
        } else {
            askedForRecording = false
        }
        // Same for a Dynamic wallpaper the desktop times by the Mac's real position: offer once to
        // let Sheer use it too (after a refusal the system won't ask again, and neither does Sheer).
        if sunNeedsLocation && Location.shared.isUndetermined {
            if !askedForLocation { askedForLocation = true; showSetup() }
        } else {
            askedForLocation = false
        }
    }
    private var askedForRecording = false
    private var askedForLocation = false
    /// A sun-following wallpaper, on a Mac whose desktop places the sun by Location Services, and
    /// without the desktop's own notes to go by (with them Sheer needn't know where the Mac is).
    private var sunNeedsLocation: Bool {
        wallpapers.followsSun && !wallpapers.notedByDesktop && DesktopLog.shared.settled && Solar.desktopUsesRealLocation
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
        guard #available(macOS 12, *) else { return items }   // notched displays came with macOS 12
        guard let screen, let left = screen.auxiliaryTopLeftArea else { return items }
        let limit = origin.x + (left.maxX - screen.frame.minX) + 1
        return items.filter { $0.frame.maxX <= limit }
    }

    // MARK: Polling: follow the system menu bar (full screen, auto-hide)

    private func poll() {
        scanWindows()
        updateVisibility(SystemMenuBars.refresh(menuBarIDs))
        updateShiftFollowing()
        StageShiftFollower.shared.check()
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

    /// Stage Manager's shifts (see StageShift.swift) start on a click in its strip; follow them at every
    /// display refresh from there. Space switches and Mission Control move the bars on purpose.
    private var clickMonitor: Any?
    private func updateShiftFollowing() {
        StageShiftFollower.shared.setPaused(missionControl || Date() < switchingUntil)
    }

    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { _ in
            StageShiftFollower.shared.follow(for: 1.5)
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
    // Mission Control slides the menu bar up out of the way for its Spaces strip, and back down on exit.
    // The overlay does the same, in step, so the system bar never shows. Entry: the Dock's
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
        guard !missionControl, dockShowsMissionControl() else { return }
        missionControl = true
        updateShiftFollowing()
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
        updateShiftFollowing()
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
        // A look at the desktop each minute; it redraws only if the image changed. (The desktop's own
        // notes bring changes in at once: see DesktopLog.)
        else if wallpapers.followsSun && tick % 60 == 0 { reloadWallpapers() }
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
                if w.isVisible { w.slideOut() }
                continue
            }
            let bar = menuBar(for: id, in: bars)
            if fullScreen != lastFullScreen[id] { lastFullScreen[id] = fullScreen; switchingUntil = Date() + 1.5; updateShiftFollowing() }
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
