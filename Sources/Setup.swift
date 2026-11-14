// Permissions window. Lists what Sheer needs — Accessibility always, Screen Recording for wallpapers
// that have no file to read, Location for Dynamic wallpapers the desktop times by the Mac's position —
// with a button for each, and closes itself once nothing is missing.

import AppKit
import ApplicationServices

final class SetupWindowController: NSWindowController {
    private var timer: Timer?
    private var wasTrusted = AXIsProcessTrusted()
    /// Called when Accessibility has just been granted.
    var onGranted: (() -> Void)?
    /// Whether the current wallpaper can only be read from the screen.
    var needsScreenRecording: () -> Bool = { false }
    /// Whether the current wallpaper follows the sun as seen from the Mac's real position.
    var usesLocation: () -> Bool = { false }

    private let axTitle = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: L("setup.accessibility.button"), target: nil, action: nil)
    private let recTitle = NSTextField(labelWithString: "")
    private let recButton = NSButton(title: L("setup.recording.button"), target: nil, action: nil)
    private let locTitle = NSTextField(labelWithString: "")
    private let locButton = NSButton(title: L("setup.location.button"), target: nil, action: nil)
    private var locSection = NSStackView()

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Sheer"
        w.isReleasedWhenClosed = false
        self.init(window: w)
        guard let content = w.contentView else { return }

        func body(_ key: String) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: L(key))
            t.textColor = .secondaryLabelColor
            t.widthAnchor.constraint(equalToConstant: 420).isActive = true
            return t
        }
        let intro = NSTextField(wrappingLabelWithString: L("setup.intro"))
        intro.widthAnchor.constraint(equalToConstant: 420).isActive = true
        for t in [axTitle, recTitle, locTitle] { t.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        locButton.target = self; locButton.action = #selector(allowLocation)
        func section(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .vertical; s.alignment = .leading; s.spacing = 8
            return s
        }
        locSection = section([locTitle, body("setup.location.body"), locButton])
        axButton.target = self; axButton.action = #selector(openAccessibility)
        recButton.target = self; recButton.action = #selector(openScreenRecording)

        let stack = NSStackView(views: [intro, section([axTitle, body("setup.accessibility.body"), axButton]),
                                        section([recTitle, body("setup.recording.body"), recButton]), locSection])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        refresh()
    }

    func present() {
        wasTrusted = AXIsProcessTrusted()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func check() {
        guard window?.isVisible == true else { timer?.invalidate(); return }
        let (trusted, recording) = granted
        if trusted && !wasTrusted { onGranted?() }
        wasTrusted = trusted
        refresh()
        if trusted && (recording || !needsScreenRecording()) && !(locationRelevant && Location.shared.isUndetermined) {
            timer?.invalidate()
            window?.close()
        }
    }

    private var locationRelevant: Bool {
        #if SHEER_DEBUG
        if UserDefaults.standard.bool(forKey: "previewSetup") { return true }
        #endif
        return usesLocation()
    }

    private var granted: (accessibility: Bool, recording: Bool) {
        #if SHEER_DEBUG
        if UserDefaults.standard.bool(forKey: "previewSetup") { return (false, false) }   // to look at the window
        #endif
        return (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
    }

    /// Titles say what is still missing; a granted permission loses its button.
    private func refresh() {
        let (trusted, recording) = granted
        axTitle.stringValue = (trusted ? "✓ " : "") + L("setup.accessibility.title")
        axButton.isHidden = trusted
        axButton.keyEquivalent = trusted ? "" : "\r"
        let key = needsScreenRecording() ? "setup.recording.title.needed" : "setup.recording.title.optional"
        recTitle.stringValue = recording ? "✓ " + L("setup.recording.title.granted") : L(key)
        recButton.isHidden = recording
        recButton.keyEquivalent = trusted && !recording ? "\r" : ""
        // The location row only exists for wallpapers it matters to.
        let located = Location.shared.isAuthorized
        locSection.isHidden = !locationRelevant
        locTitle.stringValue = located ? "✓ " + L("setup.location.title.granted") : L("setup.location.title.needed")
        locButton.isHidden = located
    }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// The system prompts once; after a refusal only its Settings pane can change the answer.
    @objc private func allowLocation() {
        if Location.shared.isUndetermined { Location.shared.request() }
        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
    }

    @objc private func openScreenRecording() {
        CGRequestScreenCaptureAccess()   // adds Sheer to the list (and shows the system prompt the first time)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
