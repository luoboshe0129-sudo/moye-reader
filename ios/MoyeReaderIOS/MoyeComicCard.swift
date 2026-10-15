import SwiftUI

enum MoyeComicCardLayout {
    static func columnCount(requested: Int) -> Int { min(3, max(1, requested)) }

    struct Metrics {
        let height: CGFloat
        let cover: CGRect
        let information: CGRect
        let narrow: Bool
        let compact: Bool
    }
    static func metrics(width: CGFloat) -> Metrics {
        let height: CGFloat = 245
        if width < 250 {
            let coverHeight: CGFloat = 189
            let coverWidth = max(1, min(width - 20, coverHeight * 0.69))
            return Metrics(height: height, cover: CGRect(x: (width - coverWidth) / 2, y: 10, width: coverWidth, height: coverHeight),
                information: CGRect(x: 10, y: 205, width: max(1, width - 20), height: 30), narrow: true, compact: true)
        }
        let inset: CGFloat = 14, gap: CGFloat = 14
        let coverHeight = height - inset * 2
        let coverWidth = min(coverHeight * 0.69, width * 0.37)
        let textX = inset + coverWidth + gap
        return Metrics(height: height, cover: CGRect(x: inset, y: inset, width: coverWidth, height: coverHeight),
            information: CGRect(x: textX, y: inset, width: max(1, width - textX - inset), height: coverHeight), narrow: width < 420, compact: false)
    }
}

struct MoyeComicCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let comic: MoyeComic

    var body: some View {
        GeometryReader { geometry in
            let metrics = MoyeComicCardLayout.metrics(width: geometry.size.width)
            if metrics.compact {
                VStack(spacing: 6) {
                    cover(metrics).frame(maxWidth: .infinity)
                    Text(comic.title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30, alignment: .topLeading)
                }.padding(10)
            } else {
              HStack(alignment: .top, spacing: 14) {
                cover(metrics)
                VStack(alignment: .leading, spacing: 10) {
                    Text(comic.title)
                        .font(.system(size: metrics.narrow ? 16 : 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(metrics.narrow ? 4 : 3)
                        .multilineTextAlignment(.leading)
                    Text(comic.author.isEmpty ? "作者信息暂未提供" : "作者 · " + comic.author)
                        .font(.system(size: metrics.narrow ? 12 : 14))
                        .foregroundStyle(.secondary).lineLimit(2)
                    if !comic.metadata.isEmpty {
                        Text(comic.metadata)
                            .font(.system(size: metrics.narrow ? 12 : 13))
                            .foregroundStyle(.secondary).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Text("JM \(comic.id)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: metrics.information.width, height: metrics.information.height, alignment: .topLeading)
            }
            .padding(14)
            }
        }
        // A compact card keeps the cover in portrait orientation at every grid width.
        .frame(height: 245)
        .background(colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.16) : .white.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("comic-card-" + comic.id)
    }

    private func cover(_ metrics: MoyeComicCardLayout.Metrics) -> some View {
        MoyeRemoteImage(url: comic.coverURL, referer: comic.url, contentMode: .fit)
            .frame(width: metrics.cover.width, height: metrics.cover.height)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityIdentifier("comic-cover-" + comic.id)
    }
}
