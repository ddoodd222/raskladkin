import AppKit
import ServiceManagement

// Режим проверки из терминала: Raskladkin --check слово1 слово2 / --fix "текст"
let cliArgs = CommandLine.arguments
if cliArgs.count > 1, ["--check", "--fix", "--map"].contains(cliArgs[1]) {
    guard let pair = LayoutPair(layouts: KeyboardLayout.all()) else { print("Не нашёл пару раскладок EN/RU"); exit(1) }
    let speller = Speller(layouts: pair)
    switch cliArgs[1] {
    case "--map":
        print("EN:", pair.en.name, "RU:", pair.ru.name)
        print(pair.mappingDescription)
    case "--check":
        for w in cliArgs.dropFirst(2) {
            let d = direction(for: script(of: w)) ?? .enToRu
            print("\(w) → \(pair.convert(w, d))  \(speller.verdict(w))")
        }
    default:
        let (t, changed) = speller.fix(cliArgs.dropFirst(2).joined(separator: " "))
        print(t, changed ? "" : "(без изменений)")
    }
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var permissionTimer: Timer?
    private var askedInputMonitoring = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        Engine.shared.reloadLayouts()
        requestAccess()
        updateIcon()
    }

    // MARK: - Права

    private func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            start()
        } else {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.start()
            }
        }
    }

    private func start() {
        if !Engine.shared.startTap() {
            if !askedInputMonitoring {
                askedInputMonitoring = true
                CGRequestListenEventAccess()
            }
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard Engine.shared.startTap() else { return }
                timer.invalidate()
                self?.updateIcon()
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let running = Engine.shared.isTapRunning
        let name = running ? "keyboard" : "keyboard.badge.ellipsis"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Раскладкин")
        button.image?.isTemplate = true
        button.appearsDisabled = !running || Settings.mode == .off
    }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = Engine.shared

        let status: String
        if !engine.isTapRunning { status = "Нет доступа — дай права в настройках" }
        else if engine.layouts == nil { status = "Не нашёл раскладки EN + RU" }
        else { status = "Раскладкин работает" }
        menu.addItem(disabled(status))
        if engine.isTapRunning && !engine.lastEvent.isEmpty { menu.addItem(disabled(engine.lastEvent)) }
        menu.addItem(.separator())

        for (title, mode) in [("Хоткей + автомат", Mode.auto), ("Только хоткей", .hotkey), ("Выключен", .off)] {
            let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = Settings.mode == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let sw = NSMenuItem(title: "Переключать раскладку после исправления", action: #selector(toggleSwitchLayout), keyEquivalent: "")
        sw.target = self
        sw.state = Settings.switchLayout ? .on : .off
        menu.addItem(sw)

        let thresholdMenu = NSMenu()
        for n in 2...4 {
            let item = NSMenuItem(title: "\(n) \(n == 2 ? "слова" : "слова")", action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = n
            item.state = Settings.threshold == n ? .on : .off
            thresholdMenu.addItem(item)
        }
        let thresholdItem = NSMenuItem(title: "Автомат срабатывает после", action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        let hotkeyMenu = NSMenu()
        for (i, hk) in hotkeyPresets.enumerated() {
            let item = NSMenuItem(title: hk.title, action: #selector(setHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = i
            item.state = Settings.hotkeyIndex == i ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Хоткей", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let exclMenu = NSMenu()
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let name = front?.localizedName ?? id
            let item = NSMenuItem(title: "Молчать в «\(name)»", action: #selector(toggleExcluded(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = Settings.excluded.contains(id) ? .on : .off
            exclMenu.addItem(item)
            exclMenu.addItem(.separator())
        }
        for id in Settings.excluded where id != front?.bundleIdentifier {
            let name = appName(for: id)
            let item = NSMenuItem(title: name, action: #selector(toggleExcluded(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = .on
            exclMenu.addItem(item)
        }
        let exclItem = NSMenuItem(title: "Автомат молчит в приложениях", action: nil, keyEquivalent: "")
        exclItem.submenu = exclMenu
        menu.addItem(exclItem)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let access = NSMenuItem(title: "Открыть настройки доступа…", action: #selector(openAccess), keyEquivalent: "")
        access.target = self
        menu.addItem(access)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: - Действия

    @objc private func setMode(_ sender: NSMenuItem) {
        Settings.mode = Mode(rawValue: sender.representedObject as? Int ?? 2) ?? .auto
        Engine.shared.reset()
        updateIcon()
    }
    @objc private func toggleSwitchLayout() { Settings.switchLayout.toggle() }
    @objc private func setThreshold(_ sender: NSMenuItem) { Settings.threshold = sender.representedObject as? Int ?? 3 }
    @objc private func setHotkey(_ sender: NSMenuItem) { Settings.hotkeyIndex = sender.representedObject as? Int ?? 0 }
    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var list = Settings.excluded
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        Settings.excluded = list
    }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }
    @objc private func openAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
