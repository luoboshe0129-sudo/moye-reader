import SwiftUI
import UIKit

enum MoyeReadingMode: String, CaseIterable {
    case spread, webtoon
    var title: String {
        switch self { case .spread: return "横向双页"; case .webtoon: return "长条漫画" }
    }
    static func resolve(_ value: String) -> Self { value == "vertical" ? .webtoon : Self(rawValue: value) ?? .spread }
}

enum MoyeReaderNavigation {
    enum Action: Equatable { case page(Int), chapter(Int), none }
    static func forward(onLeft: Bool, mode: MoyeReadingMode) -> Bool { mode == .spread ? onLeft : !onLeft }
    static func action(mode: MoyeReadingMode, forward: Bool, page: Int, count: Int, chapter: Int, chapterCount: Int) -> Action {
        if mode == .spread {
            let next = page + (forward ? 2 : -2)
            if next >= 0 && next < count { return .page(next) }
        }
        let nextChapter = chapter + (forward ? 1 : -1)
        return nextChapter >= 0 && nextChapter < chapterCount ? .chapter(nextChapter) : .none
    }
}

struct MoyeReaderAnchor {
    var page: Int
    var fraction: CGFloat
}

struct MoyeReaderLayout {
    var frames: [Int: CGRect]
    var orderedPages: [Int]
    var contentSize: CGSize
    var scrolls: Bool

    static func make(mode: MoyeReadingMode, count: Int, page: Int, viewport: CGSize, sizes: [Int: CGSize]) -> Self {
        let width = max(1, viewport.width), height = max(1, viewport.height)
        func size(_ index: Int) -> CGSize { sizes[index] ?? CGSize(width: 700, height: 1000) }
        if mode == .spread {
            let indices = [page, page + 1].filter { $0 >= 0 && $0 < count }
            let scrolls = indices.contains { size($0).height / max(1, size($0).width) >= 3 }
            var frames: [Int: CGRect] = [:]
            if scrolls {
                let columnWidth = indices.count == 1 ? min(width, 1000) : width / 2
                for (offset, index) in indices.enumerated() {
                    let imageSize = size(index)
                    let imageHeight = columnWidth * imageSize.height / max(1, imageSize.width)
                    let x = indices.count == 1 ? (width - columnWidth) / 2 : (offset == 0 ? columnWidth : 0)
                    frames[index] = CGRect(x: x, y: 0, width: columnWidth, height: imageHeight)
                }
            } else {
                let maxWidth = indices.count == 1 ? width : width / 2
                let fitted = indices.map { index -> CGSize in
                    let imageSize = size(index)
                    let scale = min(maxWidth / max(1, imageSize.width), height / max(1, imageSize.height))
                    return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                }
                let total = fitted.reduce(CGFloat(0)) { $0 + $1.width }
                // Page 1 is on the right. The image edges meet, even when the
                // original pages have different widths or aspect ratios.
                var x = (width - total) / 2
                for offset in indices.indices.reversed() {
                    let fittedSize = fitted[offset]
                    frames[indices[offset]] = CGRect(x: x, y: (height - fittedSize.height) / 2, width: fittedSize.width, height: fittedSize.height)
                    x += fittedSize.width
                }
            }
            return Self(frames: frames, orderedPages: indices, contentSize: CGSize(width: width, height: max(height, frames.values.map(\.maxY).max() ?? height)), scrolls: scrolls)
        }
        let imageWidth = min(1000, width)
        var frames: [Int: CGRect] = [:]
        var y: CGFloat = 0
        for index in 0..<count {
            let imageSize = size(index)
            let imageHeight = imageWidth * imageSize.height / max(1, imageSize.width)
            frames[index] = CGRect(x: (width - imageWidth) / 2, y: y, width: imageWidth, height: imageHeight)
            y += imageHeight
        }
        return Self(frames: frames, orderedPages: Array(0..<count), contentSize: CGSize(width: width, height: max(height, y)), scrolls: true)
    }

    func visiblePages(in rect: CGRect, continuous: Bool) -> [Int] {
        if !continuous { return orderedPages.filter { frames[$0]?.intersects(rect) == true } }
        var low = 0, high = orderedPages.count
        while low < high {
            let middle = (low + high) / 2
            if (frames[orderedPages[middle]]?.maxY ?? 0) < rect.minY { low = middle + 1 } else { high = middle }
        }
        var visible: [Int] = []
        var index = low
        while index < orderedPages.count, let frame = frames[orderedPages[index]], frame.minY <= rect.maxY {
            visible.append(orderedPages[index]); index += 1
        }
        return visible
    }
}

struct MoyeReaderViewportState: Equatable {
    var page = 0
    var atTop = true
    var atBottom = true
    var scrolls = false
}

@MainActor
final class MoyeReaderBridge: ObservableObject {
    @Published var state = MoyeReaderViewportState()
    weak var viewport: MoyeReaderViewport?
    func advance(forward: Bool) -> Bool { viewport?.scrollOneScreen(forward: forward) ?? false }
    func prepareTurn(forward: Bool) { viewport?.prepareTurn(forward: forward) }
    func suspend() { viewport?.suspend() }
    func resume() { viewport?.resume() }
}

struct MoyeReaderViewportRepresentable: UIViewRepresentable {
    let pages: MoyePageSet
    let chapter: MoyeChapter
    let mode: MoyeReadingMode
    let page: Int
    @ObservedObject var bridge: MoyeReaderBridge
    var onTurn: (Bool) -> Void
    var onToggleChrome: () -> Void

    func makeUIView(context: Context) -> MoyeReaderViewport { MoyeReaderViewport() }
    func updateUIView(_ view: MoyeReaderViewport, context: Context) {
        bridge.viewport = view
        view.onState = { [weak bridge] state in
            guard let bridge, bridge.state != state else { return }
            bridge.state = state
        }
        view.onTurn = onTurn
        view.onToggleChrome = onToggleChrome
        view.configure(pages: pages, chapter: chapter, mode: mode, page: page)
    }
}

@MainActor
final class MoyeReaderViewport: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private var scrollView = UIScrollView()
    private var pageSet = MoyePageSet(urls: [], albumID: 0, scrambleID: 0)
    private var chapter: MoyeChapter?
    private var mode = MoyeReadingMode.spread
    private var page = 0
    private var sizes: [Int: CGSize] = [:]
    private var slices: [Int: MoyeReaderSliceView] = [:]
    private var images: [Int: UIImage] = [:]
    private var requests = Set<Int>()
    private var failures = Set<Int>()
    private var generation = UUID()
    private var previousSize = CGSize.zero
    private var layoutInfo = MoyeReaderLayout(frames: [:], orderedPages: [], contentSize: .zero, scrolls: false)
    private var webtoonDrawingWindow = CGRect.null
    private var applyingLayout = false
    private var suspended = false
    private var outgoingViews: [UIView] = []
    private var turnAnimator: UIViewPropertyAnimator?
    private var turnID = UUID()
    private var turnTravel: CGFloat = 0
    private var requestedTurnForward: Bool?
    private var animateTurns = true
    var onState: ((MoyeReaderViewportState) -> Void)?
    var onTurn: ((Bool) -> Void)?
    var onToggleChrome: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        installScrollView()
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
    }
    private func installScrollView() {
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.frame = bounds
        insertSubview(scrollView, at: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(pages: MoyePageSet, chapter: MoyeChapter, mode newMode: MoyeReadingMode, page newPage: Int) {
        suspended = false
        let newChapter = self.chapter?.url != chapter.url || pageSet != pages
        let modeChanged = mode != newMode
        let spreadChanged = newMode == .spread && page != (newPage / 2) * 2
        let forward = requestedTurnForward ?? (newPage > page)
        let shouldAnimate = animateTurns && spreadChanged && !newChapter && !modeChanged && !UIAccessibility.isReduceMotionEnabled
        if shouldAnimate { retainOutgoingSpread(newPage: (newPage / 2) * 2) }
        else if newChapter || modeChanged || spreadChanged { finishTurn() }
        if newChapter || modeChanged || spreadChanged { requestedTurnForward = nil }
        if newChapter {
            generation = UUID()
            requests.removeAll(); failures.removeAll(); images.removeAll(); sizes.removeAll()
            self.chapter = chapter; pageSet = pages
            for index in pages.urls.indices {
                sizes[index] = MoyeReadingImageCache.shared.sizeIfKnown(url: pages.urls[index], albumID: pages.albumID, scrambleID: pages.scrambleID)
            }
        }
        if newChapter || modeChanged || spreadChanged {
            var anchor = currentAnchor()
            if newChapter { anchor = MoyeReaderAnchor(page: newPage, fraction: 0) }
            mode = newMode
            if newMode == .spread { page = (newPage / 2) * 2 } else if newChapter { page = newPage }
            if spreadChanged && !modeChanged { anchor = MoyeReaderAnchor(page: page, fraction: 0) }
            rebuild(anchor: anchor)
        }
        refreshVisiblePages()
        if shouldAnimate { animateTurn(forward: forward) }
    }

    func prepareTurn(forward: Bool) { requestedTurnForward = forward }

    private func retainOutgoingSpread(newPage: Int) {
        // Keep the existing GPU-backed page views instead of rasterizing the
        // entire iPad viewport. Interrupt at its current presentation position.
        let views = outgoingViews + [scrollView]
        let positions = views.map { $0.layer.presentation()?.affineTransform() ?? $0.transform }
        turnID = UUID()
        if let turnAnimator, turnAnimator.state == .active { turnAnimator.stopAnimation(true) }
        turnAnimator = nil
        for (view, transform) in zip(views, positions) { view.transform = transform }
        scrollView.delegate = nil
        scrollView.isUserInteractionEnabled = false
        outgoingViews = views.filter { view in
            if view.frame.intersects(bounds) { return true }
            view.removeFromSuperview(); return false
        }
        if outgoingViews.count > 2 {
            outgoingViews.dropFirst().dropLast().forEach { $0.removeFromSuperview() }
            outgoingViews = [outgoingViews.first!, outgoingViews.last!]
        }
        slices.removeAll()
        images = images.filter { $0.key == newPage || $0.key == newPage + 1 }
        scrollView = UIScrollView()
        installScrollView()
    }

    private func finishTurn() {
        turnID = UUID()
        if let turnAnimator, turnAnimator.state == .active { turnAnimator.stopAnimation(true) }
        turnAnimator = nil
        outgoingViews.forEach { $0.removeFromSuperview() }; outgoingViews.removeAll()
        scrollView.transform = .identity
        turnTravel = 0
    }

    private func animateTurn(forward: Bool) {
        let active = UUID(); turnID = active
        let travel = bounds.width * (forward ? 1 : -1)
        turnTravel = travel
        scrollView.transform = CGAffineTransform(translationX: -travel, y: 0)
        let targets = outgoingViews.map { ($0, $0.transform.tx + travel) }
        let animator = UIViewPropertyAnimator(duration: 0.18, curve: .easeOut) {
            targets.forEach { $0.0.transform = CGAffineTransform(translationX: $0.1, y: 0) }
            self.scrollView.transform = .identity
        }
        animator.addCompletion { [weak self] _ in
            guard let self, self.turnID == active else { return }
            self.finishTurn()
        }
        turnAnimator = animator
        animator.startAnimation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize else { return }
        finishTurn()
        let anchor = currentAnchor()
        previousSize = bounds.size
        scrollView.frame = bounds
        rebuild(anchor: anchor)
    }

    private func currentAnchor() -> MoyeReaderAnchor {
        guard !layoutInfo.frames.isEmpty else { return MoyeReaderAnchor(page: page, fraction: 0) }
        let top = max(0, scrollView.contentOffset.y)
        let selected: Int
        if mode == .spread {
            let longest = layoutInfo.frames.values.map(\.height).max() ?? 0
            selected = layoutInfo.orderedPages.first(where: { (layoutInfo.frames[$0]?.height ?? 0) >= longest }) ?? page
        }
        else { selected = layoutInfo.visiblePages(in: CGRect(x: 0, y: top + 1, width: max(1, bounds.width), height: 1), continuous: true).first ?? page }
        guard let frame = layoutInfo.frames[selected] else { return MoyeReaderAnchor(page: selected, fraction: 0) }
        return MoyeReaderAnchor(page: selected, fraction: min(1, max(0, (top - frame.minY) / max(1, frame.height))))
    }

    private func rebuild(anchor: MoyeReaderAnchor) {
        applyingLayout = true
        layoutInfo = MoyeReaderLayout.make(mode: mode, count: pageSet.urls.count, page: page, viewport: bounds.size, sizes: sizes)
        scrollView.contentSize = layoutInfo.contentSize
        scrollView.isScrollEnabled = layoutInfo.scrolls
        scrollView.alwaysBounceVertical = layoutInfo.scrolls
        let frame = layoutInfo.frames[anchor.page] ?? layoutInfo.frames[page]
        let desired = layoutInfo.scrolls ? (frame?.minY ?? 0) + (frame?.height ?? 0) * anchor.fraction : 0
        let maximum = max(0, layoutInfo.contentSize.height - bounds.height)
        scrollView.contentOffset = CGPoint(x: 0, y: min(maximum, max(0, desired)))
        applyingLayout = false
        refreshVisiblePages()
    }

    func refreshVisiblePages() {
        guard !suspended, bounds.width > 0, bounds.height > 0 else { return }
        let buffered = drawingWindow()
        let visible = layoutInfo.visiblePages(in: buffered, continuous: mode != .spread)
        for index in Array(slices.keys) where !visible.contains(index) {
            slices.removeValue(forKey: index)?.removeFromSuperview()
            images.removeValue(forKey: index)
        }
        for index in visible {
            guard let fullFrame = layoutInfo.frames[index] else { continue }
            let cropped = fullFrame.intersection(buffered)
            guard !cropped.isNull else { continue }
            let slice = slices[index] ?? MoyeReaderSliceView()
            if slices[index] == nil { slices[index] = slice; scrollView.addSubview(slice) }
            let imageRect = fullFrame.offsetBy(dx: -cropped.minX, dy: -cropped.minY)
            if images[index] == nil {
                images[index] = MoyeReadingImageCache.shared.imageIfCached(url: pageSet.urls[index], albumID: pageSet.albumID, scrambleID: pageSet.scrambleID)
            }
            let message = failures.contains(index) ? "页面暂时无法载入，点击重试" : "正在加载第 \(index + 1) 页…"
            if slice.frame != cropped || slice.imageRect != imageRect || slice.image !== images[index] || slice.message != message {
                slice.frame = cropped
                slice.imageRect = imageRect
                slice.image = images[index]
                slice.message = message
                slice.setNeedsDisplay()
            }
            slice.accessibilityLabel = "第 \(index + 1) 页"
            requestImage(index, priority: true)
        }
        // Schedule visible pages before nearby previews. Never queue an entire book.
        let nearby: [Int]
        if mode == .spread { nearby = [page + 2, page + 3, page - 1] }
        else { nearby = [(visible.last ?? page) + 1, (visible.first ?? page) - 1] }
        for index in nearby where pageSet.urls.indices.contains(index) { requestImage(index, priority: false) }
        publishState()
    }

    private func drawingWindow() -> CGRect {
        let top = max(0, scrollView.contentOffset.y)
        let height = bounds.height
        let moving = CGRect(x: 0, y: max(0, top - height / 2), width: bounds.width, height: height * 2)
        guard mode == .webtoon else { return moving }
        // Native scrolling moves the existing backing image. Repaint only when
        // its overscan is nearly exhausted, rather than moving/re-rasterizing
        // the image crop at every fractional content offset.
        let margin = height / 8
        let required = CGRect(x: 0, y: max(0, top - margin), width: bounds.width,
            height: top + height + margin - max(0, top - margin))
        if webtoonDrawingWindow.width == bounds.width, webtoonDrawingWindow.height == height * 2,
           webtoonDrawingWindow.contains(required) { return webtoonDrawingWindow }
        let scale = max(1, traitCollection.displayScale)
        webtoonDrawingWindow = CGRect(x: 0, y: floor(moving.minY * scale) / scale,
            width: moving.width, height: moving.height)
        return webtoonDrawingWindow
    }

    private func requestImage(_ index: Int, priority: Bool) {
        #if MOYE_IOS_DIAGNOSTICS
        if testDisableImageRequests { return }
        #endif
        guard pageSet.urls.indices.contains(index), !requests.contains(index), !failures.contains(index) else { return }
        let url = pageSet.urls[index]
        if let image = MoyeReadingImageCache.shared.imageIfCached(url: url, albumID: pageSet.albumID, scrambleID: pageSet.scrambleID) {
            if sizes[index] != image.size {
                sizes[index] = image.size
                let active = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == active else { return }
                    self.rebuild(anchor: self.currentAnchor())
                }
            }
            return
        }
        requests.insert(index)
        let active = generation
        MoyeReadingImageCache.shared.request(url: url, referer: chapter?.url, albumID: pageSet.albumID, scrambleID: pageSet.scrambleID, priority: priority) { [weak self] image in
            guard let self, self.generation == active, !self.suspended else { return }
            self.requests.remove(index)
            guard let image else { self.failures.insert(index); self.refreshVisiblePages(); return }
            let anchor = self.currentAnchor()
            let changed = self.sizes[index] != image.size
            self.sizes[index] = image.size
            if self.slices[index] != nil { self.images[index] = image }
            if changed { self.rebuild(anchor: anchor) } else { self.refreshVisiblePages() }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { if !applyingLayout { refreshVisiblePages() } }

    @discardableResult func scrollOneScreen(forward: Bool) -> Bool {
        guard layoutInfo.scrolls else { return false }
        let current = max(0, scrollView.contentOffset.y)
        let maximum = max(0, layoutInfo.contentSize.height - bounds.height)
        if forward ? current >= maximum - 1 : current <= 1 { return false }
        scrollView.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, current + (forward ? 1 : -1) * bounds.height * 0.88))), animated: true)
        return true
    }

    private func publishState() {
        let anchor = currentAnchor()
        let maximum = max(0, layoutInfo.contentSize.height - bounds.height)
        let state = MoyeReaderViewportState(page: mode == .spread ? page : anchor.page,
            atTop: scrollView.contentOffset.y <= 1, atBottom: scrollView.contentOffset.y >= maximum - 1, scrolls: layoutInfo.scrolls)
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    func suspend() {
        finishTurn()
        suspended = true
        generation = UUID()
        requests.removeAll(); failures.removeAll(); images.removeAll()
        slices.values.forEach { $0.image = nil; $0.setNeedsDisplay() }
    }
    func resume() { suspended = false; refreshVisiblePages() }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        handleTap(at: recognizer.location(in: self))
    }
    private func handleTap(at point: CGPoint) {
        let contentPoint = CGPoint(x: point.x, y: point.y + scrollView.contentOffset.y)
        if let failed = failures.first(where: { layoutInfo.frames[$0]?.contains(contentPoint) == true }) {
            failures.remove(failed); refreshVisiblePages(); return
        }
        let x = point.x
        if x < bounds.width / 3 { onTurn?(true) }
        else if x > bounds.width * 2 / 3 { onTurn?(false) }
        else { onToggleChrome?() }
    }
    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        onTurn?(mode == .spread ? recognizer.direction == .right : recognizer.direction == .left)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UISwipeGestureRecognizer && otherGestureRecognizer === scrollView.panGestureRecognizer) ||
            (otherGestureRecognizer is UISwipeGestureRecognizer && gestureRecognizer === scrollView.panGestureRecognizer)
    }

    #if MOYE_IOS_DIAGNOSTICS
    private var testDisableImageRequests = false
    func testConfigure(imageRequests: Bool, animatedTurns: Bool) {
        testDisableImageRequests = !imageRequests
        animateTurns = animatedTurns
        if !animatedTurns { finishTurn() }
    }
    var testLayout: MoyeReaderLayout { layoutInfo }
    var testSliceFrames: [CGRect] { slices.values.map(\.frame) }
    var testOffset: CGFloat { scrollView.contentOffset.y }
    var testIsTurning: Bool { turnAnimator != nil }
    var testHorizontalTranslation: CGFloat { scrollView.transform.tx }
    var testTurnTravel: CGFloat { turnTravel }
    var testPresentationTranslation: CGPoint? {
        scrollView.layer.presentation().map { CGPoint(x: $0.affineTransform().tx, y: $0.affineTransform().ty) }
    }
    var testOutgoingTranslation: CGPoint? {
        outgoingViews.last?.layer.presentation().map { CGPoint(x: $0.affineTransform().tx, y: $0.affineTransform().ty) }
    }
    var testOutgoingCount: Int { outgoingViews.count }
    func testTap(x: CGFloat) { handleTap(at: CGPoint(x: x, y: bounds.height / 2)) }
    func testImages(_ values: [Int: UIImage]) {
        let anchor = currentAnchor()
        for (index, image) in values { sizes[index] = image.size; images[index] = image }
        rebuild(anchor: anchor)
    }
    func testScroll(to y: CGFloat) { scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false) }
    #endif
}

private final class MoyeReaderSliceView: UIView {
    var image: UIImage?
    var imageRect = CGRect.zero
    var message = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.black.cgColor); context.fill(bounds)
        context.saveGState(); context.clip(to: bounds)
        if let image { image.draw(in: imageRect) }
        else {
            (message as NSString).draw(in: CGRect(x: 8, y: min(40, max(0, bounds.height / 2 - 20)), width: max(1, bounds.width - 16), height: 60),
                withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.lightGray])
        }
        context.restoreGState()
    }
}
