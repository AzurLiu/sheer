// Permissions window. Lists what Sheer needs — Accessibility always, Screen Recording for wallpapers
// that have no file to read — with a button for each, and closes itself once nothing is missing.

import AppKit
import ApplicationServices

final class SetupWindowController: NSWindowController {
    private var timer: Timer?
    private var wasTrusted = AXIsProcessTrusted()
    /// Called when Accessibility has just been granted.
    var onGranted: (() -> Void)?
    /// Whether the current wallpaper can only be read from the screen.
    var needsScreenRecording: () -> Bool = { false }

    private let axTitle = NSTextField(labelWithString: "")
    private let axButton = NSButton(title: L("setup.accessibility.button"), target: nil, action: nil)
    private let recTitle = NSTextField(labelWithString: "")
    private let recButton = NSButton(title: L("setup.recording.button"), target: nil, action: nil)

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
        for t in [axTitle, recTitle] { t.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        axButton.target = self; axButton.action = #selector(openAccessibility)
        recButton.target = self; recButton.action = #selector(openScreenRecording)

        let stack = NSStackView(views: [intro, axTitle, body("setup.accessibility.body"), axButton,
                                        recTitle, body("setup.recording.body"), recButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: intro)
        stack.setCustomSpacing(20, after: axButton)
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
        if trusted && (recording || !needsScreenRecording()) {
            timer?.invalidate()
            window?.close()
        }
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
    }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecording() {
        CGRequestScreenCaptureAccess()   // adds Sheer to the list (and shows the system prompt the first time)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
