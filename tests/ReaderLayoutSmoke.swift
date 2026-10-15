import AppKit

private struct CheckFailure: Error { let message: String }

@main
enum ReaderLayoutSmoke {
    static func main() {
        let application = NSApplication.shared
        let delegate = ReaderChecks()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

private final class ReaderChecks: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var reader: MoyeComicReaderView!
    private var checks: [String] = []
    private let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOYE_READER_OUTPUT"]!)
    private var deferredImage: ((NSImage?) -> Void)?
    private var released = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "阅读器布局检查"
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        Task { @MainActor in
            do { try await verify(); finish(true, "Reader geometry, rendering and scroll checks passed") }
            catch { finish(false, (error as? CheckFailure)?.message ?? String(describing: error)) }
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(message: message) }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func control(_ id: String) -> NSView? { descendants(reader).first { $0.identifier?.rawValue == id } }
    private func click(_ id: String) { (control(id) as? NSButton)?.performClick(nil); reader.layoutSubtreeIfNeeded() }
    private func setMode(_ segment: Int) {
        let control = control("reader-mode") as! NSSegmentedControl
        control.selectedSegment = segment
        control.sendAction(control.action!, to: control.target)
        reader.layoutSubtreeIfNeeded()
    }
    private var state: [String: Any] { reader.layoutSubtreeIfNeeded(); return reader.verificationSnapshot() }
    private func frames(_ key: String) -> [[String: CGFloat]] { state[key] as! [[String: CGFloat]] }
    private var scroll: NSScrollView { descendants(reader).first { $0 is NSScrollView } as! NSScrollView }
    private func scrollTo(_ y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        reader.layoutSubtreeIfNeeded()
    }
    private var fraction: CGFloat {
        let position = state["viewport"] as! [String: CGFloat]
        let page = frames("pageFrames")[reader.currentPage]
        return (position["y"]! - page["y"]!) / page["height"]!
    }
    private func record(_ name: String) throws {
        reader.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = reader.bitmapImageRepForCachingDisplay(in: reader.bounds) else { throw CheckFailure(message: "Unable to render \(name)") }
        reader.cacheDisplay(in: reader.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    private func renderedColor(page: Int? = nil) throws -> NSColor {
        guard let image = descendants(reader).compactMap({ $0 as? NSImageView }).first(where: {
            $0.image != nil && !$0.isHidden && !($0.superview?.isHidden ?? false) &&
            (page == nil || $0.identifier?.rawValue == "reader-page-\(page! + 1)")
        }),
              let bitmap = image.bitmapImageRepForCachingDisplay(in: image.bounds) else { throw CheckFailure(message: "Visible image missing") }
        image.cacheDisplay(in: image.bounds, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    }
    private func readerColors() throws -> [NSColor] {
        guard let bitmap = reader.bitmapImageRepForCachingDisplay(in: reader.bounds) else { throw CheckFailure(message: "Reader render missing") }
        reader.cacheDisplay(in: reader.bounds, to: bitmap)
        return [bitmap.pixelsWide / 4, bitmap.pixelsWide * 3 / 4, 4].map {
            bitmap.colorAt(x: $0, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
        }
    }
    private func install(_ mode: String, pages: Int, initialPage: Int = 0, chapters: Int = 1,
                         loader: @escaping MoyeComicReaderView.PageLoader) {
        UserDefaults.standard.set(mode, forKey: "MoyeReader.ReadingMode")
        reader = MoyeComicReaderView(title: "阅读器回归测试", pageCount: pages, initialPage: initialPage,
                                     chapterCount: chapters, loader: loader)
        window.contentView = reader
        window.setContentSize(NSSize(width: 1280, height: 900))
        reader.frame = NSRect(x: 0, y: 0, width: 1280, height: 900)
        reader.autoresizingMask = [.width, .height]
        reader.needsLayout = true
        reader.layoutSubtreeIfNeeded()
    }
    @MainActor private func wait(_ condition: () -> Bool, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            try require(Date() < deadline, message)
            try await Task.sleep(nanoseconds: 30_000_000)
            reader.layoutSubtreeIfNeeded()
        }
    }
    private func image(width: Int, height: Int, bands: [(UInt8, UInt8, UInt8)]) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24)!
        let data = rep.bitmapData!
        for y in 0..<height {
            let color = bands[min(bands.count - 1, y * bands.count / height)]
            for x in 0..<width {
                let at = y * rep.bytesPerRow + x * 3
                data[at] = color.0; data[at + 1] = color.1; data[at + 2] = color.2
            }
        }
        let result = NSImage(size: NSSize(width: width, height: height))
        result.addRepresentation(rep)
        return result
    }

    @MainActor private func verify() async throws {
        let red = image(width: 400, height: 600, bands: [(230, 40, 40)])
        let green = image(width: 500, height: 600, bands: [(40, 220, 70)])
        let blue = image(width: 400, height: 600, bands: [(40, 70, 230)])
        let tall = image(width: 200, height: 12000, bands: [(230, 40, 40), (40, 220, 70), (40, 70, 230)])
        let images = [red, green, blue]
        install("spread", pages: 3) { index, done in DispatchQueue.main.async { done(images[index]) } }
        try await wait({ (self.state["displayed"] as! [Int]).count == 2 }, "Spread images failed to load")
        let spread = frames("spreadFrames")
        try require(abs(spread[1]["x"]! + spread[1]["width"]! - spread[0]["x"]!) < 0.001, "Spread seam is not zero")
        try require(abs(spread[0]["height"]! - spread[1]["height"]!) < 0.001, "Spread heights differ")
        try record("spread-no-gap")
        checks.append("zero spread seam with different page widths")
        click("reader-next")
        try await wait({ (self.state["displayed"] as! [Int]).count == 1 }, "Odd final page did not load")
        let single = frames("spreadFrames")[0]
        let stageWidth = (state["stage"] as! [String: CGFloat])["width"]!
        try require(abs(single["x"]! + single["width"]! / 2 - stageWidth / 2) <= 0.51, "Odd page is not centered")
        checks.append("odd final page centers correctly")

        let otherTall = image(width: 200, height: 12000, bands: [(40, 70, 230), (230, 40, 40), (40, 220, 70)])
        let longPair = [tall, otherTall, red, green]
        install("spread", pages: 4) { index, done in DispatchQueue.main.async { done(longPair[index]) } }
        try await wait({ self.state["spreadScrollable"] as! Bool && (self.state["displayed"] as! [Int]).count == 2 }, "Long pages did not become scrollable in spread mode")
        let longFrames = frames("spreadPageFrames")
        try require(state["mode"] as! String == "spread", "Long pages forced a different reading mode")
        try require(longFrames[0]["width"]! > 500 && abs(longFrames[0]["height"]! / longFrames[0]["width"]! - 60) < 0.001, "Spread long pages are narrowed or distorted")
        try require(abs(longFrames[1]["x"]! + longFrames[1]["width"]! - longFrames[0]["x"]!) < 0.001, "Scrollable spread has a seam")
        scrollTo(longFrames[0]["height"]! * 0.5)
        try await wait({ (self.frames("spreadFrames").first?["y"] ?? 0) > 15000 }, "Spread long-page slice did not update")
        for page in 0..<2 {
            let color = try renderedColor(page: page)
            if page == 0 {
                try require(color.greenComponent > color.redComponent + 0.15 && color.greenComponent > color.blueComponent + 0.15, "Middle of right spread page is missing")
            } else {
                try require(color.redComponent > color.greenComponent + 0.15 && color.redComponent > color.blueComponent + 0.15, "Middle of left spread page is missing")
            }
        }
        let wholeColors = try readerColors()
        try require(wholeColors[0].redComponent > wholeColors[0].greenComponent + 0.15, "Left long column is overwritten")
        try require(wholeColors[1].greenComponent > wholeColors[1].redComponent + 0.15, "Right long column is overwritten")
        try require(wholeColors[2].redComponent < 0.3 && wholeColors[2].greenComponent < 0.3 && wholeColors[2].blueComponent < 0.3, "Long page drawing spills outside its column")
        try record("spread-long-middle")
        let spreadBefore = scroll.contentView.bounds.minY / frames("spreadPageFrames")[0]["height"]!
        reader.setFrameSize(NSSize(width: 960, height: 800)); reader.needsLayout = true; reader.layoutSubtreeIfNeeded()
        try require(abs(scroll.contentView.bounds.minY / frames("spreadPageFrames")[0]["height"]! - spreadBefore) < 0.001, "Resizing a long spread lost its position")
        setMode(2); setMode(0)
        try require(abs(scroll.contentView.bounds.minY / frames("spreadPageFrames")[0]["height"]! - spreadBefore) < 0.001, "Switching out of a long spread lost its position")
        let offsetBefore = scroll.contentView.bounds.minY
        click("reader-next")
        try require(reader.currentPage < 2 && scroll.contentView.bounds.minY > offsetBefore, "Spread next button skipped unread long-page content")
        click("reader-previous")
        try require(reader.currentPage < 2 && scroll.contentView.bounds.minY < offsetBefore + 1, "Spread previous button failed to scroll back")
        scrollTo(scroll.documentView!.bounds.height - scroll.contentSize.height)
        try await wait({ (self.frames("spreadFrames").first?["y"] ?? 0) > 22000 }, "Spread bottom slice did not update")
        for page in 0..<2 {
            let color = try renderedColor(page: page)
            if page == 0 {
                try require(color.blueComponent > color.redComponent + 0.15 && color.blueComponent > color.greenComponent + 0.15, "Bottom of right spread page is missing")
            } else {
                try require(color.greenComponent > color.redComponent + 0.15 && color.greenComponent > color.blueComponent + 0.15, "Bottom of left spread page is missing")
            }
        }
        let spreadViewport = state["viewport"] as! [String: CGFloat]
        try require(frames("spreadFrames").allSatisfy { $0["height"]! <= spreadViewport["height"]! * 3 + 1024 }, "Long spread allocated a giant backing view")
        try record("spread-long-bottom")
        click("reader-next")
        try await wait({ self.reader.currentPage == 2 && !(self.state["spreadScrollable"] as! Bool) }, "Long spread did not return to normal spread layout")
        checks.append("long pages remain in spread mode with full-width columns and zero seam")
        checks.append("both long spread columns render their middle and bottom")
        checks.append("long spread scrolls before flipping groups and preserves position")

        var mixedChapterChanges = 0
        install("spread", pages: 2, chapters: 2) { index, done in DispatchQueue.main.async { done(index == 0 ? red : tall) } }
        reader.onNextChapter = { mixedChapterChanges += 1 }
        try await wait({ self.state["spreadScrollable"] as! Bool && (self.state["displayed"] as! [Int]).count == 2 }, "Mixed normal/long spread failed")
        let mixedFrames = frames("spreadPageFrames")
        try require(abs(mixedFrames[0]["height"]! / mixedFrames[0]["width"]! - 1.5) < 0.001, "Normal page beside a long page was distorted")
        click("reader-next")
        try require(mixedChapterChanges == 0 && scroll.contentView.bounds.minY > 0, "Mixed spread advanced chapter before reading its long page")
        scrollTo(scroll.documentView!.bounds.height - scroll.contentSize.height)
        try await wait({ (self.frames("spreadFrames").first?["y"] ?? 0) > 30000 }, "Mixed spread bottom did not render")
        let mixedBottom = try renderedColor(page: 1)
        try require(mixedBottom.blueComponent > mixedBottom.redComponent + 0.15, "Mixed spread clipped the long page tail")
        click("reader-next")
        try require(mixedChapterChanges == 1, "Mixed spread did not advance chapter at the real bottom")
        checks.append("mixed normal/long spreads keep both aspect ratios and complete the long page")

        var requests = 0
        install("webtoon", pages: 300) { index, done in requests += 1; DispatchQueue.main.async { done(index == 0 ? tall : red) } }
        try await wait({ (self.state["displayed"] as! [Int]).contains(0) && self.frames("pageFrames")[0]["height"]! > 50000 }, "Very tall page failed to expand")
        let first = frames("pageFrames")[0]
        try require(abs(first["height"]! / first["width"]! - 60) < 0.001, "Tall image aspect ratio was truncated")
        let second = frames("pageFrames")[1]
        try require(abs(second["y"]! - first["height"]!) < 0.001, "Webtoon strips have a gap")
        try require(requests < 15, "Initial rendering loaded the whole chapter")
        let viewport = state["viewport"] as! [String: CGFloat]
        try require(frames("renderedFrames").allSatisfy { $0["height"]! <= viewport["height"]! * 3 + 1024 }, "Giant image backing view allocated")
        let topColor = try renderedColor()
        try require(topColor.redComponent > topColor.greenComponent + 0.15 && topColor.redComponent > topColor.blueComponent + 0.15, "Tall page top is blank or reversed")
        scrollTo(first["height"]! * 0.5)
        try await wait({ (self.frames("renderedFrames").first?["y"] ?? 0) > 20000 }, "Scrolled image slice did not update")
        let middleColor = try renderedColor()
        try record("long-strip-middle")
        try require(middleColor.greenComponent > middleColor.redComponent + 0.15 && middleColor.greenComponent > middleColor.blueComponent + 0.15, "Tall page middle is blank or distorted: \(middleColor)")
        try require((control("reader-previous") as! NSButton).isEnabled, "Upward scroll button disabled in the middle of a long page")
        let before = fraction
        reader.setFrameSize(NSSize(width: 960, height: 800))
        reader.needsLayout = true; reader.layoutSubtreeIfNeeded()
        try require(abs(fraction - before) < 0.001, "Resize moved the reading position")
        setMode(0); setMode(2)
        try require(abs(fraction - before) < 0.001, "Mode switch lost the middle of a long page")
        click("reader-hide-toolbar")
        try require(abs(fraction - before) < 0.001, "Hiding toolbar moved the reading position")
        checks.append("unclamped tall-page aspect ratio and clipped rendering")
        checks.append("viewport-sized page views in a 300-page chapter")
        checks.append("position preserved across resizing, mode switches and toolbar changes")

        install("vertical", pages: 20, initialPage: 5) { index, done in
            if index == 3 && !self.released { self.deferredImage = done }
            else { DispatchQueue.main.async { done(red) } }
        }
        try await wait({ self.deferredImage != nil && (self.state["displayed"] as! [Int]).contains(5) }, "Deferred page test did not reach page 5")
        let page5 = frames("pageFrames")[5]
        scrollTo(page5["y"]! + page5["height"]! * 0.25)
        let anchored = fraction
        released = true; deferredImage?(tall); deferredImage = nil
        try await wait({ self.frames("pageFrames")[3]["height"]! > 50000 }, "Deferred long page did not resize")
        try require(reader.currentPage == 5 && abs(fraction - anchored) < 0.001, "Loading a page above caused a scroll jump")
        checks.append("delayed size changes above the viewport preserve the anchor")

        var chapterChanges = 0
        install("webtoon", pages: 1, chapters: 2) { _, done in DispatchQueue.main.async { done(tall) } }
        reader.onNextChapter = { chapterChanges += 1 }
        try await wait({ self.frames("pageFrames")[0]["height"]! > 50000 }, "Final long-page test failed")
        click("reader-next")
        try require(chapterChanges == 0 && scroll.contentView.bounds.minY > 0, "Next button skipped an unfinished long page")
        let maximum = scroll.documentView!.bounds.height - scroll.contentSize.height
        scrollTo(maximum)
        try await wait({ (self.frames("renderedFrames").first?["y"] ?? 0) > 50000 }, "Bottom image slice did not update")
        let bottomColor = try renderedColor()
        try require(bottomColor.blueComponent > bottomColor.redComponent + 0.15 && bottomColor.blueComponent > bottomColor.greenComponent + 0.15, "Tall page bottom is blank or reversed")
        try record("long-strip-bottom")
        click("reader-next")
        try require(chapterChanges == 1, "Next chapter did not activate at the real chapter bottom")
        checks.append("long page scrolls by screen and advances chapter only at the bottom")
    }
    private func finish(_ passed: Bool, _ message: String) {
        if !passed { try? record("failure") }
        let report: [String: Any] = ["passed": passed, "message": message, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("result.json"))
        }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        window.orderOut(nil)
        exit(passed ? 0 : 1)
    }
}
