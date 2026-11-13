// Reads the frontmost app's menu titles and their exact frames through the Accessibility API.

import AppKit
import ApplicationServices

struct MenuTitle: Equatable {
    enum Kind { case apple, appName, normal }
    let title: String
    let frame: CGRect      // global CG coordinates (top-left origin)
    let kind: Kind
    let selected: Bool
    let enabled: Bool
}

private func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

private func axPoint(_ v: CFTypeRef?) -> CGPoint? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

private func axSize(_ v: CFTypeRef?) -> CGSize? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

private let axCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    Unmanaged<MenuBarReader>.fromOpaque(refcon).takeUnretainedValue().scheduleRefresh()
}

final class MenuBarReader {
    var onChange: (() -> Void)?
    private(set) var items: [MenuTitle] = []
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var pending = false

    /// True when every menu can be redrawn as text. Some apps put icons instead of titles in the
    /// menu bar; Sheer can't redraw those, so it falls back to the system menu bar for that app.
    var isDrawable: Bool {
        !items.isEmpty && items.dropFirst().allSatisfy { !$0.title.isEmpty }
    }

    func attach(to app: NSRunningApplication?) {
        detach()
        guard let app, AXIsProcessTrusted() else { update([]); return }
        let pid = app.processIdentifier
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        appElement = el

        var obs: AXObserver?
        if AXObserverCreate(pid, axCallback, &obs) == .success, let obs {
            let ref = Unmanaged.passUnretained(self).toOpaque()
            for n in [kAXMenuOpenedNotification, kAXMenuClosedNotification,
                      kAXMenuItemSelectedNotification, kAXTitleChangedNotification,
                      kAXUIElementDestroyedNotification, kAXCreatedNotification] {
                AXObserverAddNotification(obs, el, n as CFString, ref)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observer = obs
        }
        refresh()
    }

    func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
    }

    /// Coalesce bursts of notifications; the "selected" state sometimes updates just after the
    /// notification arrives, so read once more a moment later.
    func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self?.refresh() }
        }
    }

    func refresh() {
        guard let el = appElement, AXIsProcessTrusted() else { update([]); return }
        guard let barRef = axCopy(el, kAXMenuBarAttribute), CFGetTypeID(barRef) == AXUIElementGetTypeID() else {
            update([]); return
        }
        let bar = barRef as! AXUIElement
        guard let children = axCopy(bar, kAXChildrenAttribute) as? [AXUIElement] else { update([]); return }

        let attrs = [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                     kAXSelectedAttribute, kAXEnabledAttribute] as CFArray
        var result: [MenuTitle] = []
        for (i, child) in children.enumerated() {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(child, attrs, [], &values) == .success,
                  let arr = values as? [AnyObject], arr.count == 5 else { continue }
            let title = arr[0] as? String ?? ""
            guard let pos = axPoint(arr[1]), let size = axSize(arr[2]), size.width > 1, size.height > 1 else { continue }
            let kind: MenuTitle.Kind = i == 0 ? .apple : (i == 1 ? .appName : .normal)
            result.append(MenuTitle(title: title, frame: CGRect(origin: pos, size: size), kind: kind,
                                    selected: (arr[3] as? Bool) ?? false, enabled: (arr[4] as? Bool) ?? true))
        }
        update(result)
    }

    private func update(_ new: [MenuTitle]) {
        guard new != items else { return }
        items = new
        Debug.write(new.map { "\($0.title)\t\($0.frame)\tsel=\($0.selected)" }.joined(separator: "\n"), "menus.txt")
        onChange?()
    }
}
