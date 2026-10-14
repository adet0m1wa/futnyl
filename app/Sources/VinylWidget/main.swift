import AppKit
@preconcurrency import RiveRuntime

/// A borderless, transparent window that lives on the desktop: above the
/// desktop icons, below ordinary windows, on every Space.
final class WidgetWindow: NSWindow {
    /// Shown when the vinyl is right-clicked (or control-clicked).
    var contextMenu: NSMenu?

    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // Right-click (or control-click) opens the same menu as the menu bar icon,
        // which can hide behind the notch on a busy menu bar.
        if let menu = contextMenu, let view = contentView,
           event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        // ⌘-drag (or ⌥-drag) anywhere on the widget moves it.
        if event.type == .leftMouseDown,
           !event.modifierFlags.intersection([.command, .option]).isEmpty {
            performDrag(with: event)
            return
        }
        // A desktop widget is almost never the focused window, and AppKit
        // swallows the first click on an unfocused window unless the view
        // accepts "first mouse", which the Rive view does not. Hand pointer
        // events straight to it so every click presses a key.
        if let view = contentView {
            switch event.type {
            case .leftMouseDown: view.mouseDown(with: event); return
            case .leftMouseDragged: view.mouseDragged(with: event); return
            case .leftMouseUp: view.mouseUp(with: event); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Key {
        static let floating = "floatAboveWindows"
        static let haptics = "haptics"
        static let size = "widgetSize"
    }
    private static let sizes: [(String, CGFloat)] = [("Small", 200), ("Medium", 270), ("Large", 360), ("Extra Large", 480)]

    private let defaults = UserDefaults.standard
    private let controller = VinylController()
    private var window: WidgetWindow!
    private var statusItem: NSStatusItem!
    private var spotifyItem: NSMenuItem!

    func applicationWillTerminate(_ notification: Notification) {
        controller.saveLastPlayed()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One vinyl at a time.
        let me = NSRunningApplication.current
        if let id = me.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            NSApp.terminate(nil)
            return
        }
        defaults.register(defaults: [Key.floating: false, Key.haptics: true, Key.size: 270.0])
        controller.hapticsEnabled = defaults.bool(forKey: Key.haptics)

        window = WidgetWindow(size: CGFloat(defaults.double(forKey: Key.size)))
        applyLevel()
        if !window.setFrameUsingName("VinylWidget") { placeDefault() }
        window.setFrameAutosaveName("VinylWidget")

        buildMenu()

        Task {
            do {
                let rive = try await controller.load()
                let view = RiveUIView(rive: rive)
                view.frame = window.contentLayoutRect
                view.autoresizingMask = [.width, .height]
                window.contentView = view
                window.orderFrontRegardless()
            } catch {
                let alert = NSAlert()
                alert.messageText = "The vinyl could not load"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                NSApp.terminate(nil)
            }
        }

        controller.spotify.onStatusText = { [weak self] text in self?.spotifyItem.title = text }
        installDebugHook()
    }

    /// Test hook, only with VINYL_DEBUG=1: a distributed notification named
    /// "com.adetomiwa.vinyl.debug" with object "click:x,y" (artboard units)
    /// sends a real mouse click through the window to the Rive view.
    private func installDebugHook() {
        guard ProcessInfo.processInfo.environment["VINYL_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.adetomiwa.vinyl.debug"), object: nil, queue: .main
        ) { [weak self] note in
            guard let command = note.object as? String, command.hasPrefix("click:") else { return }
            let xy = command.dropFirst(6).split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { return }
            MainActor.assumeIsolated { self?.debugClick(x: xy[0], y: xy[1]) }
        }
    }

    private func debugClick(x: Double, y: Double) {
        let scale = window.frame.width / 270
        let point = NSPoint(x: x * scale, y: window.frame.height - y * scale)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            window.sendEvent(event)
        }
        debugLog("debug click at \(x),\(y)")
    }

    // MARK: Window

    private func placeDefault() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 40, y: screen.maxY - size.height - 40))
    }

    private func applyLevel() {
        window.level = defaults.bool(forKey: Key.floating)
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    // MARK: Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "Futnyl")

        let menu = NSMenu()
        spotifyItem = NSMenuItem(title: "Spotify: not running", action: nil, keyEquivalent: "")
        spotifyItem.isEnabled = false
        menu.addItem(spotifyItem)
        menu.addItem(.separator())

        let float = NSMenuItem(title: "Float Above Windows", action: #selector(toggleFloating(_:)), keyEquivalent: "")
        float.state = defaults.bool(forKey: Key.floating) ? .on : .off
        menu.addItem(float)

        let haptics = NSMenuItem(title: "Trackpad Haptics", action: #selector(toggleHaptics(_:)), keyEquivalent: "")
        haptics.state = defaults.bool(forKey: Key.haptics) ? .on : .off
        menu.addItem(haptics)

        let sizeMenu = NSMenu()
        let current = defaults.double(forKey: Key.size)
        for (index, (name, size)) in Self.sizes.enumerated() {
            let item = NSMenuItem(title: name, action: #selector(setSize(_:)), keyEquivalent: "")
            item.tag = index
            item.state = current == Double(size) ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        let tip = NSMenuItem(title: "⌘-drag the vinyl to move it · right-click it for this menu", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        menu.addItem(tip)
        menu.addItem(NSMenuItem(title: "Quit Futnyl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        for item in sizeMenu.items { item.target = self }
        statusItem.menu = menu
        window.contextMenu = menu
    }

    @objc private func toggleFloating(_ sender: NSMenuItem) {
        let on = !defaults.bool(forKey: Key.floating)
        defaults.set(on, forKey: Key.floating)
        sender.state = on ? .on : .off
        applyLevel()
    }

    @objc private func toggleHaptics(_ sender: NSMenuItem) {
        let on = !defaults.bool(forKey: Key.haptics)
        defaults.set(on, forKey: Key.haptics)
        sender.state = on ? .on : .off
        controller.hapticsEnabled = on
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        let size = Self.sizes[sender.tag].1
        defaults.set(Double(size), forKey: Key.size)
        sender.menu?.items.forEach { $0.state = $0 == sender ? .on : .off }
        var frame = window.frame
        // Grow or shrink around the top-left corner, as people expect.
        frame.origin.y += frame.height - size
        frame.size = NSSize(width: size, height: size)
        window.setFrame(frame, display: true, animate: true)
    }

    @objc private func resetPosition() { placeDefault() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
