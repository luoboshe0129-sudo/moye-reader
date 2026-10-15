import Foundation
import SwiftUI
import UIKit
import WebKit

struct MoyeDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MoyeDownloadModel
    @State private var selectedChapterIDs: Set<String>
    @State private var shareItem: MoyeShareItem?

    private let comic: MoyeComic
    private let detail: MoyeComicDetail

    init(comic: MoyeComic, detail: MoyeComicDetail, catalog: MoyeCatalogService) {
        self.comic = comic
        self.detail = detail
        _model = StateObject(wrappedValue: MoyeDownloadModel(catalog: catalog))
        _selectedChapterIDs = State(initialValue: Set(detail.chapters.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.isRunning {
                    VStack(alignment: .leading, spacing: 9) {
                        ProgressView(value: model.progress)
                        Text(model.status ?? "正在下载…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("保留图片原始尺寸，按作品名打包成 ZIP。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                } else if let message = model.status {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        if model.archiveURL != nil {
                            Button { presentArchive() } label: {
                                Label("分享 / 保存 ZIP", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }

                HStack {
                    Text("\(selectedChapterIDs.count) / \(detail.chapters.count) 章")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(selectedChapterIDs.count == detail.chapters.count ? "取消全选" : "全选章节") {
                        if selectedChapterIDs.count == detail.chapters.count {
                            selectedChapterIDs.removeAll()
                        } else {
                            selectedChapterIDs = Set(detail.chapters.map(\.id))
                        }
                    }
                    .disabled(model.isRunning || detail.chapters.isEmpty)
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 11)

                List(Array(detail.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        guard !model.isRunning else { return }
                        if selectedChapterIDs.contains(chapter.id) {
                            selectedChapterIDs.remove(chapter.id)
                        } else {
                            selectedChapterIDs.insert(chapter.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedChapterIDs.contains(chapter.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selectedChapterIDs.contains(chapter.id) ? Color.purple : Color.secondary)
                            Text(String(format: "%02d", index + 1))
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRunning)
                }
                .listStyle(.plain)
                .overlay {
                    if detail.chapters.isEmpty {
                        ContentUnavailableView("没有可下载的章节", systemImage: "arrow.down.to.line")
                    }
                }
            }
            .navigationTitle("章节下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.isRunning ? "取消" : "关闭") {
                        if model.isRunning { model.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if model.archiveURL != nil { presentArchive() }
                        else {
                            let selected = detail.chapters.filter { selectedChapterIDs.contains($0.id) }
                            model.start(comic: comic, detail: detail, chapters: selected)
                        }
                    } label: {
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        } else if model.archiveURL != nil {
                            Image(systemName: "square.and.arrow.up")
                        } else {
                            Text("开始下载")
                        }
                    }
                    .disabled(model.isRunning || (model.archiveURL == nil && selectedChapterIDs.isEmpty))
                }
            }
            .sheet(item: $shareItem) { item in
                MoyeActivitySheet(activityItems: [item.url])
            }
            .onChange(of: model.archiveURL) { _, url in
                if let url { shareItem = MoyeShareItem(url: url) }
            }
            .background {
                MoyeHiddenWebView(webView: model.webView).frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onDisappear { model.cancel() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func presentArchive() {
        guard let url = model.archiveURL else { return }
        shareItem = MoyeShareItem(url: url)
    }
}

@MainActor
final class MoyeDownloadModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status: String?
    @Published private(set) var archiveURL: URL?

    private let catalog: MoyeCatalogService
    var webView: WKWebView { catalog.webView }
    private var task: Task<Void, Never>?

    init(catalog: MoyeCatalogService) {
        self.catalog = catalog.independentLoader()
    }

    func start(comic: MoyeComic, detail: MoyeComicDetail, chapters: [MoyeChapter]) {
        guard !isRunning, !chapters.isEmpty else { return }
        isRunning = true
        progress = 0
        status = "正在准备下载…"
        archiveURL = nil
        task = Task { [weak self] in
            await self?.run(comic: comic, detail: detail, chapters: chapters)
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        catalog.cancel()
        status = "正在停止下载…"
    }

    private func run(comic: MoyeComic, detail: MoyeComicDetail, chapters: [MoyeChapter]) async {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("MoyeDownload-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            var archiveEntries: [MoyeZipEntry] = []
            var completedPages = 0
            var failedPages = 0
            var failedChapters = 0
            let totalChapters = chapters.count

            for (chapterNumber, chapter) in chapters.enumerated() {
                guard !Task.isCancelled else { throw CancellationError() }
                status = "正在读取第 \(chapterNumber + 1) / \(totalChapters) 章：\(chapter.title)"
                guard let pages = await loadPages(comic: comic, chapter: chapter), !pages.urls.isEmpty else {
                    failedChapters += 1
                    continue
                }

                let pageCount = pages.urls.count
                var nextIndex = 0
                var processedPages = 0
                await withTaskGroup(of: (Int, MoyeExportedPage?).self) { group in
                    for _ in 0..<min(2, pageCount) {
                        let pageIndex = nextIndex
                        nextIndex += 1
                        group.addTask {
                            let data = await Self.exportPage(
                                url: pages.urls[pageIndex],
                                referer: chapter.url,
                                albumID: pages.albumID,
                                scrambleID: pages.scrambleID
                            )
                            return (pageIndex, data)
                        }
                    }

                    while let (pageIndex, exportedPage) = await group.next() {
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            return
                        }
                        processedPages += 1
                        if let exportedPage {
                            let filename = String(format: "%03d_%04d.%@", detail.chapters.firstIndex(where: { $0.id == chapter.id }).map { $0 + 1 } ?? chapterNumber + 1, pageIndex + 1, exportedPage.fileExtension)
                            let diskName = filename
                            let pageURL = scratch.appendingPathComponent(diskName)
                            do {
                                try exportedPage.data.write(to: pageURL, options: .atomic)
                                archiveEntries.append(MoyeZipEntry(url: pageURL, path: filename))
                                completedPages += 1
                            } catch {
                                failedPages += 1
                            }
                        } else {
                            failedPages += 1
                        }
                        progress = (Double(chapterNumber) + Double(processedPages) / Double(max(1, pageCount))) / Double(max(1, totalChapters))
                        status = "第 \(chapterNumber + 1) / \(totalChapters) 章 · 已处理 \(processedPages) / \(pageCount) 页 · 成功 \(completedPages) 页"

                        if nextIndex < pageCount, !Task.isCancelled {
                            let index = nextIndex
                            nextIndex += 1
                            group.addTask {
                                let data = await Self.exportPage(
                                    url: pages.urls[index],
                                    referer: chapter.url,
                                    albumID: pages.albumID,
                                    scrambleID: pages.scrambleID
                                )
                                return (index, data)
                            }
                        }
                    }
                }
                if Task.isCancelled { throw CancellationError() }
            }

            guard !archiveEntries.isEmpty else {
                throw MoyeDownloadError.noPages
            }
            status = "正在创建 ZIP 压缩包…"
            let exportDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MoyeDownloads", isDirectory: true)
            try fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let archiveURL = Self.uniqueArchiveURL(in: exportDirectory, title: detail.title)
            try await Task.detached(priority: .utility) {
                try MoyeZipWriter.create(entries: archiveEntries, destination: archiveURL)
            }.value
            if Task.isCancelled {
                try? fm.removeItem(at: archiveURL)
                throw CancellationError()
            }
            self.archiveURL = archiveURL
            progress = 1
            let size = ((try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let sizeLabel = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let isPartial = failedPages > 0 || failedChapters > 0
            status = "\(isPartial ? "部分下载完成" : "下载完成") · \(completedPages) 页 · \(sizeLabel)\(isPartial ? " · \(failedPages) 页、\(failedChapters) 章失败" : "")\n已生成：\(archiveURL.lastPathComponent)"
            isRunning = false
            task = nil
            try? fm.removeItem(at: scratch)
        } catch is CancellationError {
            try? fm.removeItem(at: scratch)
            isRunning = false
            task = nil
            status = "下载已取消，临时页面已清理。"
        } catch {
            try? fm.removeItem(at: scratch)
            isRunning = false
            task = nil
            status = error.localizedDescription
        }
    }

    private func loadPages(comic: MoyeComic, chapter: MoyeChapter) async -> MoyePageSet? {
        await withCheckedContinuation { continuation in
            catalog.loadPages(for: comic, chapter: chapter) { pages in
                continuation.resume(returning: pages)
            }
        }
    }

    private nonisolated static func exportPage(url: URL, referer: URL, albumID: Int, scrambleID: Int) async -> MoyeExportedPage? {
        let image: UIImage? = await withCheckedContinuation { continuation in
            Task { @MainActor in
                MoyeReadingImageCache.shared.request(
                    url: url,
                    referer: referer,
                    albumID: albumID,
                    scrambleID: scrambleID,
                    priority: true
                ) { image in
                    continuation.resume(returning: image)
                }
            }
        }
        guard let image else { return nil }
        var original = await MoyeReadingImageCache.shared.dataIfCached(url: url, albumID: albumID, scrambleID: scrambleID)
        if original == nil { original = await MoyeRuntimeData.imageData(url: url, referer: referer) }
        let originalData = original
        return await Task.detached(priority: .utility) {
            let restored = originalData.map { MoyeImageDecoder.needsRestoration($0, url: url, albumID: albumID, scrambleID: scrambleID) } ?? true
            return MoyePageExporter.encode(image: image, original: originalData, url: url, restored: restored)
        }.value
    }

    private static func safeComponent(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let cleaned = value.components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "章节" : cleaned).prefix(80))
    }

    private static func uniqueArchiveURL(in directory: URL, title: String) -> URL {
        let base = safeComponent(title)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("zip")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(suffix))").appendingPathExtension("zip")
            suffix += 1
        }
        return candidate
    }
}

private enum MoyeDownloadError: LocalizedError {
    case noPages
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .noPages: return "没有下载到可用页面，未生成压缩包。"
        case .archiveTooLarge: return "所选章节太大，超过 ZIP 格式可支持的大小。"
        }
    }
}

private struct MoyeZipEntry: Sendable {
    let url: URL
    let path: String
}

private enum MoyeZipWriter {
    private struct Record {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func create(entries: [MoyeZipEntry], destination: URL) throws {
        guard entries.count <= Int(UInt16.max) else { throw MoyeDownloadError.archiveTooLarge }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var records: [Record] = []
        records.reserveCapacity(entries.count)

        for entry in entries {
            let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
            guard data.count <= Int(UInt32.max), handle.offsetInFile <= UInt64(UInt32.max) else { throw MoyeDownloadError.archiveTooLarge }
            let name = Data(entry.path.replacingOccurrences(of: "\\", with: "/").utf8)
            guard name.count <= Int(UInt16.max) else { throw MoyeDownloadError.archiveTooLarge }
            let crc = crc32(data)
            let offset = UInt32(handle.offsetInFile)

            try write(signature: 0x04034b50, to: handle)
            try write(u16(20) + u16(0x0800) + u16(0) + u16(0) + u16(0x0021), to: handle)
            try write(u32(crc) + u32(UInt32(data.count)) + u32(UInt32(data.count)), to: handle)
            try write(u16(UInt16(name.count)) + u16(0) + name, to: handle)
            try handle.write(contentsOf: data)
            records.append(Record(name: name, crc: crc, size: UInt32(data.count), offset: offset))
        }

        guard handle.offsetInFile <= UInt64(UInt32.max) else { throw MoyeDownloadError.archiveTooLarge }
        let centralOffset = UInt32(handle.offsetInFile)
        for record in records {
            try write(signature: 0x02014b50, to: handle)
            try write(u16(20) + u16(20) + u16(0x0800) + u16(0) + u16(0) + u16(0x0021), to: handle)
            try write(u32(record.crc) + u32(record.size) + u32(record.size), to: handle)
            try write(u16(UInt16(record.name.count)) + u16(0) + u16(0), to: handle)
            try write(u16(0) + u16(0) + u32(0) + u32(record.offset) + record.name, to: handle)
        }
        let endOffset = handle.offsetInFile
        let centralSize = endOffset - UInt64(centralOffset)
        guard centralSize <= UInt64(UInt32.max) else { throw MoyeDownloadError.archiveTooLarge }
        try write(signature: 0x06054b50, to: handle)
        try write(u16(0) + u16(0) + u16(UInt16(records.count)) + u16(UInt16(records.count)), to: handle)
        try write(u32(UInt32(centralSize)) + u32(centralOffset) + u16(0), to: handle)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private static func write(signature: UInt32, to handle: FileHandle) throws {
        try handle.write(contentsOf: u32(signature))
    }

    private static func write(_ data: Data, to handle: FileHandle) throws {
        try handle.write(contentsOf: data)
    }

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }
}

private struct MoyeShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MoyeActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
