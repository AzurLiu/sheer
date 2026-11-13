// One-time Accessibility onboarding window. Closes itself as soon as permission is granted.

import AppKit
import ApplicationServices

final class SetupWindowController: NSWindowController {
    private var timer: Timer?
    var onGranted: (() -> Void)?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Sheer"
        w.isReleasedWhenClosed = false
        self.init(window: w)
        guard let content = w.contentView else { return }
        let text = NSTextField(wrappingLabelWithString: L("setup.message"))
        let button = NSButton(title: L("setup.button"), target: self, action: #selector(openAX))
        button.keyEquivalent = "\r"
        let stack = NSStackView(views: [text, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            text.widthAnchor.constraint(equalToConstant: 380),
        ])
    }

    func present() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.timer?.invalidate()
            self.window?.close()
            self.onGranted?()
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
