import AppKit
import Carbon

enum Mode: Int { case off = 0, hotkey = 1, auto = 2 }

struct Hotkey {
    let title: String
    let keyCode: Int64
    let flags: CGEventFlags
}

let hotkeyPresets: [Hotkey] = [
    Hotkey(title: "⌘ ⇧ A", keyCode: 0, flags: [.maskCommand, .maskShift]),
    Hotkey(title: "⌘ ⌥ A", keyCode: 0, flags: [.maskCommand, .maskAlternate]),
    Hotkey(title: "⌥ ⇧ Пробел", keyCode: 49, flags: [.maskAlternate, .maskShift]),
    Hotkey(title: "⌃ ⌥ L", keyCode: 37, flags: [.maskControl, .maskAlternate]),
]

enum Settings {
    private static let d = UserDefaults.standard
    static var mode: Mode {
        get { Mode(rawValue: d.object(forKey: "mode") as? Int ?? 2) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
    static var switchLayout: Bool {
        get { d.object(forKey: "switchLayout") as? Bool ?? true }
        set { d.set(newValue, forKey: "switchLayout") }
    }
    static var threshold: Int {
        get { max(1, d.object(forKey: "threshold") as? Int ?? 3) }
        set { d.set(newValue, forKey: "threshold") }
    }
    static var hotkeyIndex: Int {
        get { min(hotkeyPresets.count - 1, max(0, d.integer(forKey: "hotkey"))) }
        set { d.set(newValue, forKey: "hotkey") }
    }
    static let defaultExcluded = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "com.github.wez.wezterm",
        "org.alacritty", "net.kovidgoyal.kitty", "com.mitchellh.ghostty",
    ]
    static var excluded: [String] {
        get { d.stringArray(forKey: "excluded") ?? defaultExcluded }
        set { d.set(newValue, forKey: "excluded") }
    }
}

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Engine>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

/// Сердце: перехват клавиатуры, буфер последних слов, хоткей и автомат.
final class Engine {
    static let shared = Engine()

    private let marker: Int64 = 0x5241534B // "RASK": метка наших собственных событий
    private(set) var layouts: LayoutPair?
    private var speller: Speller?
    private var tap: CFMachPort?
    private let typingQueue = DispatchQueue(label: "raskladkin.typing")
    private var busy = false

    struct Word { var text: String; var verdict: Verdict }
    private var run: [Word] = []   // слова текущей серии (после последнего пробела каждое)
    private var current = ""       // слово, которое печатается сейчас

    var isTapRunning: Bool { tap != nil }
    var lastEvent = ""             // для отладки в меню

    // MARK: - Setup

    @discardableResult
    func reloadLayouts() -> Bool {
        layouts = LayoutPair(layouts: KeyboardLayout.all())
        speller = layouts.map(Speller.init)
        return layouts != nil
    }

    @discardableResult
    func startTap() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: tapCallback, userInfo: refcon) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reset() }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.reloadLayouts() }
        return true
    }

    func reset() {
        run = []
        current = ""
    }

    // MARK: - Event tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return pass }
        if type == .leftMouseDown || type == .rightMouseDown { reset(); return pass }
        guard type == .keyDown else { return pass }

        let mode = Settings.mode
        guard mode != .off else { return pass }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let hotkey = hotkeyPresets[Settings.hotkeyIndex]
        if code == hotkey.keyCode && flags == hotkey.flags {
            DispatchQueue.main.async { self.hotkeyPressed() }
            return nil // не пропускаем дальше, чтобы приложение не увидело сочетание
        }
        guard !busy else { return pass }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { reset(); return pass }

        switch code {
        case 36, 76, 48, 53, 123, 124, 125, 126, 115, 116, 119, 121, 117:
            // return, enter, tab, esc, стрелки, home, pgup, end, pgdn, forward delete
            reset()
            return pass
        case 51: // backspace
            if !current.isEmpty {
                current.removeLast()
            } else if let last = run.popLast() {
                current = last.text
            }
            return pass
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return pass }
        let s = String(utf16CodeUnits: chars, count: length)

        if s == " " {
            if let words = finalizeWord(mode: mode) {
                typingQueue.async { self.performAutoFix(words) }
                return nil // пробел проглатываем: перепечатаем его сами
            }
            return pass
        }
        guard let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F else {
            reset()
            return pass
        }
        current += s
        return pass
    }

    /// Завершает текущее слово по пробелу. Возвращает серию слов, если пора чинить автоматом.
    private func finalizeWord(mode: Mode) -> [Word]? {
        guard !current.isEmpty else { return nil }
        let word = current
        current = ""

        let autoAllowed = mode == .auto && !isExcludedApp() && !Bool(IsSecureEventInputEnabled())
        guard autoAllowed, let speller else {
            run.append(Word(text: word, verdict: .unknown))
            trimRun()
            return nil
        }
        let v = speller.verdict(word)
        if v == .keep {
            run = [Word(text: word, verdict: .keep)]
        } else {
            run.append(Word(text: word, verdict: v))
        }
        trimRun()
        let wrong = run.filter { $0.verdict == .convert }.count
        lastEvent = "\(word) → \(v), серия \(wrong)/\(Settings.threshold)"
        guard wrong >= Settings.threshold else { return nil }
        let fix = Array(run.drop(while: { $0.verdict == .keep }))
        run = []
        busy = true
        return fix
    }

    private func trimRun() {
        if run.count > 12 { run.removeFirst(run.count - 12) }
    }

    private func isExcludedApp() -> Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Settings.excluded.contains(id)
    }

    // MARK: - Auto fix

    private func performAutoFix(_ words: [Word]) {
        guard let layouts else { DispatchQueue.main.async { self.busy = false }; return }
        let n = words.reduce(0) { $0 + $1.text.count } + max(0, words.count - 1)
        var votes: [Direction: Int] = [:]
        for w in words where w.verdict == .convert {
            if let d = direction(for: script(of: w.text)) { votes[d, default: 0] += 1 }
        }
        let majority = votes.max { $0.value < $1.value }?.key ?? .enToRu
        let fixed = words.map { w -> String in
            let d = direction(for: script(of: w.text)) ?? majority
            return layouts.convert(w.text, d)
        }.joined(separator: " ")

        waitForModifiersReleased()
        sendBackspaces(n)
        typeText(fixed + " ")
        DispatchQueue.main.async {
            if Settings.switchLayout, let target = lang(for: script(of: fixed)) {
                layouts.layout(for: target).select()
            }
            self.reset()
            self.busy = false
        }
    }

    // MARK: - Hotkey

    private func hotkeyPressed() {
        guard !busy, layouts != nil else { return }
        if Bool(IsSecureEventInputEnabled()) { NSSound.beep(); return }
        busy = true
        if let sel = axSelectedText() {
            if sel.isEmpty { fixLastWord() } else { fixSelection(sel, saved: nil) }
        } else {
            probeSelectionViaCopy { [self] sel, saved in
                if let sel, !sel.isEmpty { fixSelection(sel, saved: saved) } else { fixLastWord() }
            }
        }
    }

    /// Выделенный текст через Accessibility. nil = приложение не отдаёт, надо пробовать ⌘C.
    private func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        let element = f as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        // Пустое выделение верим только настоящим текстовым полям; в веб-областях перепроверяем через ⌘C.
        if text.isEmpty && !["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return nil }
        return text
    }

    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    private func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let x = item.data(forType: t) { d[t] = x } }
            return d
        }
    }

    private func restore(_ pb: NSPasteboard, _ s: Snapshot) {
        pb.clearContents()
        guard !s.isEmpty else { return }
        pb.writeObjects(s.map { d in
            let item = NSPasteboardItem()
            for (t, x) in d { item.setData(x, forType: t) }
            return item
        })
    }

    private func probeSelectionViaCopy(_ done: @escaping (String?, Snapshot) -> Void) {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = snapshot(pb)
        typingQueue.async { [self] in
            waitForModifiersReleased()
            sendKey(8, flags: .maskCommand) // ⌘C
            usleep(150_000)
            DispatchQueue.main.async {
                guard pb.changeCount != before else { done(nil, saved); return }
                let types = (pb.types ?? []).map { $0.rawValue }
                let looksLikeObject = types.contains { $0.hasPrefix("public.png") || $0.hasPrefix("public.tiff")
                    || $0.hasPrefix("public.jpeg") || $0.contains("figma") || $0.contains("file-url") }
                let text = looksLikeObject ? nil : pb.string(forType: .string)
                if text == nil || text!.isEmpty { self.restore(pb, saved) }
                done(text, saved)
            }
        }
    }

    private func fixSelection(_ selection: String, saved: Snapshot?) {
        guard let speller, let layouts else { busy = false; return }
        let (fixed, changed) = speller.fix(selection)
        guard changed else { NSSound.beep(); busy = false; return }
        let pb = NSPasteboard.general
        let snap = saved ?? snapshot(pb)
        pb.clearContents()
        pb.setString(fixed, forType: .string)
        let origLang = lang(for: script(of: selection))
        let targetLang = lang(for: script(of: fixed))
        typingQueue.async { [self] in
            waitForModifiersReleased()
            sendKey(9, flags: .maskCommand) // ⌘V
            usleep(500_000)
            DispatchQueue.main.async {
                self.restore(pb, snap)
                if Settings.switchLayout, let t = targetLang, let o = origLang,
                   KeyboardLayout.current()?.lang.hasPrefix(o) == true {
                    layouts.layout(for: t).select()
                }
                self.reset()
                self.busy = false
            }
        }
    }

    private func fixLastWord() {
        guard let layouts else { busy = false; return }
        let text: String
        let trailingSpace: Bool
        if !current.isEmpty {
            text = current
            trailingSpace = false
        } else if let last = run.last {
            text = last.text
            trailingSpace = true
        } else {
            NSSound.beep()
            busy = false
            return
        }
        let currentIsRu = KeyboardLayout.current()?.lang.hasPrefix("ru") ?? false
        let dir = direction(for: script(of: text)) ?? (currentIsRu ? .ruToEn : .enToRu)
        let fixed = layouts.convert(text, dir)
        guard fixed != text else { NSSound.beep(); busy = false; return }
        let n = text.count + (trailingSpace ? 1 : 0)
        let out = fixed + (trailingSpace ? " " : "")
        typingQueue.async { [self] in
            waitForModifiersReleased()
            sendBackspaces(n)
            typeText(out)
            DispatchQueue.main.async {
                if Settings.switchLayout, let t = lang(for: script(of: fixed)) {
                    layouts.layout(for: t).select()
                }
                // Оставляем исправленное слово в буфере: повторное нажатие вернёт как было.
                self.run = trailingSpace ? [Word(text: fixed, verdict: .unknown)] : []
                self.current = trailingSpace ? "" : fixed
                self.busy = false
            }
        }
    }

    // MARK: - Sending keys (только на typingQueue)

    private func waitForModifiersReleased() {
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        for _ in 0..<60 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mods).isEmpty { return }
            usleep(20_000)
        }
    }

    private func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cgSessionEventTap)
        usleep(4_000)
    }

    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        post(down)
        post(up)
    }

    private func sendBackspaces(_ n: Int) {
        for _ in 0..<n { sendKey(51) }
    }

    private func typeText(_ s: String) {
        for ch in s {
            var units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            post(down)
            post(up)
        }
    }
}
