import AppKit
import ServiceManagement
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let model = NowPlayingModel()
    private var controller: LockScreenController!
    private var observer: LockObserver!
    private var statusItem: NSStatusItem!
    private var modeSub: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = LockScreenController(model: model, settings: settings)
        observer = LockObserver(
            onLock:   { [weak self] in Task { @MainActor in self?.controller.show() } },
            onUnlock: { [weak self] in Task { @MainActor in self?.controller.hide() } })
        model.start()

        // Trigger the "System Audio Recording" permission prompt now (it can't appear on the lock screen).
        AudioSpectrum.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AudioSpectrum.shared.stop() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        rebuildMenu()
        // the card's artwork can switch the mode too, so keep the menu checkmark in sync
        modeSub = settings.$mode.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }
    }

    private func rebuildMenu() {
        statusItem.button?.image = MenuBarIcon.image()
        let menu = NSMenu()
        for mode in LockMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.target = self
            item.state = settings.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        // Card colour: black / white / automatic
        let colorMenu = NSMenu()
        for t in CardTone.allCases {
            let item = NSMenuItem(title: t.title, action: #selector(pickTone(_:)), keyEquivalent: "")
            item.representedObject = t.rawValue
            item.target = self
            item.state = settings.tone == t ? .on : .off
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Card Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // Text & buttons colour: white / black / automatic (follows the card colour)
        let textMenu = NSMenu()
        for t in TextTone.allCases {
            let item = NSMenuItem(title: t.title, action: #selector(pickTextTone(_:)), keyEquivalent: "")
            item.representedObject = t.rawValue
            item.target = self
            item.state = settings.textTone == t ? .on : .off
            textMenu.addItem(item)
        }
        let textItem = NSMenuItem(title: "Text & Buttons", action: nil, keyEquivalent: "")
        textItem.submenu = textMenu
        menu.addItem(textItem)

        // Border opacity: 0 ... 100 % in steps of 10 % (30 % = default)
        let borderMenu = NSMenu()
        for pct in stride(from: 100, through: 0, by: -10) {
            let v = Double(pct) / 100
            let title = pct == 0 ? "Off" : "\(pct)%" + (pct == 30 ? "  (default)" : "")
            let item = NSMenuItem(title: title, action: #selector(pickBorder(_:)), keyEquivalent: "")
            item.representedObject = v
            item.target = self
            item.state = abs(settings.borderOpacity - v) < 0.001 ? .on : .off
            borderMenu.addItem(item)
        }
        let borderItem = NSMenuItem(title: "Border Opacity", action: nil, keyEquivalent: "")
        borderItem.submenu = borderMenu
        menu.addItem(borderItem)

        // Dimming: 0.0 ... 1.0 in steps of 0.1 (default 0.1)
        let dimMenu = NSMenu()
        for i in 0...10 {
            let v = Double(i) / 10
            let title = String(format: "%.1f", v) + (i == 1 ? "  (default)" : "")
            let item = NSMenuItem(title: title, action: #selector(pickDim(_:)), keyEquivalent: "")
            item.representedObject = v
            item.target = self
            item.state = abs(settings.dim - v) < 0.001 ? .on : .off
            dimMenu.addItem(item)
        }
        let dimItem = NSMenuItem(title: "Dimming", action: nil, keyEquivalent: "")
        dimItem.submenu = dimMenu
        menu.addItem(dimItem)

        // Blur: 0 ... 100 % in steps of 10 %
        let blurMenu = NSMenu()
        for pct in stride(from: 0, through: 100, by: 10) {
            let v = Double(pct) / 100
            let item = NSMenuItem(title: "\(pct)%" + (pct == 20 ? "  (default)" : ""), action: #selector(pickBlur(_:)), keyEquivalent: "")
            item.representedObject = v
            item.target = self
            item.state = abs(settings.blur - v) < 0.001 ? .on : .off
            blurMenu.addItem(item)
        }
        let blurItem = NSMenuItem(title: "Blur", action: nil, keyEquivalent: "")
        blurItem.submenu = blurMenu
        menu.addItem(blurItem)

        menu.addItem(.separator())
        let preview = NSMenuItem(title: "Preview (8 s)", action: #selector(preview), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = LockMode(rawValue: raw) {
            settings.mode = m
            rebuildMenu()
        }
    }
    @objc private func pickTone(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = CardTone(rawValue: raw) {
            settings.tone = t
            rebuildMenu()
        }
    }
    @objc private func pickTextTone(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = TextTone(rawValue: raw) {
            settings.textTone = t
            rebuildMenu()
        }
    }
    @objc private func pickBorder(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { settings.borderOpacity = v; rebuildMenu() }
    }
    @objc private func pickDim(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { settings.dim = v; rebuildMenu() }
    }
    @objc private func pickBlur(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { settings.blur = v; rebuildMenu() }
    }
    @objc private func preview() { controller.preview() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Login item error: \(error)") }
        rebuildMenu()
    }
}
