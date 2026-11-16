// Stage Manager: keeping the bar in place while the stage slides aside.
//
// When a thumbnail in Stage Manager's strip fans out its app's windows, Stage Manager slides the stage
// aside — and Sheer's bar with it, though it isn't part of any stage. It does so in the window server,
// stacked on the window's own position (AppKit's `frame` doesn't change), one step per 60 Hz frame. No
// level, Space, tag, collection behavior or parent window keeps the bar out of it, and moving the window
// back only takes once the animation is over. So the bar's window has room on either side of the bar,
// off the screen's edges, and the bar is drawn the other way by as much as the window is shifted.
//
// The follower runs on its own thread at every display refresh, reads the exact shift (to the fraction of
// a point) and offsets the bar's layer directly. That way the offset lands in the same refresh as Stage
// Manager's step, and the bar doesn't move at all; from the main thread it lands a refresh or more late
// (whenever the main thread is busy), and the bar visibly shakes.

import AppKit
import QuartzCore

final class StageShiftFollower: NSObject {
    static let shared = StageShiftFollower()

    /// One bar's window, as the main thread last placed it.
    struct Bar {
        var window: Int
        var layer: CALayer?          // holds the bar; shifted through its sublayerTransform
        var home: CGFloat = 0        // the window's x as AppKit placed it (global)
        var room: (left: CGFloat, right: CGFloat) = (0, 0)
        var scale: CGFloat = 2
        var active = false           // shown and not sliding (Mission Control)
        var settlesAt: CFTimeInterval = 0   // AppKit's own moves reach the window server a little later
    }

    private struct State {
        var shift: CGFloat?
        var drawn: CGFloat = 0
        var hidden = false
    }

    private let lock = NSLock()
    private var bars: [ObjectIdentifier: Bar] = [:]
    private var states: [ObjectIdentifier: State] = [:]
    private var paused = false
    private var followUntil: CFTimeInterval = 0
    #if SHEER_DEBUG
    var enabled = UserDefaults.standard.object(forKey: "followShifts") as? Bool ?? true
    #else
    let enabled = true
    #endif

    // MARK: From the main thread

    func update(_ owner: AnyObject, _ bar: Bar) {
        let id = ObjectIdentifier(owner)
        lock.lock()
        let wasActive = bars[id]?.active ?? false
        bars[id] = bar
        if !bar.active && wasActive { states[id] = State() }
        lock.unlock()
        if !bar.active { apply(0, hidden: false, to: bar) }
    }

    func remove(_ owner: AnyObject) {
        lock.lock(); bars[ObjectIdentifier(owner)] = nil; states[ObjectIdentifier(owner)] = nil; lock.unlock()
    }

    /// Space switches and Mission Control move the bar on purpose; leave it alone meanwhile.
    func setPaused(_ p: Bool) {
        lock.lock(); paused = p; lock.unlock()
    }

    /// A reading now (from the poll); starts following at every refresh if the shift is changing.
    func check() {
        lock.lock(); let running = link != nil; lock.unlock()
        guard !running else { return }   // followed at every refresh already
        if tick() { follow(for: 0.3) }
    }

    /// Follow at every display refresh for a while (a click may start a shift).
    func follow(for seconds: TimeInterval) {
        lock.lock()
        followUntil = max(followUntil, CACurrentMediaTime() + seconds)
        let running = link != nil
        lock.unlock()
        guard !running else { return }
        if #available(macOS 14, *) {
            guard let screen = NSScreen.screens.first else { return }
            let l = screen.displayLink(target: self, selector: #selector(refresh(_:)))
            lock.lock(); link = l; lock.unlock()
            perform(#selector(schedule(_:)), on: thread, with: l, waitUntilDone: false)
        } else if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13 {   // Stage Manager came with 13
            startLegacyLink()
        }
    }

    // MARK: On the follower's thread

    private var link: AnyObject?   // CADisplayLink on macOS 14+, CVDisplayLink before
    private lazy var thread: Thread = {
        let t = Thread { RunLoop.current.add(NSMachPort(), forMode: .default); RunLoop.current.run() }
        t.name = "Sheer.StageShift"
        t.qualityOfService = .userInteractive
        t.start()
        return t
    }()

    @available(macOS 14, *)
    @objc private func schedule(_ l: CADisplayLink) {
        l.add(to: .current, forMode: .common)
    }

    @available(macOS 14, *)
    @objc private func refresh(_ l: CADisplayLink) {
        if refreshed(l, at: l.timestamp) { l.invalidate() }
    }

    /// One display refresh. Returns true once following is over (the link is then to be stopped).
    private func refreshed(_ l: AnyObject, at time: CFTimeInterval) -> Bool {
        let busy = tick()
        lock.lock()
        if busy { followUntil = max(followUntil, time + 0.3) }
        let done = time > followUntil
        if done && link === l { link = nil }
        lock.unlock()
        return done
    }

    /// macOS 13 has no CADisplayLink on the Mac: a CVDisplayLink calls back at every refresh of the
    /// main display, on its own thread (explicit, flushed transactions work there too).
    private func startLegacyLink() {
        var made: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&made) == kCVReturnSuccess, let cv = made else { return }
        CVDisplayLinkSetOutputHandler(cv) { [weak self] l, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.lock.lock(); let current = self.link === l; self.lock.unlock()
            guard current else { return kCVReturnSuccess }   // already being stopped
            if self.refreshed(l, at: CACurrentMediaTime()) {
                DispatchQueue.global(qos: .userInteractive).async { CVDisplayLinkStop(l) }   // not from its own callback
            }
            return kCVReturnSuccess
        }
        lock.lock(); link = cv; lock.unlock()
        CVDisplayLinkStart(cv)
    }

    /// Read every bar's shift and draw it back in place. Returns true while a shift is changing.
    @discardableResult
    private func tick() -> Bool {
        let time = CACurrentMediaTime()
        lock.lock()
        guard enabled, !paused else { lock.unlock(); return false }
        let current = bars
        lock.unlock()
        var busy = false
        for (id, bar) in current where bar.active && time >= bar.settlesAt {
            guard let x = SkyLight.shownX(bar.window) else { continue }
            let shift = x - (bar.home - bar.room.left)
            lock.lock()
            var s = states[id] ?? State()
            let changing = s.shift.map { abs($0 - shift) > 0.01 } ?? false
            s.shift = shift
            let target = (shift * bar.scale).rounded() / bar.scale
            let hidden = target > bar.room.left + 0.5 || -target > bar.room.right + 0.5
            let redraw = target != s.drawn || hidden != s.hidden
            s.drawn = target; s.hidden = hidden
            states[id] = s
            lock.unlock()
            if redraw { apply(target, hidden: hidden, to: bar) }
            if changing { busy = true }
        }
        return busy
    }

    /// Draw the bar `shift` points to the left of its resting place. Beyond the room on that side it can't
    /// cover its place; it hides then and the system menu bar shows.
    private func apply(_ shift: CGFloat, hidden: Bool, to bar: Bar) {
        guard let layer = bar.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DMakeTranslation(-shift, 0, 0)
        layer.opacity = hidden ? 0 : 1
        CATransaction.commit()
        CATransaction.flush()
    }
}
