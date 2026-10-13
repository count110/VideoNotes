import AppKit
import Foundation
import PDFKit

// MARK: - DailyNotesPDFExporter

/// 把今天记录的笔记导出为一份 A4 纵向、排版整洁的 PDF。
///
/// UI 层只负责触发 NSSavePanel 和展示结果；查询、排序、排版、图片布局、
/// 分页、中文字体、页码等全部封装在本模块中。
final class DailyNotesPDFExporter {

    enum ExportError: LocalizedError {
        case emptyRecords
        case cannotCreatePDF
        case cannotReadGeneratedPDF

        var errorDescription: String? {
            switch self {
            case .emptyRecords:
                return "今天还没有可以导出的笔记"
            case .cannotCreatePDF:
                return "无法创建 PDF 文件，请重新选择保存位置"
            case .cannotReadGeneratedPDF:
                return "无法读取生成的 PDF 页数"
            }
        }
    }

    // A4 纵向（72 dpi）
    private static let pageWidth: CGFloat = 595
    private static let pageHeight: CGFloat = 842
    private static let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    private static let margin: CGFloat = 48
    private static let contentWidth: CGFloat = pageWidth - margin * 2
    private static let contentBottom: CGFloat = 56
    private static let contentTop: CGFloat = pageHeight - margin

    func export(
        records: [NoteRecord],
        to url: URL,
        title: String = "今日学习笔记",
        subtitle: String? = nil
    ) throws {
        let sorted = records.sorted { $0.createdAt < $1.createdAt }

        guard !sorted.isEmpty else { throw ExportError.emptyRecords }

        // 第一次渲染用于得到总页数；第二次渲染写入正式页码。
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".vn-pdf-tmp-\(UUID().uuidString).pdf")

        try render(
            records: sorted,
            to: tempURL,
            totalPages: nil,
            title: title,
            subtitle: subtitle
        )

        let pageCount: Int
        if let document = PDFDocument(url: tempURL) {
            pageCount = document.pageCount
        } else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExportError.cannotReadGeneratedPDF
        }

        try render(
            records: sorted,
            to: url,
            totalPages: pageCount,
            title: title,
            subtitle: subtitle
        )
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Rendering

    private func render(
        records: [NoteRecord],
        to url: URL,
        totalPages: Int?,
        title: String,
        subtitle: String?
    ) throws {
        var mediaBox = Self.pageRect
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ExportError.cannotCreatePDF
        }

        let page = PDFPage(
            context: context,
            totalPages: totalPages,
            exportDate: Date()
        )
        page.beginPage()

        drawHeader(records: records, title: title, subtitle: subtitle, on: page)

        for (index, record) in records.enumerated() {
            drawRecordCard(record, index: index + 1, on: page)
        }

        page.endPage()
        context.closePDF()
    }

    // MARK: - Header / Cover

    private func drawHeader(
        records: [NoteRecord],
        title: String,
        subtitle: String?,
        on page: PDFPage
    ) {
        let today = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 · EEEE"
        let dateText = subtitle ?? dateFormatter.string(from: today)

        page.drawText(
            "VideoNotes",
            font: .systemFont(ofSize: 30, weight: .bold),
            color: NSColor(calibratedWhite: 0.10, alpha: 1),
            in: CGRect(x: Self.margin, y: page.currentY - 36, width: Self.contentWidth, height: 36)
        )
        page.moveDown(36 + 8)

        page.drawText(
            title,
            font: .systemFont(ofSize: 20, weight: .semibold),
            color: NSColor(calibratedWhite: 0.18, alpha: 1),
            in: CGRect(x: Self.margin, y: page.currentY - 26, width: Self.contentWidth, height: 26)
        )
        page.moveDown(26 + 4)

        page.drawText(
            dateText,
            font: .systemFont(ofSize: 13, weight: .regular),
            color: NSColor(calibratedWhite: 0.42, alpha: 1),
            in: CGRect(x: Self.margin, y: page.currentY - 18, width: Self.contentWidth, height: 18)
        )
        page.moveDown(18 + 6)

        let stats = Self.stats(from: records)
        page.drawText(
            stats,
            font: .systemFont(ofSize: 12, weight: .medium),
            color: NSColor(calibratedWhite: 0.32, alpha: 1),
            in: CGRect(x: Self.margin, y: page.currentY - 18, width: Self.contentWidth, height: 18)
        )
        page.moveDown(18 + 14)

        drawSeparator(on: page)
        page.moveDown(18)
    }

    private func drawSeparator(on page: PDFPage) {
        let y = page.currentY - 1
        page.context.setFillColor(NSColor(calibratedWhite: 0.88, alpha: 1).cgColor)
        page.context.fill(CGRect(x: Self.margin, y: y, width: Self.contentWidth, height: 1))
    }

    private static func stats(from records: [NoteRecord]) -> String {
        let videoIDs = Set(records.compactMap { record -> String? in
            if let sessionID = record.videoSessionID { return sessionID.uuidString }
            if let title = record.videoTitle, !title.isEmpty { return "title:\(title)" }
            return nil
        })
        let imageCount = records.filter { record in
            guard let path = record.screenshotPath else { return false }
            return FileManager.default.fileExists(atPath: path)
        }.count
        return "共记录 \(records.count) 条笔记 · 来自 \(videoIDs.count) 个视频 · 包含 \(imageCount) 张截图"
    }

    // MARK: - Record card

    private func drawRecordCard(_ record: NoteRecord, index: Int, on page: PDFPage) {
        let estimatedHeight = estimateCardHeight(record)
        if page.currentY - estimatedHeight < Self.contentBottom {
            page.endPage()
            page.beginPage()
        }

        let title = record.videoTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.videoTitle!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "笔记"

        let inset: CGFloat = 16
        let textX = Self.margin + inset
        let textWidth = Self.contentWidth - inset * 2

        // 卡片背景
        let cardRect = CGRect(
            x: Self.margin,
            y: page.currentY - estimatedHeight,
            width: Self.contentWidth,
            height: estimatedHeight
        )
        let path = CGPath(
            roundedRect: cardRect,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
        page.context.addPath(path)
        page.context.setFillColor(NSColor(calibratedWhite: 0.965, alpha: 1).cgColor)
        page.context.fillPath()

        page.currentY -= inset

        let indexTitle = "\(String(format: "%02d", index)) · \(title)"
        page.drawText(
            indexTitle,
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: NSColor(calibratedWhite: 0.15, alpha: 1),
            in: CGRect(x: textX, y: page.currentY - 20, width: textWidth, height: 20)
        )
        page.currentY -= 20 + 6

        let timeText = record.createdAt.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        )
        page.drawText(
            timeText,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: NSColor(calibratedWhite: 0.35, alpha: 1),
            in: CGRect(x: textX, y: page.currentY - 16, width: textWidth, height: 16)
        )
        page.currentY -= 16 + 8

        // 正文
        let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            let contentHeight = Self.heightForWrappingText(
                content,
                font: .systemFont(ofSize: 13, weight: .regular),
                width: textWidth,
                lineSpacing: 4
            )
            page.drawWrappingText(
                content,
                font: .systemFont(ofSize: 13, weight: .regular),
                color: NSColor(calibratedWhite: 0.16, alpha: 1),
                in: CGRect(x: textX, y: page.currentY - contentHeight, width: textWidth, height: contentHeight),
                lineSpacing: 4
            )
            page.currentY -= contentHeight + 10
        }

        // 元数据：视频时间点、来源 App、videoURL、标签
        var metaLines: [String] = []
        if let timestamp = record.videoTimestamp {
            metaLines.append("视频时间 \(timestamp)")
        } else if let seconds = record.videoTimestampSeconds {
            metaLines.append("视频时间 \(Self.formatTimestamp(seconds))")
        }
        if let source = record.sourceApplicationName {
            metaLines.append("来源 App \(source)")
        }
        if !record.tags.isEmpty {
            metaLines.append("标签 \(record.tags.joined(separator: " · "))")
        }
        if let videoURL = record.videoURL, !videoURL.isEmpty {
            metaLines.append("视频链接 \(videoURL)")
        }

        for line in metaLines {
            let lineHeight = Self.heightForWrappingText(
                line,
                font: .systemFont(ofSize: 11, weight: .regular),
                width: textWidth,
                lineSpacing: 2
            )
            page.drawWrappingText(
                line,
                font: .systemFont(ofSize: 11, weight: .regular),
                color: NSColor(calibratedWhite: 0.42, alpha: 1),
                in: CGRect(x: textX, y: page.currentY - lineHeight, width: textWidth, height: lineHeight),
                lineSpacing: 2
            )
            page.currentY -= lineHeight + 3
        }

        // 截图
        if let path = record.screenshotPath,
           FileManager.default.fileExists(atPath: path),
           let image = NSImage(contentsOfFile: path),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            page.drawImage(cgImage, maxWidth: textWidth, maxHeight: 320)
            page.currentY -= 10
        }

        page.currentY = cardRect.minY - 14
    }

    private func estimateCardHeight(_ record: NoteRecord) -> CGFloat {
        let inset: CGFloat = 16
        let textWidth = Self.contentWidth - inset * 2
        var height: CGFloat = inset * 2 + 20 + 6 + 16 + 8

        let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            height += Self.heightForWrappingText(
                content,
                font: .systemFont(ofSize: 13, weight: .regular),
                width: textWidth,
                lineSpacing: 4
            ) + 10
        }

        if record.videoTimestamp != nil || record.videoTimestampSeconds != nil { height += 18 }
        if record.sourceApplicationName != nil { height += 18 }
        if !record.tags.isEmpty { height += 18 }
        if let videoURL = record.videoURL, !videoURL.isEmpty { height += 18 }

        if let path = record.screenshotPath,
           FileManager.default.fileExists(atPath: path),
           let image = NSImage(contentsOfFile: path),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let aspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
            let scaledWidth = textWidth
            let scaledHeight = scaledWidth / aspect
            let maxImageHeight: CGFloat = 320
            height += min(scaledHeight, maxImageHeight) + 10
        }

        return height
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private static func heightForWrappingText(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style
        ]
        let rect = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }
}

// MARK: - PDFPage

private final class PDFPage {
    let context: CGContext
    var currentY: CGFloat
    var pageNumber: Int = 1
    let totalPages: Int?
    let exportDate: Date

    private let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let margin: CGFloat = 48
    private let contentWidth: CGFloat = 595 - 48 * 2
    private let contentBottom: CGFloat = 56
    private let contentTop: CGFloat = 842 - 48

    init(context: CGContext, totalPages: Int?, exportDate: Date) {
        self.context = context
        self.totalPages = totalPages
        self.exportDate = exportDate
        self.currentY = contentTop
    }

    func beginPage() {
        context.beginPDFPage(nil)
        currentY = contentTop
    }

    func endPage() {
        drawFooter()
        context.endPDFPage()
        pageNumber += 1
    }

    func moveDown(_ delta: CGFloat) {
        currentY -= delta
    }

    func drawText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: CGRect
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    @discardableResult
    func drawWrappingText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: CGRect,
        lineSpacing: CGFloat
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return rect.height
    }

    @discardableResult
    func drawImage(_ cgImage: CGImage, maxWidth: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        var drawWidth = min(maxWidth, CGFloat(cgImage.width))
        var drawHeight = drawWidth / imageAspect
        if drawHeight > maxHeight {
            drawHeight = maxHeight
            drawWidth = drawHeight * imageAspect
        }

        let availableHeight = currentY - contentBottom
        if drawHeight > availableHeight {
            if availableHeight < 120 {
                endPage()
                beginPage()
                drawHeight = min(drawHeight, contentTop - contentBottom)
                drawWidth = drawHeight * imageAspect
            } else {
                drawHeight = availableHeight
                drawWidth = drawHeight * imageAspect
            }
        }

        let drawRect = CGRect(x: margin, y: currentY - drawHeight, width: drawWidth, height: drawHeight)
        context.interpolationQuality = .high
        context.draw(cgImage, in: drawRect)
        currentY -= drawHeight
        return drawHeight
    }

    private func drawFooter() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateText = formatter.string(from: exportDate)

        let left = "VideoNotes · \(dateText)"
        let right = totalPages.map { "\(pageNumber) / \($0)" } ?? "\(pageNumber)"
        let footerY: CGFloat = 34

        drawText(
            left,
            font: .systemFont(ofSize: 10, weight: .regular),
            color: NSColor(calibratedWhite: 0.45, alpha: 1),
            in: CGRect(x: margin, y: footerY, width: 200, height: 14)
        )
        drawText(
            right,
            font: .systemFont(ofSize: 10, weight: .medium),
            color: NSColor(calibratedWhite: 0.45, alpha: 1),
            in: CGRect(x: pageRect.width - margin - 100, y: footerY, width: 100, height: 14)
        )
    }
}
