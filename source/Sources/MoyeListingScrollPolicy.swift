import Foundation

enum MoyeListingScrollPolicy {
    static let compactHeaderHeight: CGFloat = 72
    static let footerTop: CGFloat = 98
    private static let collapseOffset: CGFloat = 90
    private static let expandOffset: CGFloat = 4

    static func compactViewportHeight(windowHeight: CGFloat) -> CGFloat {
        max(1, windowHeight - compactHeaderHeight - footerTop)
    }

    static func compactState(current: Bool, offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, windowHeight: CGFloat) -> Bool {
        // Read the natural card height, never the canvas stretched to fit a viewport.
        // A short list must not fold: the enlarged viewport would clamp its offset
        // to zero and immediately unfold it again. Elastic overscroll is not progress.
        let compactRange = max(0, contentHeight - compactViewportHeight(windowHeight: windowHeight))
        guard compactRange > collapseOffset else { return false }
        let scrollRange = max(0, contentHeight - viewportHeight)
        let position = min(max(0, offset), scrollRange)
        return current ? position > expandOffset : position > collapseOffset
    }
}
