import Cocoa
import IOKit.hid
import ApplicationServices
import CryptoKit

struct KeySpec {
    let id: String
    let label: String
    let usage: String?
    let rect: NSRect
    var configurable: Bool { usage != nil }
}

struct Assignment: Codable, Equatable {
    var signal: String
    var action: String
    var browserOnly: Bool
    var customShortcut: Shortcut? = nil
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64
    var keyLabel: String
    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }
    var displayName: String {
        let marks = [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        return marks.filter { flags.contains($0.0) }.map { $0.1 }.joined() + keyLabel
    }
    var valid: Bool {
        shortcutKeys.contains { $0.0 == keyCode && $0.1 == keyLabel } &&
        modifiers & ~shortcutModifierMask == 0 && modifiers != 0
    }
}

let shortcutModifierMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
let adapterEventTag: Int64 = 0x43484D4143
let targetDeviceMatch: [String: Int] = [kIOHIDVendorIDKey: 0x0687, kIOHIDProductIDKey: 0x00E9]
let targetDeviceMatches: [[String:Any]] = [targetDeviceMatch,
    [kIOHIDVendorIDKey:0x046A,kIOHIDProductIDKey:0x01CE,kIOHIDTransportKey:"USB"]]
let shortcutKeys: [(UInt16, String)] = [
    (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"),
    (4, "H"), (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"),
    (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"),
    (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
    (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"),
    (26, "7"), (28, "8"), (25, "9"), (29, "0"), (49, "Space"), (36, "Enter"),
    (48, "Tab"), (53, "Esc"), (51, "Backspace"),
    (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
    (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"),
    (98, "F7"), (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")
]

struct ConfigurationFile: Codable {
    let format: String
    let version: Int
    let assignments: [String: Assignment]
    let learnedSignals: [String: String]
}

enum ConfigurationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let reason) = self { return reason }
        return nil
    }
}

func validSignal(_ signal: String) -> Bool {
    let parts = signal.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let page = UInt32(parts[0]), let usage = UInt32(parts[1]),
          page <= 0xFFFF, usage > 3, usage <= 0xFFFF else { return false }
    guard page == 7 || page == 12 || page >= 0xFF00 else { return false }
    return !(page == 7 && (0xE0...0xE7).contains(usage))
}

func validateConfiguration(_ file: ConfigurationFile) throws {
    guard file.format == "CherryMac", file.version == 1 else {
        throw ConfigurationError.invalid("这不是受支持的 CherryMac 配置文件。")
    }
    let configurableIDs = Set(keyboardLayout().filter { $0.configurable }.map { $0.id }).union(["calculator", "browser", "mediaPlay", "cherry"])
    var seen = Set<String>()
    for (id, assignment) in file.assignments {
        guard configurableIDs.contains(id), validSignal(assignment.signal),
              actions.contains(where: { $0.0 == assignment.action && $0.0 != "none" }) else {
            throw ConfigurationError.invalid("配置中包含无效按键或功能：\(id)。")
        }
        guard seen.insert(assignment.signal).inserted else {
            throw ConfigurationError.invalid("配置中存在重复的实体按键信号。")
        }
        if assignment.action == "custom", assignment.customShortcut?.valid != true {
            throw ConfigurationError.invalid("自定义快捷键需要有效的主键和修饰键。")
        }
    }
    for (id, signal) in file.learnedSignals {
        guard configurableIDs.contains(id), validSignal(signal) else {
            throw ConfigurationError.invalid("配置中包含无效的学习按键：\(id)。")
        }
        if let assignment = file.assignments[id], assignment.signal != signal {
            throw ConfigurationError.invalid("学习信号与功能设置不一致：\(id)。")
        }
    }
}

let actions: [(String, String)] = [
    ("none", "保留原功能"), ("screenshot", "框选区域截图"),
    ("screenshotToolbar", "打开截图工具栏"), ("calculator", "打开计算器"),
    ("refresh", "刷新页面 · ⌘R"), ("find", "查找 · ⌘F"),
    ("newTab", "新建标签页 · ⌘T"), ("closeTab", "关闭标签页 · ⌘W"),
    ("copy", "复制 · ⌘C"), ("paste", "粘贴 · ⌘V"),
    ("undo", "撤销 · ⌘Z"), ("spotlight", "打开 Spotlight"),
    ("custom", "自定义快捷键…")
]
let browserIDs: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "app.zen-browser.zen"]

func keyboardLayout() -> [KeySpec] {
    var keys: [KeySpec] = []
    let unit: CGFloat = 36
    func add(_ id: String, _ label: String, _ usage: Int?, _ x: CGFloat, _ row: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1, _ page: Int = 7) {
        keys.append(KeySpec(id: id, label: label, usage: usage.map { "\(page):\($0)" }, rect: NSRect(x: 18 + x * unit, y: 20 + row * unit, width: w * unit - 4, height: h * unit - 4)))
    }
    add("esc", "Esc", 41, 0, 0)
    add("cherry", "CHERRY", nil, 1, 0)
    for i in 1...12 { add("f\(i)", "F\(i)", 57 + i, 2 + CGFloat(i - 1) + CGFloat((i - 1) / 4) * 0.5, 0) }
    for (i, item) in [("print", "截屏", 70), ("scroll", "Scroll", 71), ("pause", "Pause", 72)].enumerated() { add(item.0, item.1, item.2, 15.5 + CGFloat(i), 0) }
    // User-confirmed dedicated keys directly above Num, /, × and −.
    for (i, item) in [("calculator", "计算器", 402), ("mediaPrevious", "上一曲", 182), ("mediaPlay", "暂停", 205), ("mediaNext", "下一曲", 181)].enumerated() {
        add(item.0, item.1, item.2, 19 + CGFloat(i), 0, 1, 1, 12)
    }
    let numberRow: [(String, Int)] = [("`", 53), ("1", 30), ("2", 31), ("3", 32), ("4", 33), ("5", 34), ("6", 35), ("7", 36), ("8", 37), ("9", 38), ("0", 39), ("−", 45), ("=", 46)]
    for (i, item) in numberRow.enumerated() { add("key\(item.1)", item.0, item.1, CGFloat(i), 1.2) }
    add("backspace", "Backspace", 42, 13, 1.2, 2)
    func letterRow(_ letters: String, _ start: CGFloat, _ row: CGFloat) {
        for (i, c) in letters.enumerated() {
            let usage = Int(c.asciiValue!) - 65 + 4
            add("key\(usage)", String(c), usage, start + CGFloat(i), row)
        }
    }
    add("tab", "Tab", 43, 0, 2.2, 1.5)
    letterRow("QWERTYUIOP", 1.5, 2.2)
    add("key47", "[", 47, 11.5, 2.2)
    add("key48", "]", 48, 12.5, 2.2)
    add("key49", "\\", 49, 13.5, 2.2, 1.5)
    add("caps", "Caps", nil, 0, 3.2, 1.75)
    letterRow("ASDFGHJKL", 1.75, 3.2)
    add("key51", ";", 51, 10.75, 3.2)
    add("key52", "'", 52, 11.75, 3.2)
    add("enter", "Enter", 40, 12.75, 3.2, 2.25)
    add("shiftL", "Shift", nil, 0, 4.2, 2.25)
    letterRow("ZXCVBNM", 2.25, 4.2)
    add("key54", ",", 54, 9.25, 4.2)
    add("key55", ".", 55, 10.25, 4.2)
    add("key56", "/", 56, 11.25, 4.2)
    add("shiftR", "Shift", nil, 12.25, 4.2, 2.75)
    for (i, label) in ["Ctrl", "Win", "Alt"].enumerated() { add("modL\(i)", label, nil, CGFloat(i) * 1.25, 5.2, 1.25) }
    add("space", "Space", 44, 3.75, 5.2, 6.25)
    for (i, label) in ["Alt", "Fn", "Menu", "Ctrl"].enumerated() { add(label == "Menu" ? "modR3" : (i == 3 ? "modR2" : "modR\(i)"), label, label == "Menu" ? 101 : nil, 10 + CGFloat(i) * 1.25, 5.2, 1.25) }
    for (i, item) in [("insert", "Ins", 73), ("home", "Home", 74), ("pageUp", "PgUp", 75)].enumerated() { add(item.0, item.1, item.2, 15.5 + CGFloat(i), 1.2) }
    for (i, item) in [("delete", "Del", 76), ("end", "End", 77), ("pageDown", "PgDn", 78)].enumerated() { add(item.0, item.1, item.2, 15.5 + CGFloat(i), 2.2) }
    add("up", "↑", 82, 16.5, 4.2)
    for (i, item) in [("left", "←", 80), ("down", "↓", 81), ("right", "→", 79)].enumerated() { add(item.0, item.1, item.2, 15.5 + CGFloat(i), 5.2) }
    for (i, item) in [("numLock", "Num", 83), ("numDivide", "/", 84), ("numMultiply", "×", 85), ("numMinus", "−", 86)].enumerated() { add(item.0, item.1, item.2, 19 + CGFloat(i), 1.2) }
    for (i, item) in [("num7", "7", 95), ("num8", "8", 96), ("num9", "9", 97)].enumerated() { add(item.0, item.1, item.2, 19 + CGFloat(i), 2.2) }
    add("numPlus", "+", 87, 22, 2.2, 1, 2)
    for (i, item) in [("num4", "4", 92), ("num5", "5", 93), ("num6", "6", 94)].enumerated() { add(item.0, item.1, item.2, 19 + CGFloat(i), 3.2) }
    for (i, item) in [("num1", "1", 89), ("num2", "2", 90), ("num3", "3", 91)].enumerated() { add(item.0, item.1, item.2, 19 + CGFloat(i), 4.2) }
    add("numEnter", "Enter", 88, 22, 4.2, 1, 2)
    add("num0", "0", 98, 19, 5.2, 2)
    add("numDot", ".", 99, 21, 5.2)
    return keys
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class KeyButton: NSButton {
    let spec: KeySpec
    var hardwareConfigurable=false
    var lightingColor:NSColor? {didSet{needsDisplay=true}}
    var chosen = false { didSet { needsDisplay = true } }
    var mapped = false { didSet { needsDisplay = true } }
    init(_ spec: KeySpec) {
        self.spec = spec
        super.init(frame: spec.rect)
        title = spec.label
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel("\(spec.label) 键")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.8, dy: 0.8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill: NSColor = lightingColor?.blended(withFraction:0.22,of:.controlBackgroundColor) ?? (chosen ? .controlAccentColor : (isHighlighted ? .selectedControlColor : .controlBackgroundColor))
        fill.setFill(); path.fill()
        (chosen ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = chosen ? 2 : 1
        path.stroke()
        var color: NSColor = chosen ? .white : ((spec.configurable || hardwareConfigurable) ? .labelColor : .secondaryLabelColor)
        if lightingColor != nil,let rgb=fill.usingColorSpace(.sRGB){color=(rgb.redComponent*0.2126+rgb.greenComponent*0.7152+rgb.blueComponent*0.0722)>0.5 ? .black:.white}
        var font = NSFont.systemFont(ofSize: title.count > 6 ? 9 : 11, weight: chosen ? .semibold : .medium)
        if (title as NSString).size(withAttributes: [.font: font]).width > bounds.width - 4 {
            font = .systemFont(ofSize: 9, weight: chosen ? .semibold : .medium)
        }
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = title as NSString
        let size = text.size(withAttributes: attr)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attr)
        if mapped {
            (chosen ? NSColor.white : NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: bounds.height - 9, width: 4, height: 4)).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4)
            focus.lineWidth = 2; focus.stroke()
        }
    }
}

final class Adapter: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var manager: IOHIDManager?
    let hidQueue = DispatchQueue(label: "local.cherrymac.input", qos: .userInteractive)
    let inputLedger = RawInputLedger()
    lazy var eventRouter = KeyboardEventRouter(ledger: inputLedger)
    var managerToken = UUID()
    var retiredManagers: [UUID: IOHIDManager] = [:]
    var replaceOriginal = true
    var window: NSWindow!
    let defaults: UserDefaults
    let keys = keyboardLayout()
    var buttons: [String: KeyButton] = [:]
    var assignments: [String: Assignment] = [:]
    var signals: [String: String] = [:]
    var selected = "print"
    var learning: String?
    var timeout: Timer?
    var held = Set<String>()
    var modifiers = Set<String>()
    var paused = false
    var hardwareWindow: HardwareWindowController?
    var permissionTimer: Timer?
    var pauseItem: NSMenuItem?
    var startupWarning: String?
    var lastInput: String?
    var lastAction: String?
    var frontmostProvider: (() -> (String?, Int32))?
    var actionSink: ((String, Shortcut?) -> Void)?
    var runtimeStatusURL: URL?
    var lastStatusData: Data?
    var deviceOpenResult: IOReturn?
    let message = NSTextField(wrappingLabelWithString: "")
    let selectionTitle = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let mappingSummary = NSTextField(wrappingLabelWithString: "")
    let actionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let scope = NSButton(checkboxWithTitle: "仅在浏览器中生效", target: nil, action: nil)
    let shortcutPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let command = NSButton(checkboxWithTitle: "⌘", target: nil, action: nil)
    let shift = NSButton(checkboxWithTitle: "⇧", target: nil, action: nil)
    let option = NSButton(checkboxWithTitle: "⌥", target: nil, action: nil)
    let control = NSButton(checkboxWithTitle: "⌃", target: nil, action: nil)
    let customControls = FlippedView()
    let permissionStatus = NSTextField(labelWithString: "")
    let pauseToggle = NSButton(checkboxWithTitle: "暂停适配", target: nil, action: nil)
    let inputMode = NSPopUpButton(frame: .zero, pullsDown: false)
    let behaviorNote = NSTextField(wrappingLabelWithString: "")
    var saveButton: NSButton!
    var learnButton: NSButton!
    var testButton: NSButton!
    var restoreButton: NSButton!
    let preview: Bool

    init(defaults: UserDefaults = .standard, preview: Bool = false) {
        self.defaults = defaults
        self.preview = preview
        super.init()
        replaceOriginal = defaults.object(forKey: "replaceOriginalV3") as? Bool ?? true
        load()
        eventRouter.handle = { [weak self] record, event in self?.routeOriginal(record, event: event) ?? false }
        updateMonitoredCodes()
    }
    func load() {
        if let data = defaults.data(forKey: "assignmentsV2"), let decoded = try? JSONDecoder().decode([String: Assignment].self, from: data) {
            do {
                try validateConfiguration(ConfigurationFile(format: "CherryMac", version: 1, assignments: decoded, learnedSignals: [:]))
                assignments = decoded
            } catch {
                assignments = [:]
                startupWarning = "已有配置无法读取，已停止全部动作。可重新设置或导入备份。"
            }
        } else if defaults.data(forKey: "assignmentsV2") != nil {
            assignments = [:]
            startupWarning = "已有配置已损坏，已停止全部动作。可重新设置或导入备份。"
        } else {
            assignments = [
                "print": Assignment(signal: defaults.string(forKey: "screenshot") ?? "7:70", action: "screenshot", browserOnly: false),
                "calculator": Assignment(signal: defaults.string(forKey: "calculator") ?? "12:402", action: "calculator", browserOnly: false),
                "f5": Assignment(signal: "7:62", action: "refresh", browserOnly: true)
            ]
        }
        let configurableIDs = Set(keys.filter { $0.configurable }.map { $0.id }).union(["calculator", "browser", "mediaPlay", "cherry"])
        signals = (defaults.dictionary(forKey: "learnedSignalsV2") as? [String: String] ?? [:]).filter { configurableIDs.contains($0.key) && validSignal($0.value) }
        for (id, assignment) in assignments { signals[id] = assignment.signal }
    }
    func persist() {
        for (id, assignment) in assignments { signals[id] = assignment.signal }
        if let data = try? JSONEncoder().encode(assignments) { defaults.set(data, forKey: "assignmentsV2") }
        defaults.set(signals, forKey: "learnedSignalsV2")
        updateMonitoredCodes()
        updateKeys()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        CalculatorService.configureApplicationMenu()
        paused = true
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "⌨︎"
        let menu = NSMenu()
        for (title, action) in [("USB 键盘配置", #selector(showHardware)), ("Mac 端适配设置", #selector(showSettings)), ("暂停适配", #selector(togglePaused)), ("重新连接键盘", #selector(connect)), ("导出配置…", #selector(exportConfiguration)), ("导入配置…", #selector(importConfiguration)), ("退出 CherryMac", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
            if action == #selector(togglePaused) { pauseItem = item }
        }
        status.menu = menu
        setupWindow()
        connect()
        refreshPermissionStatus()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissionStatus() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        if let startupWarning { message.stringValue = startupWarning }
        showHardware()
    }
    @objc func showHardware() {
        if hardwareWindow == nil { hardwareWindow = HardwareWindowController() }
        hardwareWindow?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func label(_ text: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, in parent: NSView) {
        view.frame = NSRect(x: x, y: y, width: w, height: h)
        parent.addSubview(view)
    }
    func setupWindow() {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let size = NSSize(width: min(1220, screen.width - 32), height: min(795, screen.height - 60))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CherryMac · 键盘布局与设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 1220, height: 820))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = root
        window.contentView = scroll
        place(label("你的键盘，你的习惯。", 27, .semibold), 28, 27, 780, 40, in: root)
        place(label("CHERRY MX 3.0S Pokémon  ·  点击一个按键，在右侧设置功能。", 13), 28, 76, 880, 24, in: root)
        pauseToggle.target = self; pauseToggle.action = #selector(togglePaused)
        place(pauseToggle, 1082, 35, 110, 24, in: root)
        place(label("键盘布局示意", 15, .semibold), 28, 124, 500, 24, in: root)
        let legend = label("● 已设置功能     蓝色 = 当前选中", 11)
        legend.textColor = .secondaryLabelColor
        place(legend, 575, 128, 310, 20, in: root)
        let board = FlippedView(frame: NSRect(x: 28, y: 162, width: 866, height: 260))
        board.wantsLayer = true
        board.layer?.cornerRadius = 14
        board.layer?.borderWidth = 1
        board.layer?.borderColor = NSColor.separatorColor.cgColor
        board.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        root.addSubview(board)
        for spec in keys {
            let key = KeyButton(spec)
            key.target = self; key.action = #selector(selectKey(_:))
            buttons[spec.id] = key
            board.addSubview(key)
        }
        place(label("其他特殊功能 / Fn 组合", 13, .semibold), 28, 446, 300, 24, in: root)
        for (i, extra) in [("browser", "浏览器", 406), ("cherry", "CHERRY", -1)].enumerated() {
            let spec = KeySpec(id: extra.0, label: extra.1, usage: extra.2 >= 0 ? "12:\(extra.2)" : "learn", rect: NSRect(x: 28 + CGFloat(i) * 136, y: 479, width: 125, height: 36))
            let key = KeyButton(spec)
            key.target = self; key.action = #selector(selectKey(_:))
            buttons[spec.id] = key; root.addSubview(key)
        }
        let layoutNote = label("右上角四键已按你的实物说明排列；下方其他功能区是设置入口。\nFn、修饰键和键盘内部灯光设置暂不支持重新分配。", 11)
        layoutNote.textColor = .secondaryLabelColor
        place(layoutNote, 28, 530, 866, 40, in: root)
        mappingSummary.font = .systemFont(ofSize: 12, weight: .medium)
        place(mappingSummary, 28, 595, 866, 48, in: root)

        let panel = FlippedView(frame: NSRect(x: 920, y: 124, width: 274, height: 644))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        root.addSubview(panel)
        place(selectionTitle, 20, 22, 234, 32, in: panel)
        selectionTitle.font = .systemFont(ofSize: 23, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        place(detail, 20, 65, 234, 62, in: panel)
        place(label("按下后执行", 12, .medium), 20, 136, 234, 22, in: panel)
        actionPicker.addItems(withTitles: actions.map { $0.1 })
        actionPicker.target = self; actionPicker.action = #selector(actionChanged)
        place(actionPicker, 18, 162, 238, 30, in: panel)
        place(customControls, 20, 195, 234, 53, in: panel)
        for (i, checkbox) in [command, shift, option, control].enumerated() { place(checkbox, CGFloat(i) * 53, 0, 52, 22, in: customControls) }
        shortcutPicker.addItems(withTitles: shortcutKeys.map { $0.1 })
        place(shortcutPicker, -2, 25, 238, 25, in: customControls)
        place(scope, 20, 257, 234, 25, in: panel)
        saveButton = button("保存设置", #selector(saveSelection))
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        place(saveButton, 18, 294, 116, 32, in: panel)
        restoreButton = button("恢复原功能", #selector(restoreSelection))
        place(restoreButton, 136, 294, 120, 32, in: panel)
        learnButton = button("识别这个实体按键…", #selector(learnSelection))
        place(learnButton, 18, 337, 238, 32, in: panel)
        testButton = button("测试所选功能", #selector(testSelection))
        place(testButton, 18, 375, 238, 32, in: panel)
        behaviorNote.font = .systemFont(ofSize: 11)
        behaviorNote.textColor = .secondaryLabelColor
        place(behaviorNote, 20, 416, 234, 68, in: panel)
        place(button("输入监控权限", #selector(inputPermission)), 18, 500, 118, 30, in: panel)
        place(button("辅助功能权限", #selector(accessibilityPermission)), 138, 500, 118, 30, in: panel)
        message.font = .systemFont(ofSize: 11)
        place(message, 20, 546, 234, 80, in: panel)
        place(button("导出配置…", #selector(exportConfiguration)), 28, 722, 126, 30, in: root)
        place(button("导入配置…", #selector(importConfiguration)), 164, 722, 126, 30, in: root)
        permissionStatus.font = .systemFont(ofSize: 11)
        place(permissionStatus, 312, 728, 580, 24, in: root)
        inputMode.addItems(withTitles: ["替换原按键 · 避免重复输入", "追加动作 · 旧版兼容方式"])
        inputMode.target = self; inputMode.action = #selector(changeInputMode)
        inputMode.selectItem(at: replaceOriginal ? 0 : 1)
        place(inputMode, 26, 768, 285, 28, in: root)
        updateBehaviorNote()
        updateKeys()
        updateInspector()
    }
    @objc func selectKey(_ sender: KeyButton) {
        cancelLearning()
        selected = sender.spec.id
        updateKeys(); updateInspector()
        message.stringValue = sender.spec.configurable ? "选择功能后点击保存。" : "此键暂不支持设置，原功能保持不变。"
    }
    func currentSpec() -> KeySpec? { buttons[selected]?.spec }
    func currentSignal() -> String? {
        if let learned = signals[selected] { return learned }
        guard let signal = currentSpec()?.usage, signal != "learn" else { return nil }
        return signal
    }
    func updateKeys() {
        for (id, key) in buttons {
            key.chosen = id == selected
            key.mapped = assignments[id] != nil
            let action = assignments[id].map(actionName) ?? "原功能"
            key.toolTip = "\(key.spec.label)：\(action)"
            key.setAccessibilityHelp(key.toolTip)
        }
        let descriptions = assignments.sorted { $0.key < $1.key }.map { id, a in
            let name = buttons[id]?.spec.label ?? id
            let action = actionName(a)
            return "\(name) → \(action)\(a.browserOnly ? "（浏览器）" : "")"
        }
        mappingSummary.stringValue = descriptions.isEmpty ? "所有按键保留原功能。" : "已设置 \(assignments.count) 个按键\n" + descriptions.prefix(4).joined(separator: "    ·    ") + (descriptions.count > 4 ? "    …" : "")
        mappingSummary.toolTip = descriptions.joined(separator: "\n")
    }
    func updateInspector() {
        guard let spec = currentSpec() else { return }
        selectionTitle.stringValue = spec.label
        let assignment = assignments[selected]
        let configured = assignment.map(actionName) ?? "保留原功能"
        detail.stringValue = spec.configurable ? "当前：\(configured)\n实体键无反应时，点击下方识别按钮。" : "修饰键、Fn 和 Caps Lock 暂不支持设置。"
        actionPicker.selectItem(at: actions.firstIndex { $0.0 == (assignment?.action ?? "none") } ?? 0)
        scope.state = (assignment?.browserOnly ?? false) ? .on : .off
        actionPicker.isEnabled = spec.configurable
        scope.isEnabled = spec.configurable
        saveButton.isEnabled = spec.configurable
        restoreButton.isEnabled = spec.configurable
        learnButton.isEnabled = spec.configurable
        testButton.isEnabled = spec.configurable
        let shortcut = assignment?.customShortcut ?? Shortcut(keyCode: 15, modifiers: CGEventFlags.maskCommand.rawValue, keyLabel: "R")
        shortcutPicker.selectItem(at: shortcutKeys.firstIndex { $0.0 == shortcut.keyCode } ?? 0)
        for (button, flag) in [(command, CGEventFlags.maskCommand), (shift, .maskShift), (option, .maskAlternate), (control, .maskControl)] {
            button.state = shortcut.flags.contains(flag) ? .on : .off
        }
        customControls.isHidden = assignment?.action != "custom"
    }
    @objc func actionChanged() {
        let action = actions[actionPicker.indexOfSelectedItem].0
        scope.state = ["refresh", "newTab", "closeTab"].contains(action) ? .on : .off
        customControls.isHidden = action != "custom"
    }
    @objc func saveSelection() {
        guard currentSpec()?.configurable == true else { return }
        cancelLearning()
        let action = actions[actionPicker.indexOfSelectedItem].0
        if action == "none" { restoreSelection(); return }
        guard let signal = currentSignal() else {
            message.stringValue = "请先点击识别按钮，按一次实体键，再保存。"; return
        }
        if let conflict = assignments.first(where: { $0.key != selected && $0.value.signal == signal }) {
            message.stringValue = "此信号已用于 \(buttons[conflict.key]?.spec.label ?? conflict.key)。请先恢复该键，或重新识别。"; return
        }
        let shortcut = selectedShortcut()
        guard action != "custom" || shortcut.valid else {
            message.stringValue = "自定义快捷键请至少选择一个修饰键（⌘、⇧、⌥、⌃）。"; return
        }
        assignments[selected] = Assignment(signal: signal, action: action, browserOnly: scope.state == .on, customShortcut: action == "custom" ? shortcut : nil)
        persist(); updateInspector()
        message.stringValue = "已保存，立即生效。\(scope.state == .on ? "仅在支持的浏览器前台时执行。" : "")"
    }
    @objc func restoreSelection() {
        guard currentSpec()?.configurable == true else { return }
        cancelLearning()
        assignments.removeValue(forKey: selected)
        persist(); updateInspector()
        message.stringValue = "已恢复原功能。"
    }
    func cancelLearning() { learning = nil; timeout?.invalidate() }
    @objc func learnSelection() {
        guard currentSpec()?.configurable == true else { return }
        cancelLearning()
        learning = selected
        message.stringValue = "请在 15 秒内只按一下 \(currentSpec()?.label ?? "目标") 实体键。需要 Fn 时按原组合。"
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.learning = nil
            self?.message.stringValue = "没有收到信号。检查权限与连接；键盘内部功能可能不会向 Mac 发送信号。"
        }
    }
    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHardware()
        return true
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let hardwareWindow,hardwareWindow.busy {
            hardwareWindow.showWindow(nil)
            hardwareWindow.message.stringValue="键盘配置操作正在进行，请等待完成后再退出。"
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        cancelLearning(); permissionTimer?.invalidate()
        eventRouter.stop()
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerCancel(manager)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    @objc func wake() { connect() }
    @objc func togglePaused() {
        paused.toggle()
        cancelLearning()
        eventRouter.reset()
        pauseToggle.state = paused ? .on : .off
        pauseItem?.state = paused ? .on : .off
        status?.button?.title = paused ? "⌨︎Ⅱ" : "⌨︎"
        message.stringValue = paused ? "适配已暂停。所有原按键继续正常输入。" : "已恢复适配。"
        refreshPermissionStatus()
    }
    func refreshPermissionStatus() {
        let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        let access = AXIsProcessTrusted()
        if replaceOriginal && access && input && !preview { _ = eventRouter.start() }
        else if !access || !input { eventRouter.stop() }
        permissionStatus.stringValue = "输入监控：\(input ? "已开启" : "待授权")    辅助功能：\(access ? "已开启" : "待授权")\(paused ? "    · 已暂停" : "")\(replaceOriginal ? "    · \(eventRouter.running ? "替换已就绪" : "替换待授权")" : "    · 追加动作")"
        if let runtimeStatusURL {
            let devices = manager.flatMap { IOHIDManagerCopyDevices($0) as? Set<IOHIDDevice> } ?? []
            let snapshot: [String: Any] = [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "inputMonitoringGranted": input, "accessibilityGranted": access,
                "replacementTapRunning": eventRouter.running, "replaceOriginal": replaceOriginal,
                "deviceOpenResult": deviceOpenResult.map { Int($0) } ?? -1,
                "devices": devices.map { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "CHERRY" }.sorted()
            ]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted]), data != lastStatusData {
                try? data.write(to: runtimeStatusURL, options: .atomic)
                lastStatusData = data
            }
        }
    }
    @objc func changeInputMode() {
        replaceOriginal = inputMode.indexOfSelectedItem == 0
        defaults.set(replaceOriginal, forKey: "replaceOriginalV3")
        cancelLearning()
        if replaceOriginal {
            if !preview && AXIsProcessTrusted() { _ = eventRouter.start() }
        } else { eventRouter.stop() }
        updateBehaviorNote(); refreshPermissionStatus()
        message.stringValue = replaceOriginal ? "已切换到替换模式。仅确认来自 CHERRY 的信号才会被替换，其他输入保持原样。" : "已切换到追加动作。原按键也会传递，建议用于特殊功能键兼容。"
    }
    func updateBehaviorNote() {
        behaviorNote.stringValue = replaceOriginal ? "替换模式：已设置的普通按键执行新功能，不再输入原字符。其他键盘、范围外和修饰组合保持原功能；特殊功能键使用兼容触发。" : "追加模式：原按键仍会传递。字母键可能同时输入字符，建议优先设置 F 区和特殊键。"
    }
    func updateMonitoredCodes() {
        eventRouter.monitoredCodes = Set(assignments.values.compactMap { assignment -> UInt16? in
            let parts = assignment.signal.split(separator: ":")
            guard parts.count == 2, parts[0] == "7", let usage = UInt32(parts[1]) else { return nil }
            return hidToMacKey[usage]
        })
    }
    func frontmost() -> (String?, Int32) {
        frontmostProvider?() ?? (NSWorkspace.shared.frontmostApplication?.bundleIdentifier, NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
    }
    func routeOriginal(_ record: RawKeyRecord, event: CGEvent) -> Bool {
        guard preview || AXIsProcessTrusted() else { return false }
        guard replaceOriginal, !paused, learning == nil, event.flags.rawValue & shortcutModifierMask == 0,
              let entry = assignments.first(where: { $0.value.signal == record.signal }) else { return false }
        let app = frontmost()
        guard app.1 != ProcessInfo.processInfo.processIdentifier,
              !entry.value.browserOnly || browserIDs.contains(app.0 ?? "") else { return false }
        // The router already consumed the original down/up pair. Dispatching
        // asynchronously avoids recursive event posting inside a tap callback.
        lastAction = entry.value.action
        let assignment = entry.value
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, !self.paused, self.frontmost().1 == app.1 else { return }
            self.perform(assignment.action, custom: assignment.customShortcut)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return true
    }
    func selectedShortcut() -> Shortcut {
        let key = shortcutKeys[max(0, shortcutPicker.indexOfSelectedItem)]
        var flags = CGEventFlags()
        for (button, flag) in [(command, CGEventFlags.maskCommand), (shift, .maskShift), (option, .maskAlternate), (control, .maskControl)] {
            if button.state == .on { flags.insert(flag) }
        }
        return Shortcut(keyCode: key.0, modifiers: flags.rawValue, keyLabel: key.1)
    }
    func actionName(_ assignment: Assignment) -> String {
        if assignment.action == "custom", let custom = assignment.customShortcut { return custom.displayName }
        return actions.first { $0.0 == assignment.action }?.1 ?? assignment.action
    }
    func configurationData() throws -> Data {
        let file = ConfigurationFile(format: "CherryMac", version: 1, assignments: assignments, learnedSignals: signals)
        try validateConfiguration(file)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }
    func applyConfiguration(_ data: Data) throws {
        guard data.count <= 1_048_576 else { throw ConfigurationError.invalid("配置文件过大。") }
        let file = try JSONDecoder().decode(ConfigurationFile.self, from: data)
        try validateConfiguration(file)
        cancelLearning()
        assignments = file.assignments
        signals = file.learnedSignals
        for (id, assignment) in assignments { signals[id] = assignment.signal }
        persist(); updateInspector()
    }
    @objc func exportConfiguration() {
        cancelLearning()
        let panel = NSSavePanel()
        panel.title = "备份键盘设置"
        panel.nameFieldStringValue = "CherryMac-配置.json"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do { try self.configurationData().write(to: url, options: .atomic); self.message.stringValue = "配置已导出。" }
            catch { self.message.stringValue = "导出失败：\(error.localizedDescription)" }
        }
    }
    @objc func importConfiguration() {
        cancelLearning()
        let panel = NSOpenPanel()
        panel.title = "导入键盘设置（替换当前配置）"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            do {
                let data = try Data(contentsOf: url)
                try self.applyConfiguration(data)
                self.message.stringValue = "已导入 \(self.assignments.count) 个按键设置。"
            } catch { self.message.stringValue = "未更改现有配置：\(error.localizedDescription)" }
        }
    }
    @objc func connect() {
        held.removeAll(); modifiers.removeAll()
        eventRouter.reset()
        if let manager {
            retiredManagers[managerToken] = manager
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerCancel(manager)
        }
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = newManager
        let token = UUID()
        managerToken = token
        IOHIDManagerSetDeviceMatchingMultiple(newManager, targetDeviceMatches as CFArray)
        IOHIDManagerRegisterInputValueCallback(newManager, { context, _, _, value in
            guard let context else { return }
            let adapter = Unmanaged<Adapter>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let integer = IOHIDValueGetIntegerValue(value)
            adapter.inputLedger.record(page: page, usage: usage, value: integer, absoluteTimestamp: IOHIDValueGetTimeStamp(value))
            DispatchQueue.main.async { adapter.receive(page: page, usage: usage, value: integer) }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, _ in
            guard let context else { return }
            let adapter = Unmanaged<Adapter>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { adapter.held.removeAll(); adapter.modifiers.removeAll(); adapter.eventRouter.reset() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerSetDispatchQueue(newManager, hidQueue)
        IOHIDManagerSetCancelHandler(newManager) { [weak self] in
            DispatchQueue.main.async { self?.retiredManagers.removeValue(forKey: token) }
        }
        let result = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        deviceOpenResult = result
        IOHIDManagerActivate(newManager)
        let count = (IOHIDManagerCopyDevices(newManager) as? Set<IOHIDDevice>)?.count ?? 0
        let permitted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        message.stringValue = result == kIOReturnSuccess && permitted ? "正在运行 · \(count) 个 CHERRY 设备。关闭窗口后仍在菜单栏运行。" : "请开启输入监控，然后退出并重新打开软件。"
        refreshPermissionStatus()
    }
    func receive(page: UInt32, usage: UInt32, value: Int) {
        guard page == 7 || page == 12 || page >= 0xFF00 else { return }
        let signal = "\(page):\(usage)"
        if page == 7 && (0xE0...0xE7).contains(usage) {
            if value == 0 { modifiers.remove(signal) } else { modifiers.insert(signal) }
            return
        }
        if value == 0 { held.remove(signal); return }
        guard value == 1, usage > 3, !held.contains(signal) else { return }
        held.insert(signal)
        lastInput = signal
        if let id = learning {
            if let conflict = assignments.first(where: { $0.key != id && $0.value.signal == signal }) {
                message.stringValue = "这个信号已用于 \(buttons[conflict.key]?.spec.label ?? conflict.key)，请换一个实体键。"; return
            }
            signals[id] = signal
            if var assignment = assignments[id] { assignment.signal = signal; assignments[id] = assignment }
            cancelLearning(); persist(); updateInspector()
            message.stringValue = "已识别 \(buttons[id]?.spec.label ?? id)。选择功能并保存，或按一次验证已有设置。"
            return
        }
        guard !paused, modifiers.isEmpty else { return }
        if replaceOriginal && page == 7 { return }
        if !preview && CGEventSource.flagsState(.combinedSessionState).rawValue & shortcutModifierMask != 0 { return }
        guard let entry = assignments.first(where: { $0.value.signal == signal }) else { return }
        let frontmost = self.frontmost()
        if entry.value.browserOnly && !browserIDs.contains(frontmost.0 ?? "") { return }
        // Do not send configured actions back into the settings app while editing.
        guard frontmost.1 != ProcessInfo.processInfo.processIdentifier else { return }
        lastAction = entry.value.action
        perform(entry.value.action, custom: entry.value.customShortcut)
    }
    @objc func inputPermission() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func accessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func testSelection() {
        let action = actions[actionPicker.indexOfSelectedItem].0
        if ["calculator", "screenshot", "screenshotToolbar", "spotlight"].contains(action) {
            window.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.perform(action) }
        } else {
            message.stringValue = action == "none" ? "当前保留原功能，无需测试。" : "请保存后切换到目标软件，再按实体键测试，避免在设置窗口执行此操作。"
        }
    }
    func perform(_ action: String, custom: Shortcut? = nil) {
        if let actionSink { actionSink(action, custom); return }
        guard !preview, action != "none" else { return }
        if action == "calculator" {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") else { message.stringValue = "未找到系统计算器。"; return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { self.message.stringValue = error.localizedDescription } }
            }
            return
        }
        guard AXIsProcessTrusted() else {
            message.stringValue = "执行快捷键需要辅助功能权限，请先开启。"
            showSettings(); return
        }
        let shortcuts: [String: (CGKeyCode, CGEventFlags)] = [
            "screenshot": (21, [.maskCommand, .maskShift]), "screenshotToolbar": (23, [.maskCommand, .maskShift]),
            "refresh": (15, .maskCommand), "find": (3, .maskCommand), "newTab": (17, .maskCommand),
            "closeTab": (13, .maskCommand), "copy": (8, .maskCommand), "paste": (9, .maskCommand),
            "undo": (6, .maskCommand), "spotlight": (49, .maskCommand)
        ]
        let shortcut = action == "custom" && custom?.valid == true ? custom.map { ($0.keyCode, $0.flags) } : shortcuts[action]
        guard let (keyCode, flags) = shortcut else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: adapterEventTag)
            event?.post(tap: .cghidEventTap)
        }
    }
}

final class EventProbe {
    struct Record: Equatable {
        let down: Bool
        let code: UInt16
        let modifiers: UInt64
    }
    var records: [Record] = []
    var passedTestInputs = 0
}

func runSystemTests() -> Int32 {
    guard AXIsProcessTrusted() else {
        print("NOT RUN: accessibility permission is required for system-event verification")
        return 2
    }
    let probe = EventProbe()
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
        // Ignore real user input entirely. Only capture and consume this app's
        // tagged test events, so shortcuts never reach the user's applications.
        guard let context else { return Unmanaged.passUnretained(event) }
        let probe = Unmanaged<EventProbe>.fromOpaque(context).takeUnretainedValue()
        if event.getIntegerValueField(.eventSourceUserData) == KeyboardEventRouter.testInputTag {
            probe.passedTestInputs += 1
            return nil
        }
        guard event.getIntegerValueField(.eventSourceUserData) == adapterEventTag else { return Unmanaged.passUnretained(event) }
        probe.records.append(EventProbe.Record(down: type == .keyDown, code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: event.flags.rawValue & shortcutModifierMask))
        return nil
    }, userInfo: Unmanaged.passUnretained(probe).toOpaque()) else {
        print("NOT RUN: macOS did not allow the event verification tap")
        return 2
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    defer {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
    let suite = "local.cherrymac.systemtest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let adapter = Adapter(defaults: defaults)
    let cases: [(String, UInt16, CGEventFlags)] = [
        ("screenshot", 21, [.maskCommand, .maskShift]), ("screenshotToolbar", 23, [.maskCommand, .maskShift]),
        ("refresh", 15, .maskCommand), ("find", 3, .maskCommand), ("newTab", 17, .maskCommand),
        ("closeTab", 13, .maskCommand), ("copy", 8, .maskCommand), ("paste", 9, .maskCommand),
        ("undo", 6, .maskCommand), ("spotlight", 49, .maskCommand)
    ]
    var expected: [EventProbe.Record] = []
    for (action, code, flags) in cases {
        expected.append(EventProbe.Record(down: true, code: code, modifiers: flags.rawValue))
        expected.append(EventProbe.Record(down: false, code: code, modifiers: flags.rawValue))
        adapter.perform(action)
    }
    let custom = Shortcut(keyCode: 1, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue, keyLabel: "S")
    adapter.perform("custom", custom: custom)
    expected.append(EventProbe.Record(down: true, code: custom.keyCode, modifiers: custom.modifiers))
    expected.append(EventProbe.Record(down: false, code: custom.keyCode, modifiers: custom.modifiers))
    let deadline = Date().addingTimeInterval(2)
    while probe.records.count < expected.count && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard probe.records == expected else {
        print("FAIL: expected \(expected.count) tagged system events, observed \(probe.records.count)")
        return 1
    }
    print("PASS: macOS received all 22 key-down/key-up events with correct shortcut keys and modifiers; test events were consumed before reaching user applications")

    // Exercise the production interception tap, not just a direct callback.
    // The downstream probe consumes any test input the router passes through,
    // keeping both successful and intentionally unmatched cases isolated.
    adapter.eventRouter.allowTestInput = true
    adapter.frontmostProvider = { ("com.apple.Safari", 999_999) }
    guard adapter.eventRouter.start() else {
        print("FAIL: production interception tap could not start")
        return 1
    }
    defer { adapter.eventRouter.stop() }
    func sendInput(_ code: UInt16, _ signal: String, correlated: Bool = true) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = []
            event.timestamp = adapter.inputLedger.nanoseconds(mach_absolute_time())
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardEventRouter.testInputTag)
            adapter.inputLedger.insert(signal: signal, timestamp: correlated ? event.timestamp : event.timestamp - 1, keyCode: code, down: down)
            event.post(tap: .cghidEventTap)
        }
    }
    func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
    sendInput(96, "7:62")
    drain()
    expected.append(EventProbe.Record(down: true, code: 15, modifiers: CGEventFlags.maskCommand.rawValue))
    expected.append(EventProbe.Record(down: false, code: 15, modifiers: CGEventFlags.maskCommand.rawValue))
    guard probe.records == expected, probe.passedTestInputs == 0 else {
        print("FAIL: production F5 interception/output mismatch (events=\(probe.records.count), original-passed=\(probe.passedTestInputs))")
        return 1
    }
    adapter.assignments["key4"] = Assignment(signal: "7:4", action: "copy", browserOnly: false)
    adapter.updateMonitoredCodes()
    sendInput(0, "7:4")
    drain()
    expected.append(EventProbe.Record(down: true, code: 8, modifiers: CGEventFlags.maskCommand.rawValue))
    expected.append(EventProbe.Record(down: false, code: 8, modifiers: CGEventFlags.maskCommand.rawValue))
    guard probe.records == expected, probe.passedTestInputs == 0 else {
        print("FAIL: production letter-key replacement leaked original input")
        return 1
    }
    adapter.frontmostProvider = { ("com.apple.TextEdit", 999_999) }
    sendInput(96, "7:62")
    drain()
    guard probe.records == expected, probe.passedTestInputs == 2 else {
        print("FAIL: F5 should pass through unchanged outside browser scope")
        return 1
    }
    adapter.frontmostProvider = { ("com.apple.Safari", 999_999) }
    sendInput(96, "7:62", correlated: false)
    drain()
    guard probe.records == expected, probe.passedTestInputs == 4 else {
        print("FAIL: unmatched-device input should pass through unchanged")
        return 1
    }
    print("PASS: production macOS tap replaces F5 with Command-R and a letter key with Command-C without leaking original test input; out-of-scope and unmatched-device events remain unchanged")
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") != nil else {
        print("FAIL: system Calculator application was not found")
        return 1
    }
    print("PASS: system Calculator application resolves through the actual application launcher")
    return 0
}

func runSelfTests() {
    let suite = "local.cherrymac.selftest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let adapter = Adapter(defaults: defaults, preview: true)
    adapter.setupWindow()
    precondition(adapter.keys.count == 109)
    for (topID, bottomID) in [("calculator", "numLock"), ("mediaPrevious", "numDivide"), ("mediaPlay", "numMultiply"), ("mediaNext", "numMinus")] {
        let top = adapter.keys.first { $0.id == topID }!
        let bottom = adapter.keys.first { $0.id == bottomID }!
        precondition(top.rect.minX == bottom.rect.minX && top.rect.maxY < bottom.rect.minY)
        precondition(adapter.buttons[topID]?.superview === adapter.buttons[bottomID]?.superview, "dedicated keys must be on the physical board")
    }
    precondition(Set(adapter.keys.map { $0.id }).count == adapter.keys.count)
    for a in adapter.keys {
        precondition(a.rect.minX >= 0 && a.rect.maxX <= 866 && a.rect.maxY <= 260)
        if a.rect.width == 32 { precondition(a.rect.height == 32 || a.rect.height == 68, "single keys must be square except physical double-row keys") }
        for b in adapter.keys where a.id != b.id { precondition(!a.rect.intersects(b.rect), "overlapping \(a.id) / \(b.id)") }
    }
    precondition(adapter.assignments["f5"] == Assignment(signal: "7:62", action: "refresh", browserOnly: true))
    adapter.selectKey(adapter.buttons["f6"]!)
    adapter.actionPicker.selectItem(at: actions.firstIndex { $0.0 == "calculator" }!)
    adapter.scope.state = .off
    adapter.saveSelection()
    precondition(adapter.assignments["f6"]?.action == "calculator")
    let reloaded = Adapter(defaults: defaults, preview: true)
    precondition(reloaded.assignments == adapter.assignments)
    adapter.learning = "f6"
    adapter.receive(page: 7, usage: 0xE1, value: 1)
    precondition(adapter.learning == "f6")
    adapter.receive(page: 7, usage: 62, value: 1)
    precondition(adapter.learning == "f6", "conflicting binding should be rejected")
    adapter.receive(page: 7, usage: 62, value: 0)
    adapter.receive(page: 12, usage: 500, value: 1)
    precondition(adapter.learning == nil)
    precondition(adapter.assignments["f6"]?.signal == "12:500")
    adapter.restoreSelection()
    precondition(adapter.assignments["f6"] == nil)
    adapter.actionPicker.selectItem(at: actions.firstIndex { $0.0 == "refresh" }!)
    adapter.actionChanged()
    precondition(adapter.scope.state == .on)
    precondition(adapter.held.contains("12:500"))
    adapter.receive(page: 12, usage: 500, value: 0)
    precondition(!adapter.held.contains("12:500"))
    defaults.removePersistentDomain(forName: suite)
    defaults.set("12:499", forKey: "screenshot")
    precondition(Adapter(defaults: defaults, preview: true).assignments["print"]?.signal == "12:499")

    // Route complete input sequences through the actual runtime handler, using
    // an action sink to avoid operating on the user's browser or clipboard.
    defaults.removePersistentDomain(forName: suite)
    let runtime = Adapter(defaults: defaults, preview: true)
    runtime.replaceOriginal = false
    runtime.setupWindow()
    var dispatched: [(String, Shortcut?)] = []
    runtime.actionSink = { dispatched.append(($0, $1)) }
    runtime.frontmostProvider = { ("com.apple.Safari", 999_999) }
    runtime.receive(page: 7, usage: 62, value: 1)
    precondition(dispatched.map { $0.0 } == ["refresh"])
    runtime.receive(page: 7, usage: 62, value: 1)
    precondition(dispatched.count == 1, "holding key must not repeat")
    runtime.receive(page: 7, usage: 62, value: 0)
    runtime.receive(page: 7, usage: 62, value: 1)
    precondition(dispatched.count == 2, "two deliberate presses should both work")
    runtime.receive(page: 7, usage: 62, value: 0)
    runtime.frontmostProvider = { ("com.apple.TextEdit", 999_999) }
    runtime.receive(page: 7, usage: 62, value: 1)
    runtime.receive(page: 7, usage: 62, value: 0)
    precondition(dispatched.count == 2, "browser-only action must not reach editor")
    runtime.frontmostProvider = { ("com.apple.Safari", 999_999) }
    runtime.receive(page: 7, usage: 0xE0, value: 1)
    runtime.receive(page: 7, usage: 62, value: 1)
    runtime.receive(page: 7, usage: 62, value: 0)
    precondition(dispatched.count == 2, "modified F5 must retain its original function")
    runtime.receive(page: 7, usage: 0xE0, value: 0)
    runtime.togglePaused()
    runtime.receive(page: 7, usage: 70, value: 1)
    runtime.receive(page: 7, usage: 70, value: 0)
    precondition(dispatched.count == 2, "paused adapter must not execute actions")
    runtime.togglePaused()
    runtime.receive(page: 7, usage: 70, value: 1)
    runtime.receive(page: 7, usage: 70, value: 0)
    runtime.receive(page: 12, usage: 402, value: 1)
    runtime.receive(page: 12, usage: 402, value: 0)
    precondition(dispatched.map { $0.0 } == ["refresh", "refresh", "screenshot", "calculator"])
    runtime.frontmostProvider = { ("local.cherrymac.adapter", ProcessInfo.processInfo.processIdentifier) }
    runtime.receive(page: 7, usage: 70, value: 1)
    runtime.receive(page: 7, usage: 70, value: 0)
    precondition(dispatched.count == 4, "settings must not execute configured actions")

    runtime.selectKey(runtime.buttons["f6"]!)
    runtime.actionPicker.selectItem(at: actions.firstIndex { $0.0 == "custom" }!)
    runtime.actionChanged()
    runtime.shortcutPicker.selectItem(at: shortcutKeys.firstIndex { $0.1 == "S" }!)
    runtime.command.state = .on; runtime.shift.state = .on
    runtime.scope.state = .off
    runtime.saveSelection()
    precondition(runtime.assignments["f6"]?.customShortcut?.displayName == "⇧⌘S")
    runtime.frontmostProvider = { ("com.apple.TextEdit", 999_999) }
    runtime.receive(page: 7, usage: 63, value: 1)
    runtime.receive(page: 7, usage: 63, value: 0)
    precondition(dispatched.last?.1?.displayName == "⇧⌘S")
    let originalAssignments = runtime.assignments
    for checkbox in [runtime.command, runtime.shift, runtime.option, runtime.control] { checkbox.state = .off }
    runtime.saveSelection()
    precondition(runtime.assignments == originalAssignments, "invalid shortcut must not overwrite a working mapping")

    let exported = try! runtime.configurationData()
    let imported = Adapter(defaults: defaults, preview: true)
    imported.setupWindow()
    try! imported.applyConfiguration(exported)
    precondition(imported.assignments == runtime.assignments && imported.signals == runtime.signals)
    let beforeInvalid = imported.assignments
    let invalid = ConfigurationFile(format: "CherryMac", version: 1, assignments: ["f6": Assignment(signal: "7:225", action: "custom", browserOnly: false)], learnedSignals: [:])
    do { try imported.applyConfiguration(try JSONEncoder().encode(invalid)); preconditionFailure("invalid import accepted") }
    catch { precondition(imported.assignments == beforeInvalid) }
    do { try imported.applyConfiguration(Data("not JSON".utf8)); preconditionFailure("invalid JSON accepted") }
    catch { precondition(imported.assignments == beforeInvalid) }
    let duplicate = ConfigurationFile(format: "CherryMac", version: 1, assignments: ["f5": Assignment(signal: "7:62", action: "refresh", browserOnly: true), "f6": Assignment(signal: "7:62", action: "calculator", browserOnly: false)], learnedSignals: [:])
    do { try validateConfiguration(duplicate); preconditionFailure("duplicate import accepted") } catch {}
    defaults.set(Data("broken".utf8), forKey: "assignmentsV2")
    let corrupted = Adapter(defaults: defaults, preview: true)
    precondition(corrupted.assignments.isEmpty && corrupted.startupWarning != nil)
    defaults.removePersistentDomain(forName: suite)

    let replacement = Adapter(defaults: defaults, preview: true)
    replacement.setupWindow()
    replacement.frontmostProvider = { ("com.apple.Safari", 999_999) }
    var replacementActions: [String] = []
    replacement.actionSink = { action, _ in replacementActions.append(action) }
    func originalEvent(_ timestamp: UInt64, _ code: UInt16 = 96, down: Bool = true, flags: CGEventFlags = [], tag: Int64 = 0) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.timestamp = timestamp
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        return event
    }
    func correlate(_ timestamp: UInt64, down: Bool = true) {
        replacement.inputLedger.insert(signal: "7:62", timestamp: timestamp, keyCode: 96, down: down)
    }
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: originalEvent(100), wait: 0), "unrelated keyboard must pass through")
    correlate(101)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: originalEvent(102), wait: 0), "nearby timestamp must never be guessed")
    correlate(103)
    precondition(replacement.eventRouter.consume(type: .keyDown, event: originalEvent(103), wait: 0))
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    precondition(replacementActions == ["refresh"])
    let repeatEvent = originalEvent(104)
    repeatEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    precondition(replacement.eventRouter.consume(type: .keyDown, event: repeatEvent, wait: 0), "original auto-repeat must be consumed")
    precondition(replacementActions == ["refresh"])
    correlate(105, down: false)
    precondition(replacement.eventRouter.consume(type: .keyUp, event: originalEvent(105, down: false), wait: 0))
    replacement.frontmostProvider = { ("com.apple.TextEdit", 999_999) }
    correlate(106)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: originalEvent(106), wait: 0))
    replacement.frontmostProvider = { ("com.apple.Safari", 999_999) }
    correlate(107)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: originalEvent(107, flags: .maskCommand), wait: 0))
    replacement.paused = true
    correlate(108)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: originalEvent(108), wait: 0))
    replacement.paused = false
    let synthetic = originalEvent(109, tag: adapterEventTag)
    correlate(109)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: synthetic, wait: 0), "output events must never recurse")
    correlate(110)
    precondition(replacement.eventRouter.consume(type: .keyDown, event: originalEvent(110), wait: 0))
    let otherKeyboardDown = originalEvent(111)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: otherKeyboardDown, wait: 0))
    let otherKeyboardRepeat = originalEvent(112)
    otherKeyboardRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: otherKeyboardRepeat, wait: 0), "other keyboard repeat ownership must be preserved")
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    precondition(replacementActions == ["refresh", "refresh"])
    correlate(113)
    precondition(replacement.eventRouter.consume(type: .keyDown, event: originalEvent(113), wait: 0))
    replacement.togglePaused()
    let pausedRepeat = originalEvent(114)
    pausedRepeat.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    precondition(!replacement.eventRouter.consume(type: .keyDown, event: pausedRepeat, wait: 0), "pause must clear repeat ownership")
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    precondition(replacementActions == ["refresh", "refresh"], "pause must cancel queued actions")
    let absoluteNow = mach_absolute_time()
    let eventNow = DispatchTime.now().uptimeNanoseconds
    let converted = replacement.inputLedger.nanoseconds(absoluteNow)
    precondition(eventNow > converted ? eventNow - converted < 100_000_000 : converted - eventNow < 100_000_000, "HID and CGEvent clocks must share boot-time nanoseconds")

    print("PASS: 109-key geometry including the four dedicated keys above Num, /, ×, −; selection, persistence, learning, conflict rejection, modifiers, restore, old-version migration")
    print("PASS: runtime screenshot/calculator/F5 routing, browser scope, settings exclusion, pause/resume, held-key deduplication, rapid deliberate presses")
    print("PASS: custom shortcut dispatch, invalid shortcut rejection, configuration round-trip, invalid/duplicate imports, corrupt-config safe handling")
    print("PASS: exact device/time correlation, original key interception, balanced release, auto-repeat, unrelated keyboard isolation, scope/modifier/pause bypass, synthetic loop prevention, live clock conversion")
}

let app = NSApplication.shared
#if CHERRY_MACRO_TEST
if CommandLine.arguments.contains("--macro-observer-self-test"){
    MacroObserverTestController().runOfflineTests()
    do{try MacroPhysicalStopController.runOfflineTests();try MacroHardwareTestController.runOfflineTests()}catch{fputs(error.localizedDescription+"\n",stderr);exit(1)};exit(0)
}
if let i=CommandLine.arguments.firstIndex(of:"--macro-stop-window-preview"),CommandLine.arguments.count>i+1{
    do{try MacroPhysicalStopController.preview(URL(fileURLWithPath:CommandLine.arguments[i+1]));exit(0)}catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
}
if let i=CommandLine.arguments.firstIndex(of:"--macro-hardware-window-preview"),CommandLine.arguments.count>i+1{
    do{try MacroHardwareTestController.preview(URL(fileURLWithPath:CommandLine.arguments[i+1]));exit(0)}catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
}
if let i=CommandLine.arguments.firstIndex(of:"--macro-recover-dir"),CommandLine.arguments.count>i+1{
    let tester=MacroHardwareTestController(resumeDirectory:URL(fileURLWithPath:CommandLine.arguments[i+1]));app.delegate=tester;app.run();exit(0)
}
if CommandLine.arguments.contains("--macro-hardware-test"){
    let directory:URL? = CommandLine.arguments.firstIndex(of:"--test-dir").flatMap{CommandLine.arguments.count>$0+1 ? URL(fileURLWithPath:CommandLine.arguments[$0+1]):nil}
    let tester=MacroHardwareTestController(directory:directory);app.delegate=tester;app.run();exit(0)
}
if CommandLine.arguments.contains("--macro-output-observer"){
    let tester=MacroObserverTestController();app.delegate=tester;app.run();exit(0)
}
#endif
#if CHERRY_PRODUCT_TEST
if CommandLine.arguments.contains("--product-flow-self-test"){
    ProductKeymapTestController().runOfflineTests();exit(0)
}
if CommandLine.arguments.contains("--product-key-test"){
    let tester=ProductKeymapTestController();app.delegate=tester;app.run();exit(0)
}
#endif
#if CHERRY_CALCULATOR_TEST
if CommandLine.arguments.contains("--calculator-key-test"){
    let tester=CalculatorHardwareTestController();app.delegate=tester;app.run();exit(0)
}
#endif
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
    runHardwareTests()
} else if CommandLine.arguments.contains("--system-test") {
    exit(runSystemTests())
} else if CommandLine.arguments.contains("--diagnostics") {
    let input = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let access = AXIsProcessTrusted()
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatchingMultiple(manager, targetDeviceMatches as CFArray)
    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    let names = devices.map { IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String ?? "CHERRY" }.sorted()
    let diagnostics: [String: Any] = ["inputMonitoringGranted": input == kIOHIDAccessTypeGranted, "accessibilityGranted": access, "deviceOpenResult": result, "devices": names, "calculatorAvailable": NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") != nil]
    if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
} else if let output=CommandLine.arguments.firstIndex(of:"--analyze-macro-execution"),CommandLine.arguments.count>output+1{
    do{
        guard let input=CommandLine.arguments.firstIndex(of:"--execution-log"),CommandLine.arguments.count>input+1 else{throw HardwareError(message:"需要 --execution-log 宏执行日志.json。")}
        let source=URL(fileURLWithPath:CommandLine.arguments[input+1]),destination=URL(fileURLWithPath:CommandLine.arguments[output+1])
        guard source.resolvingSymlinksInPath().standardizedFileURL != destination.resolvingSymlinksInPath().standardizedFileURL else{throw HardwareError(message:"评估结果不能覆盖原执行日志。")}
        let size=(try FileManager.default.attributesOfItem(atPath:source.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size<=8_000_000 else{throw HardwareError(message:"执行日志过大。")}
        let data=try Data(contentsOf:source);guard data.count<=8_000_000 else{throw HardwareError(message:"执行日志过大。")}
        let assessment=try JSONDecoder().decode(MacroExecutionLog.self,from:data).replay()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let report=MacroExecutionReport(inputSHA256:SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),assessment:assessment)
        try encoder.encode(report).write(to:destination,options:.atomic);print("观察日志评估：\(assessment.status)。仅重放已有事件，未连接或写入键盘。")
    }catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
} else if let output=CommandLine.arguments.firstIndex(of:"--convert-windows-profile"),CommandLine.arguments.count>output+1{
    do{
        guard let input=CommandLine.arguments.firstIndex(of:"--profile"),let baseline=CommandLine.arguments.firstIndex(of:"--baseline"),CommandLine.arguments.count>input+1,CommandLine.arguments.count>baseline+1 else{throw HardwareError(message:"需要 --profile Windows.json 和 --baseline CherryMac.json。")}
        let before=try HardwareProfile.decode(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[baseline+1]))).snapshot
        let imported=try WindowsProfile.decode(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[input+1])),baseline:before)
        try imported.profile.encoded().write(to:URL(fileURLWithPath:CommandLine.arguments[output+1]),options:.atomic);print(imported.summary)
    }catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
} else if let index = CommandLine.arguments.firstIndex(of: "--hardware-read"), CommandLine.arguments.count > index+1 {
    do { let snapshot=try CherryUSB().completeSnapshot();let profile=(try? HardwareProfile.fromHardware(snapshot)) ?? HardwareProfile(snapshot:snapshot);try profile.encoded().write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]),options:.atomic);print("PASS: USB keymap, lighting parameters, 126 RGB values and 3071-byte macro bank read") }catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}
} else if let index = CommandLine.arguments.firstIndex(of: "--hardware-preview"), CommandLine.arguments.count > index+1 {
    if CommandLine.arguments.contains("--dark"){app.appearance=NSAppearance(named:.darkAqua)}
    let controller=HardwareWindowController()
    if let input=CommandLine.arguments.firstIndex(of:"--profile"),CommandLine.arguments.count>input+1{
        controller.profile=try HardwareProfile.decode(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[input+1])));controller.baseline=controller.profile?.snapshot;controller.connection.stringValue="配置预览 · 126 个固件键位 · 未连接硬件";controller.loadLighting();controller.refreshMacroPicker();controller.loadSelectedAssignment();controller.update()
    }
    if let input=CommandLine.arguments.firstIndex(of:"--hardware-tab"),CommandLine.arguments.count>input+1,let tab=Int(CommandLine.arguments[input+1]),controller.tabButtons.indices.contains(tab){controller.chooseTab(controller.tabButtons[tab])}
    if let input=CommandLine.arguments.firstIndex(of:"--light-tab"),CommandLine.arguments.count>input+1,let tab=Int(CommandLine.arguments[input+1]),controller.lightTabButtons.indices.contains(tab){controller.chooseLightTab(controller.lightTabButtons[tab])}
    if CommandLine.arguments.contains("--lighting-demo"),controller.profile != nil{
        controller.lightRegion.selectItem(at:1);controller.selectLightRegion();controller.lightPattern.selectItem(at:3);controller.stageColor()
    }
    if CommandLine.arguments.contains("--key-demo"),controller.profile != nil{
        controller.actionPicker.selectItem(at:3);controller.stageKey();controller.loadSelectedAssignment()
    }
    controller.window?.displayIfNeeded()
    if let bitmap=controller.root.bitmapImageRepForCachingDisplay(in:controller.root.bounds){controller.root.cacheDisplay(in:controller.root.bounds,to:bitmap);if let data=bitmap.representation(using:.png,properties:[:]){try data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))}}
} else if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
    if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    let suite = "local.cherrymac.preview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let adapter = Adapter(defaults: defaults, preview: true)
    adapter.setupWindow()
    adapter.selected = "f5"
    if CommandLine.arguments.contains("--custom") {
        adapter.selected = "f6"
        adapter.assignments["f6"] = Assignment(signal: "7:63", action: "custom", browserOnly: false, customShortcut: Shortcut(keyCode: 1, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue, keyLabel: "S"))
    }
    adapter.updateKeys(); adapter.updateInspector()
    adapter.message.stringValue = CommandLine.arguments.contains("--custom") ? "已设置 F6 → ⇧⌘S。切换到目标软件后按实体键验证。" : "设置已保存 · 在浏览器中按 F5 即可刷新。"
    adapter.permissionStatus.stringValue = "输入监控：待授权    辅助功能：待授权"
    adapter.window.displayIfNeeded()
    let view = (adapter.window.contentView as! NSScrollView).documentView!
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }
    defaults.removePersistentDomain(forName: suite)
} else {
    let bundleID = Bundle.main.bundleIdentifier
    if let bundleID,
       let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        existing.activate(options: [.activateAllWindows])
        exit(0)
    }
    let delegate = Adapter()
    if let index = CommandLine.arguments.firstIndex(of: "--write-runtime-status"), CommandLine.arguments.count > index + 1 {
        delegate.runtimeStatusURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    app.delegate = delegate
    app.run()
}
