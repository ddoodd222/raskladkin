import Carbon
import Foundation

/// Одна клавиатурная раскладка из системы (ABC, Russian и т.п.).
final class KeyboardLayout {
    let source: TISInputSource
    let id: String
    let lang: String
    let name: String
    private let layoutData: CFData

    private static func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }

    init?(_ source: TISInputSource) {
        guard let type = KeyboardLayout.property(source, kTISPropertyInputSourceType) as? String,
              type == (kTISTypeKeyboardLayout as String),
              let id = KeyboardLayout.property(source, kTISPropertyInputSourceID) as? String,
              let langs = KeyboardLayout.property(source, kTISPropertyInputSourceLanguages) as? [String],
              let lang = langs.first,
              let name = KeyboardLayout.property(source, kTISPropertyLocalizedName) as? String,
              let data = KeyboardLayout.property(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        self.source = source
        self.id = id
        self.lang = lang
        self.name = name
        self.layoutData = unsafeBitCast(data, to: CFData.self)
    }

    var isEnabled: Bool { (KeyboardLayout.property(source, kTISPropertyInputSourceIsEnabled) as? Bool) ?? false }
    var isSelectable: Bool { (KeyboardLayout.property(source, kTISPropertyInputSourceIsSelectCapable) as? Bool) ?? false }

    /// Какой символ даёт клавиша в этой раскладке.
    func character(keyCode: UInt16, shift: Bool) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { ptr -> String? in
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(ptr, keyCode, UInt16(kUCKeyActionDown), shift ? 2 : 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    func select() { TISSelectInputSource(source) }

    static func all() -> [KeyboardLayout] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        return (list as NSArray)
            .map { unsafeBitCast($0 as AnyObject, to: TISInputSource.self) }
            .compactMap(KeyboardLayout.init)
            .filter { $0.isEnabled && $0.isSelectable }
    }

    static func current() -> KeyboardLayout? {
        guard let s = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyboardLayout(s)
    }
}

enum Direction { case enToRu, ruToEn }

/// Пара раскладок EN/RU и таблица соответствия символов, снятая с самой системы.
final class LayoutPair {
    let en: KeyboardLayout
    let ru: KeyboardLayout
    private var enToRu: [Character: Character] = [:]
    private var ruToEn: [Character: Character] = [:]

    init?(layouts: [KeyboardLayout]) {
        guard let en = layouts.first(where: { $0.lang.hasPrefix("en") }),
              let ru = layouts.first(where: { $0.lang.hasPrefix("ru") }) else { return nil }
        self.en = en
        self.ru = ru
        for shift in [false, true] {
            for code in 0..<128 {
                guard let a = en.character(keyCode: UInt16(code), shift: shift),
                      let b = ru.character(keyCode: UInt16(code), shift: shift),
                      a.count == 1, b.count == 1,
                      let ca = a.first, let cb = b.first, ca != cb else { continue }
                if enToRu[ca] == nil { enToRu[ca] = cb }
                if ruToEn[cb] == nil { ruToEn[cb] = ca }
            }
        }
    }

    func convert(_ s: String, _ direction: Direction) -> String {
        let map = direction == .enToRu ? enToRu : ruToEn
        return String(s.map { map[$0] ?? $0 })
    }

    func layout(for lang: String) -> KeyboardLayout { lang.hasPrefix("ru") ? ru : en }

    var mappingDescription: String {
        enToRu.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" }.joined(separator: " ")
    }
}
