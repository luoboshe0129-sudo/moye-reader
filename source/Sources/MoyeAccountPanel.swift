import AppKit

private final class MoyeAccountBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let colors = MoyeAppearance.isDark
            ? [NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.21, alpha: 1), NSColor(calibratedRed: 0.25, green: 0.19, blue: 0.36, alpha: 1)]
            : [NSColor(calibratedRed: 0.98, green: 0.97, blue: 1, alpha: 1), NSColor(calibratedRed: 0.87, green: 0.83, blue: 0.97, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: bounds, angle: 0)
    }
}

final class MoyeAccountPanel: NSObject {
    private let panel: NSPanel
    private var onSwitchAccount: (() -> Void)?

    init(username: String, site: String, onSwitchAccount: @escaping () -> Void) {
        self.onSwitchAccount = onSwitchAccount
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "账号已登录"
        panel.appearance = MoyeAppearance.appearance
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        let content = MoyeAccountBackdrop(frame: NSRect(x: 0, y: 0, width: 680, height: 380))
        panel.contentView = content

        if let url = Bundle.main.url(forResource: "MoyeMascot", withExtension: "png"), let image = NSImage(contentsOf: url) {
            let mascot = NSImageView(image: image)
            mascot.imageScaling = .scaleProportionallyUpOrDown
            mascot.frame = NSRect(x: 414, y: 96, width: 242, height: 242)
            mascot.setAccessibilityLabel("墨夜动漫阅读角色")
            content.addSubview(mascot)
        }
        let check = NSImageView(image: symbol("checkmark.seal.fill", size: 31) ?? NSImage())
        check.contentTintColor = color(0.24, 0.65, 0.43)
        check.frame = NSRect(x: 34, y: 291, width: 34, height: 34)
        content.addSubview(check)
        let title = label("已成功登录", size: 28, weight: .bold)
        title.frame = NSRect(x: 80, y: 285, width: 310, height: 42)
        title.identifier = NSUserInterfaceItemIdentifier("account-signed-in-title")
        content.addSubview(title)
        let account = label(username, size: 22, weight: .semibold)
        account.frame = NSRect(x: 36, y: 231, width: 355, height: 32)
        account.identifier = NSUserInterfaceItemIdentifier("account-current-username")
        account.toolTip = username
        content.addSubview(account)
        let source = label("当前站点 · " + site, size: 14, color: .secondaryLabelColor)
        source.frame = NSRect(x: 36, y: 196, width: 355, height: 24)
        content.addSubview(source)
        let description = NSTextField(wrappingLabelWithString: "已确认网站登录会话有效。\n你可以直接搜索、阅读和下载作品。")
        description.font = .systemFont(ofSize: 16, weight: .medium)
        description.textColor = .secondaryLabelColor
        description.frame = NSRect(x: 36, y: 126, width: 363, height: 54)
        content.addSubview(description)
        let continueButton = iconButton("继续使用", symbolName: "checkmark", target: self, action: #selector(dismiss(_:)), identifier: "account-continue")
        continueButton.contentTintColor = .white
        continueButton.layer?.backgroundColor = color(0.46, 0.34, 0.66).cgColor
        continueButton.frame = NSRect(x: 36, y: 40, width: 174, height: 48)
        content.addSubview(continueButton)
        let switchButton = iconButton("切换账号", symbolName: "person.crop.circle.badge.arrow.left", target: self, action: #selector(switchAccount(_:)), identifier: "account-switch")
        switchButton.frame = NSRect(x: 224, y: 40, width: 148, height: 48)
        content.addSubview(switchButton)
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func dismiss() { panel.orderOut(nil) }
    @objc private func dismiss(_ sender: Any?) { dismiss() }
    @objc private func switchAccount(_ sender: Any?) {
        panel.orderOut(nil)
        onSwitchAccount?()
    }
}
