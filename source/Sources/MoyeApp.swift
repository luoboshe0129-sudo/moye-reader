import AppKit
import WebKit

@main
enum MoyeReaderLauncher {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MoyeWindowController!
    private var isTerminating = false
    private var terminationReplied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
#if MOYE_DIAGNOSTICS
        if Bundle.main.bundleIdentifier?.hasPrefix("com.moye.moyereader.review") == true, let defaults = UserDefaults(suiteName: "com.moye.moyereader") {
            for key in ["MoyeShelf.DarkAppearance", "MoyeShelf.ComicColumns", "MoyeShelf.SiteRoute", "MoyeShelf.SessionUser.18comic.vip", "MoyeShelf.SessionUser.18comic.ink", "MoyeShelf.SessionUser.jmcomic-zzz.one", "MoyeShelf.SessionUser.jmcomic-zzz.org", "MoyeShelf.DownloadDirectory"] {
                if let value = defaults.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
            }
        }
#endif
#if MOYE_DIAGNOSTICS
        if let path = Bundle.main.object(forInfoDictionaryKey: "MoyeVerificationDownloadDirectory") as? String { UserDefaults.standard.set(path, forKey: "MoyeShelf.DownloadDirectory") }
#endif
        // Discard caches from a previous interrupted run; account cookies are preserved.
        MoyeRuntimeData.clearCaches {}
        UserDefaults.standard.removeObject(forKey: "MoyeShelf.LastComicQuery")
        NSApp.setActivationPolicy(.regular)
        if let url = Bundle.main.url(forResource: "MoyeMascot", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        windowController = MoyeWindowController()
        buildMainMenu()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        windowController.prepareToQuit()
        MoyeReadingCache.shared.stop()
        MoyeRuntimeData.imageSession.invalidateAndCancel()
        MoyeRuntimeData.clearCaches { [weak self] in self?.replyToTermination() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.replyToTermination() }
        return .terminateLater
    }
    private func replyToTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出墨夜阅读器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let onlineItem = NSMenuItem(title: "回到首页", action: #selector(MoyeWindowController.showOnline(_:)), keyEquivalent: "l")
        onlineItem.target = windowController
        fileMenu.addItem(onlineItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let fullscreenItem = NSMenuItem(title: "切换全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullscreenItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        NSApp.mainMenu = mainMenu
    }
}

final class MoyeWindowController: NSWindowController {
    private var rootView: OnlineMainView?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "墨夜阅读器"
#if MOYE_DIAGNOSTICS
        if Bundle.main.bundleIdentifier?.hasPrefix("com.moye.moyereader.review") == true { window.title = "墨夜阅读器 · 功能检查" }
#endif
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = MoyeAppearance.appearance
        window.backgroundColor = color(0.93, 0.94, 0.98)
        window.minSize = NSSize(width: 1120, height: 760)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        super.init(window: window)
        window.isReleasedWhenClosed = false
        showOnline(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func showOnline(_ sender: Any?) {
        rootView?.prepareToClose()
        let view = OnlineMainView(frame: window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1360, height: 900), owner: self)
        rootView = view
        window?.contentView = view
        window?.makeFirstResponder(view)
    }
    func toggleAppearance(from source: OnlineMainView) {
        UserDefaults.standard.set(!MoyeAppearance.isDark, forKey: MoyeAppearance.preferenceKey)
        window?.appearance = MoyeAppearance.appearance
        window?.backgroundColor = color(0.93, 0.94, 0.98)
        let view = OnlineMainView(frame: window?.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1360, height: 900), owner: self, initialQuery: source.searchQuery)
        rootView = view
        window?.contentView = view
        window?.makeFirstResponder(view)
        view.reloadSearchAfterAppearanceChange(from: source)
        source.prepareToClose()
    }
    func prepareToQuit() { rootView?.prepareToClose(); rootView = nil; window?.contentView = nil }
    func showToast(_ text: String) {
        guard let content = window?.contentView else { return }
        let bubble = NSTextField(labelWithString: text)
        bubble.font = .systemFont(ofSize: 13, weight: .semibold)
        bubble.textColor = .labelColor
        bubble.alignment = .center
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = surfaceTint(0.95).cgColor
        bubble.layer?.cornerRadius = 15
        bubble.frame = NSRect(x: (content.bounds.width - 260) / 2, y: 24, width: 260, height: 34)
        content.addSubview(bubble)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { bubble.removeFromSuperview() }
    }
}

// Website sign-in persists. Reading files exist only in this launch’s temporary directory.
enum MoyeRuntimeData {
    static let imageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MoyeReaderRuntime-" + (Bundle.main.bundleIdentifier ?? "MoyeReader"), isDirectory: true)
    static func makeTemporaryDirectory() throws -> URL {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func clearCaches(_ completion: @escaping () -> Void) {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.diskCapacity = 0
        try? FileManager.default.removeItem(at: temporaryRoot)
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: completion)
    }
}

enum MoyeAppearance {
    static let preferenceKey = "MoyeShelf.DarkAppearance"
    static var isDark: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }
    static var appearance: NSAppearance { NSAppearance(named: isDark ? .darkAqua : .aqua)! }
}

private func rawColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    guard MoyeAppearance.isDark else { return rawColor(r, g, b, a) }
    let lightness = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let saturation = max(r, g, b) - min(r, g, b)
    if saturation < 0.10 {
        if lightness > 0.80 {
            if a < 0.90 { return rawColor(r, g, b, a) }
            return rawColor(0.10, 0.11, 0.15, a)
        }
        if lightness < 0.30 { return rawColor(0.92, 0.92, 0.96, a) }
        return rawColor(0.73, 0.74, 0.80, a)
    }
    return rawColor(min(1, r * 1.18 + 0.04), min(1, g * 1.18 + 0.04), min(1, b * 1.18 + 0.04), a)
}

func surfaceTint(_ alpha: CGFloat) -> NSColor {
    MoyeAppearance.isDark ? rawColor(0.17, 0.18, 0.22, max(alpha, 0.74)) : NSColor.white.withAlphaComponent(alpha)
}

func borderTint(_ alpha: CGFloat) -> NSColor {
    MoyeAppearance.isDark ? rawColor(0.80, 0.81, 0.88, alpha * 0.24) : NSColor.white.withAlphaComponent(alpha)
}

func darkReadingBackdrop(_ alpha: CGFloat = 1) -> NSColor { rawColor(0.12, 0.13, 0.17, alpha) }

func glassView(radius: CGFloat = 20, material: NSVisualEffectView.Material = .hudWindow) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .behindWindow
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.cornerCurve = .continuous
    view.layer?.borderWidth = 1
    view.layer?.borderColor = borderTint(0.64).cgColor
    view.layer?.backgroundColor = surfaceTint(0.10).cgColor
    return view
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: max(size, 12), weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

func symbol(_ name: String, size: CGFloat = 14, color: NSColor = .secondaryLabelColor) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    image?.isTemplate = true
    return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: max(size, 13), weight: .medium))
}

func iconButton(_ title: String, symbolName: String, target: AnyObject?, action: Selector, identifier: String? = nil) -> NSButton {
    let button = MoyeGlassButton(frame: .zero)
    button.title = title
    button.image = symbol(symbolName)
    button.target = target
    button.action = action
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.contentTintColor = .labelColor
    button.wantsLayer = true
    button.layer?.cornerRadius = 13
    button.layer?.backgroundColor = surfaceTint(0.45).cgColor
    button.layer?.borderWidth = 1
    button.layer?.borderColor = borderTint(0.76).cgColor
    if let identifier { button.identifier = NSUserInterfaceItemIdentifier(identifier) }
    return button
}

func addSubview(_ child: NSView, to parent: NSView) { parent.addSubview(child) }

func showAlert(_ title: String, detail: String, parent: NSWindow?) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = detail
    alert.addButton(withTitle: "好")
    if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
}

final class GlowOrb: NSView {
    private let fill: NSColor
    private let blur: CGFloat
    init(frame: NSRect, fill: NSColor, blur: CGFloat) {
        self.fill = fill; self.blur = blur
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = frame.width / 2
        layer?.shadowColor = fill.cgColor
        layer?.shadowOpacity = 0.9
        layer?.shadowRadius = blur
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); layer?.cornerRadius = min(bounds.width, bounds.height) / 2 }
}

