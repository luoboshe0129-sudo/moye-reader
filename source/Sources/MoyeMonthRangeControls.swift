import AppKit

final class MoyeMonthRangeControls: NSView {
    private(set) var isBusy = false
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    private let title = label("上架月份", size: 14, weight: .semibold)
    private let separator = label("至", size: 14, color: .secondaryLabelColor)
    private let startButton = iconButton("", symbolName: "calendar", target: nil, action: #selector(chooseStart(_:)))
    private let endButton = iconButton("", symbolName: "calendar", target: nil, action: #selector(chooseEnd(_:)))
    private let note = label("按当前爱心数", size: 13, color: .secondaryLabelColor)
    private let applyButton = iconButton("查看前 30", symbolName: "heart", target: nil, action: #selector(apply(_:)))
    private let cancelButton = iconButton("取消", symbolName: "xmark", target: nil, action: #selector(cancel(_:)))
    private var firstYear: Int
    private var firstMonth: Int
    private var lastYear: Int
    private var lastMonth: Int
    private var monthPopover: NSPopover?

    static var currentMonth: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
    var startMonth: String { String(format: "%04d-%02d", firstYear, firstMonth) }
    var endMonth: String { String(format: "%04d-%02d", lastYear, lastMonth) }
    var rangeTitle: String { startMonth == endMonth ? startMonth : startMonth + " 至 " + endMonth }

    override init(frame frameRect: NSRect) {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        firstYear = parts.year!; lastYear = parts.year!
        firstMonth = parts.month!; lastMonth = parts.month!
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = surfaceTint(0.38).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = borderTint(0.7).cgColor
        for view in [title, separator, note, startButton, endButton, applyButton, cancelButton] { addSubview(view) }
        startButton.target = self; endButton.target = self
        applyButton.target = self; cancelButton.target = self
        startButton.identifier = NSUserInterfaceItemIdentifier("month-range-start")
        endButton.identifier = NSUserInterfaceItemIdentifier("month-range-end")
        applyButton.identifier = NSUserInterfaceItemIdentifier("month-range-apply")
        cancelButton.identifier = NSUserInterfaceItemIdentifier("month-range-cancel")
        updateTitles()
        setBusy(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func copySelection(from source: MoyeMonthRangeControls) {
        firstYear = source.firstYear; firstMonth = source.firstMonth
        lastYear = source.lastYear; lastMonth = source.lastMonth
        updateTitles()
    }
    private func updateTitles() {
        startButton.title = "\(firstYear) 年 \(firstMonth) 月"
        endButton.title = "\(lastYear) 年 \(lastMonth) 月"
        startButton.setAccessibilityLabel("开始月份，" + startButton.title)
        endButton.setAccessibilityLabel("结束月份，" + endButton.title)
    }
    func setBusy(_ busy: Bool) {
        isBusy = busy
        startButton.isEnabled = !busy; endButton.isEnabled = !busy
        applyButton.isEnabled = !busy; cancelButton.isHidden = !busy
        if busy { monthPopover?.close() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 20, y: 19, width: 80, height: 22)
        startButton.frame = NSRect(x: 106, y: 12, width: 186, height: 36)
        separator.frame = NSRect(x: 309, y: 19, width: 22, height: 22)
        endButton.frame = NSRect(x: 344, y: 12, width: 186, height: 36)
        note.frame = NSRect(x: 558, y: 19, width: 140, height: 22)
        let right = bounds.width - 16
        cancelButton.frame = NSRect(x: right - 82, y: 12, width: 82, height: 36)
        applyButton.frame = NSRect(x: right - (cancelButton.isHidden ? 130 : 224), y: 12, width: 130, height: 36)
    }
    private func showPicker(start: Bool) {
        monthPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let picker = MoyeMonthPicker(year: start ? firstYear : lastYear, month: start ? firstMonth : lastMonth) { [weak self, weak popover] year, month in
            guard let self else { return }
            if start { self.firstYear = year; self.firstMonth = month }
            else { self.lastYear = year; self.lastMonth = month }
            self.updateTitles(); popover?.close()
        }
        popover.contentViewController = picker
        popover.contentSize = NSSize(width: 330, height: 260)
        monthPopover = popover
        let button = start ? startButton : endButton
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
    @objc private func chooseStart(_ sender: Any?) { showPicker(start: true) }
    @objc private func chooseEnd(_ sender: Any?) { showPicker(start: false) }
    @objc private func apply(_ sender: Any?) { onApply?() }
    @objc private func cancel(_ sender: Any?) { onCancel?() }
}

private final class MoyeMonthPicker: NSViewController {
    private var year: Int
    private let selectedYear: Int
    private let selectedMonth: Int
    private let onSelect: (Int, Int) -> Void
    private let yearLabel = label("", size: 19, weight: .semibold)
    private let previousButton = iconButton("", symbolName: "chevron.left", target: nil, action: #selector(previousYear(_:)))
    private let nextButton = iconButton("", symbolName: "chevron.right", target: nil, action: #selector(nextYear(_:)))
    private var monthButtons: [NSButton] = []
    init(year: Int, month: Int, onSelect: @escaping (Int, Int) -> Void) {
        self.year = year; selectedYear = year; selectedMonth = month; self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 260))
        view.appearance = MoyeAppearance.appearance
        view.wantsLayer = true
        view.layer?.backgroundColor = surfaceTint(0.98).cgColor
        yearLabel.alignment = .center
        yearLabel.frame = NSRect(x: 68, y: 206, width: 194, height: 32)
        previousButton.frame = NSRect(x: 20, y: 204, width: 38, height: 38)
        nextButton.frame = NSRect(x: 272, y: 204, width: 38, height: 38)
        previousButton.target = self; nextButton.target = self
        previousButton.setAccessibilityLabel("上一年")
        nextButton.setAccessibilityLabel("下一年")
        for child in [yearLabel, previousButton, nextButton] { view.addSubview(child) }
        for month in 1...12 {
            let button = MoyeGlassButton(frame: NSRect(x: 20 + CGFloat((month - 1) % 3) * 100, y: 150 - CGFloat((month - 1) / 3) * 45, width: 90, height: 36))
            button.title = "\(month) 月"
            button.tag = month
            button.target = self; button.action = #selector(selectMonth(_:))
            button.font = .systemFont(ofSize: 15, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier("month-picker-\(month)")
            button.wantsLayer = true; button.layer?.cornerRadius = 12
            view.addSubview(button); monthButtons.append(button)
        }
        updateYear()
    }
    private func updateYear() {
        yearLabel.stringValue = "\(year) 年"
        let current = Calendar.current.dateComponents([.year, .month], from: Date())
        previousButton.isEnabled = year > 2000
        nextButton.isEnabled = year < current.year!
        for button in monthButtons {
            let selected = year == selectedYear && button.tag == selectedMonth
            button.isEnabled = year < current.year! || button.tag <= current.month!
            button.layer?.backgroundColor = (selected ? color(0.49, 0.37, 0.68) : surfaceTint(0.45)).cgColor
            button.contentTintColor = selected ? .white : .labelColor
        }
    }
    @objc private func previousYear(_ sender: Any?) { year = max(2000, year - 1); updateYear() }
    @objc private func nextYear(_ sender: Any?) { year = min(Calendar.current.component(.year, from: Date()), year + 1); updateYear() }
    @objc private func selectMonth(_ sender: NSButton) { onSelect(year, sender.tag) }
}
