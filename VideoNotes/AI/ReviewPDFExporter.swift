import AppKit
import Foundation

// MARK: - Codex review PDF exporter

/// Renders the structured Markdown returned by local Codex into a searchable,
/// A4 learning note. The renderer is deliberately small and dependency-free:
/// Markdown is parsed into learning-oriented blocks instead of being painted
/// as one long stream of text.
final class ReviewPDFExporter {

    enum ExportError: LocalizedError {
        case emptyReview
        case cannotCreatePDF

        var errorDescription: String? {
            switch self {
            case .emptyReview:
                return "复盘内容为空，无法生成 PDF"
            case .cannotCreatePDF:
                return "无法创建复盘 PDF，请检查默认复盘目录是否可写"
            }
        }
    }

    private static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 44
    private static let contentWidth: CGFloat = 595 - 44 * 2
    private static let contentBottom: CGFloat = 54
    private static let contentTop: CGFloat = 842 - 44

    // One restrained palette: blue-gray is the document identity, while the
    // semantic colors are reserved for mistakes and pending checks.
    private static let ink = NSColor(calibratedRed: 0.10, green: 0.15, blue: 0.20, alpha: 1)
    private static let body = NSColor(calibratedRed: 0.18, green: 0.23, blue: 0.28, alpha: 1)
    private static let muted = NSColor(calibratedRed: 0.42, green: 0.48, blue: 0.53, alpha: 1)
    private static let accent = NSColor(calibratedRed: 0.15, green: 0.39, blue: 0.48, alpha: 1)
    private static let accentLight = NSColor(calibratedRed: 0.91, green: 0.95, blue: 0.96, alpha: 1)
    private static let rule = NSColor(calibratedRed: 0.82, green: 0.86, blue: 0.88, alpha: 1)
    private static let error = NSColor(calibratedRed: 0.72, green: 0.22, blue: 0.18, alpha: 1)
    private static let errorLight = NSColor(calibratedRed: 0.99, green: 0.94, blue: 0.93, alpha: 1)
    private static let pending = NSColor(calibratedRed: 0.33, green: 0.29, blue: 0.58, alpha: 1)
    private static let pendingLight = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.99, alpha: 1)
    private static let neutralLight = NSColor(calibratedWhite: 0.965, alpha: 1)

    func export(
        markdown: String,
        title: String,
        noteCount: Int,
        generatedAt: Date = Date(),
        to url: URL
    ) throws {
        let blocks = parse(markdown: markdown)
        guard !blocks.isEmpty else { throw ExportError.emptyReview }

        let documentTitle = blocks.compactMap { block -> String? in
            guard case .heading(let level, let text) = block, level == 1 else { return nil }
            return text
        }.first ?? title

        var mediaBox = Self.pageRect
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ExportError.cannotCreatePDF
        }

        let page = ReviewPDFPage(
            context: context,
            pageRect: Self.pageRect,
            margin: Self.margin,
            contentBottom: Self.contentBottom,
            contentTop: Self.contentTop
        )
        page.beginPage()
        drawHeader(
            title: documentTitle,
            noteCount: noteCount,
            generatedAt: generatedAt,
            on: page
        )

        var skippedDocumentTitle = false
        var isQuickReview = false
        for block in blocks {
            if case .heading(let level, _) = block,
               level == 1,
               !skippedDocumentTitle {
                // The document title is already displayed in the cover
                // header. Keeping it in Markdown still makes copied text
                // complete, while avoiding a duplicate visual title.
                skippedDocumentTitle = true
                continue
            }

            if case .heading(let level, let text) = block,
               level == 2,
               text.contains("1. 高等数学"),
               isQuickReview {
                // Keep the dashboard-like first page focused on the quick
                // review. The learning body starts on a clean A4 page.
                if page.hasDrawnContent {
                    page.startNewPage()
                }
                isQuickReview = false
            }
            if case .heading(let level, let text) = block,
               level == 2,
               text.contains("0. 一页速览") {
                isQuickReview = true
            }
            draw(block: block, on: page, compact: isQuickReview)
        }

        page.endPage()
        context.closePDF()
    }

    // MARK: - Structured Markdown

    private enum CalloutKind {
        case error
        case pending
        case note

        var tint: NSColor {
            switch self {
            case .error: return ReviewPDFExporter.error
            case .pending: return ReviewPDFExporter.pending
            case .note: return ReviewPDFExporter.accent
            }
        }

        var background: NSColor {
            switch self {
            case .error: return ReviewPDFExporter.errorLight
            case .pending: return ReviewPDFExporter.pendingLight
            case .note: return ReviewPDFExporter.accentLight
            }
        }
    }

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(level: Int, text: String, ordered: Bool, number: Int?)
        case table(headers: [String], rows: [[String]])
        case callout(kind: CalloutKind, title: String, lines: [String])
        case diagram(lines: [String])
        case flow(String)
        case formula(String)
        case separator
        case spacer

        var isSpacer: Bool {
            if case .spacer = self { return true }
            return false
        }
    }

    private func parse(markdown: String) -> [Block] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                if blocks.last?.isSpacer != true {
                    blocks.append(.spacer)
                }
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                index += 1
                var diagramLines: [String] = []
                while index < lines.count {
                    let codeLine = lines[index]
                    if codeLine.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                        index += 1
                        break
                    }
                    diagramLines.append(codeLine)
                    index += 1
                }
                if !diagramLines.isEmpty {
                    blocks.append(.diagram(lines: diagramLines))
                }
                continue
            }

            if let heading = heading(from: line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isHorizontalRule(line) {
                blocks.append(.separator)
                index += 1
                continue
            }

            if let table = table(from: lines, startingAt: index) {
                blocks.append(.table(headers: table.headers, rows: table.rows))
                index = table.nextIndex
                continue
            }

            if isErrorStart(line) || isPendingStart(line) {
                let kind: CalloutKind = isErrorStart(line) ? .error : .pending
                let collected = collectCallout(lines: lines, startingAt: index)
                blocks.append(.callout(kind: kind, title: collected.title, lines: collected.lines))
                index = collected.nextIndex
                continue
            }

            if let bullet = bullet(from: rawLine) {
                blocks.append(
                    .bullet(
                        level: bullet.level,
                        text: bullet.text,
                        ordered: bullet.ordered,
                        number: bullet.number
                    )
                )
                index += 1
                continue
            }

            if isTreeLine(line) {
                var diagramLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty, isTreeLine(candidate) else { break }
                    diagramLines.append(lines[index])
                    index += 1
                }
                if diagramLines.count >= 2 {
                    blocks.append(.diagram(lines: diagramLines))
                } else if let onlyLine = diagramLines.first {
                    blocks.append(.flow(onlyLine))
                }
                continue
            }

            if isFormulaLine(line) {
                blocks.append(.formula(cleanInlineMarkdown(line)))
                index += 1
                continue
            }

            if line.contains("→") && line.count <= 150 {
                blocks.append(.flow(cleanInlineMarkdown(line)))
                index += 1
                continue
            }

            var paragraphLines = [rawLine]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !next.isEmpty,
                      heading(from: next) == nil,
                      !isHorizontalRule(next),
                      table(from: lines, startingAt: index) == nil,
                      !isErrorStart(next),
                      !isPendingStart(next),
                      bullet(from: lines[index]) == nil,
                      !isTreeLine(next),
                      !isFormulaLine(next),
                      !(next.contains("→") && next.count <= 150),
                      !next.hasPrefix("```") else {
                    break
                }
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        while blocks.first?.isSpacer == true {
            blocks.removeFirst()
        }
        while blocks.last?.isSpacer == true {
            blocks.removeLast()
        }
        return blocks
    }

    private func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes),
              line.dropFirst(hashes).first == " " else {
            return nil
        }
        let text = line
            .dropFirst(hashes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (hashes, cleanInlineMarkdown(text))
    }

    private func table(
        from lines: [String],
        startingAt index: Int
    ) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headerCells = splitTableRow(lines[index])
        let dividerCells = splitTableRow(lines[index + 1])
        guard headerCells.count >= 2,
              dividerCells.count == headerCells.count,
              dividerCells.allSatisfy(isTableDividerCell) else {
            return nil
        }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count {
            let line = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { break }
            let cells = splitTableRow(line)
            guard cells.count == headerCells.count else { break }
            rows.append(cells.map(cleanInlineMarkdown))
            nextIndex += 1
        }
        return (
            headerCells.map(cleanInlineMarkdown),
            rows,
            nextIndex
        )
    }

    private func splitTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator: String = trimmed.contains("|") ? "|" : "｜"
        guard trimmed.contains(separator) else { return [] }
        var value = trimmed
        if value.hasPrefix(separator) { value.removeFirst() }
        if value.hasSuffix(separator) { value.removeLast() }
        return value
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func isTableDividerCell(_ cell: String) -> Bool {
        let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
        let hyphens = value.filter { $0 == "-" }.count
        return hyphens >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }

    private func bullet(from rawLine: String) -> (level: Int, text: String, ordered: Bool, number: Int?)? {
        let indentation = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let level = min(3, indentation / 2)
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return (
                level,
                cleanInlineMarkdown(String(line.dropFirst(marker.count))),
                false,
                nil
            )
        }

        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let numberText = String(line[..<dotIndex])
        guard !numberText.isEmpty, numberText.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dotIndex)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (
            level,
            cleanInlineMarkdown(String(line[line.index(after: afterDot)...])),
            true,
            Int(numberText)
        )
    }

    private func collectCallout(
        lines: [String],
        startingAt index: Int
    ) -> (title: String, lines: [String], nextIndex: Int) {
        let first = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        var title = cleanInlineMarkdown(first)
        var body: [String] = []
        var cursor = index + 1

        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty {
                break
            }
            if heading(from: candidate) != nil
                || isErrorStart(candidate)
                || isPendingStart(candidate)
                || bullet(from: lines[cursor]) != nil {
                break
            }
            body.append(cleanInlineMarkdown(lines[cursor]))
            cursor += 1
        }

        if title.isEmpty {
            title = "待确认"
        }
        return (title, body, cursor)
    }

    private func isErrorStart(_ line: String) -> Bool {
        line.hasPrefix("⚠") || line.hasPrefix("错误 ") || line.hasPrefix("错误：")
    }

    private func isPendingStart(_ line: String) -> Bool {
        line.hasPrefix("？")
            || line.hasPrefix("?")
            || line.hasPrefix("【待确认】")
            || line.hasPrefix("【需要回看原视频确认】")
    }

    private func isTreeLine(_ line: String) -> Bool {
        line.contains("↓")
            || line.contains("├")
            || line.contains("└")
            || line.contains("↙")
            || line.contains("↘")
            || line.contains("│")
    }

    private func isFormulaLine(_ line: String) -> Bool {
        guard line.count <= 100 else { return false }
        let hasFormulaSignal = line.contains("=")
            || line.contains("ΔU")
            || line.contains("ΔH")
            || line.contains("pV")
            || line.contains("f'")
            || line.contains("f''")
        let hasSentencePunctuation = line.contains("。")
            || line.contains("，")
            || line.contains("：")
            || line.contains("；")
        return hasFormulaSignal && !hasSentencePunctuation
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact == "---"
            || compact == "***"
            || compact == "___"
            || (compact.allSatisfy { $0 == "━" || $0 == "-" || $0 == "—" } && compact.count >= 5)
    }

    private func cleanInlineMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Drawing

    private func drawHeader(
        title: String,
        noteCount: Int,
        generatedAt: Date,
        on page: ReviewPDFPage
    ) {
        let accentRect = CGRect(
            x: Self.margin,
            y: page.currentY - 4,
            width: 46,
            height: 4
        )
        page.context.setFillColor(Self.accent.cgColor)
        page.context.fill(accentRect)
        page.moveDown(15)

        page.drawText(
            "VIDEONOTES  ·  LOCAL CODEX",
            font: .systemFont(ofSize: 9.5, weight: .semibold),
            color: Self.muted,
            in: CGRect(x: Self.margin, y: page.currentY - 14, width: Self.contentWidth, height: 14)
        )
        page.moveDown(18)

        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let titleHeight = height(for: title, font: titleFont, width: Self.contentWidth, lineSpacing: 4)
        page.drawWrappingText(
            title,
            font: titleFont,
            color: Self.ink,
            in: CGRect(x: Self.margin, y: page.currentY - titleHeight, width: Self.contentWidth, height: titleHeight),
            lineSpacing: 4
        )
        page.moveDown(titleHeight + 6)

        let time = generatedAt.formatted(
            .dateTime.year().month().day().hour().minute()
        )
        page.drawText(
            "基于 \(noteCount) 条笔记  ·  生成于 \(time)",
            font: .systemFont(ofSize: 10.5, weight: .regular),
            color: Self.muted,
            in: CGRect(x: Self.margin, y: page.currentY - 16, width: Self.contentWidth, height: 16)
        )
        page.moveDown(16 + 15)

        page.context.setFillColor(Self.rule.cgColor)
        page.context.fill(CGRect(x: Self.margin, y: page.currentY - 1, width: Self.contentWidth, height: 1))
        page.moveDown(17)
    }

    private func draw(block: Block, on page: ReviewPDFPage, compact: Bool = false) {
        if compact {
            drawCompact(block: block, on: page)
            return
        }

        switch block {
        case .spacer:
            page.ensureSpace(9)
            page.moveDown(9)

        case .separator:
            page.ensureSpace(17)
            page.context.setFillColor(Self.rule.cgColor)
            page.context.fill(CGRect(x: Self.margin, y: page.currentY - 1, width: Self.contentWidth, height: 1))
            page.moveDown(17)

        case .heading(let level, let text):
            drawHeading(level: level, text: text, on: page)

        case .paragraph(let text):
            let font = NSFont.systemFont(ofSize: 11.2, weight: .regular)
            let textHeight = height(for: text, font: font, width: Self.contentWidth, lineSpacing: 3.2)
            let blockHeight = textHeight + 6
            page.ensureSpace(blockHeight)
            page.drawWrappingText(
                text,
                font: font,
                color: Self.body,
                in: CGRect(x: Self.margin, y: page.currentY - textHeight, width: Self.contentWidth, height: textHeight),
                lineSpacing: 3.2
            )
            page.moveDown(blockHeight)

        case .bullet(let level, let text, let ordered, let number):
            drawBullet(
                level: level,
                text: text,
                ordered: ordered,
                number: number,
                on: page
            )

        case .formula(let text):
            drawFormula(text, on: page)

        case .flow(let text):
            drawFlow(text, on: page)

        case .diagram(let lines):
            drawDiagram(lines, on: page)

        case .callout(let kind, let title, let lines):
            drawCallout(kind: kind, title: title, lines: lines, on: page)

        case .table(let headers, let rows):
            drawTable(headers: headers, rows: rows, on: page)
        }
    }

    private func drawCompact(block: Block, on page: ReviewPDFPage) {
        switch block {
        case .spacer:
            page.ensureSpace(3)
            page.moveDown(3)

        case .heading(let level, let text):
            let font = NSFont.systemFont(ofSize: level >= 3 ? 12.3 : 14.8, weight: .semibold)
            let textHeight = height(
                for: text,
                font: font,
                width: Self.contentWidth - (level == 2 ? 10 : 0),
                lineSpacing: 1.5
            )
            let topGap: CGFloat = level >= 3 ? 3 : 7
            let bottomGap: CGFloat = level >= 3 ? 3 : 6
            let blockHeight = topGap + textHeight + bottomGap
            page.ensureSpace(blockHeight)
            page.moveDown(topGap)
            if level == 2 {
                page.context.setFillColor(Self.accent.cgColor)
                page.context.fill(
                    CGRect(x: Self.margin, y: page.currentY - textHeight - 1, width: 3, height: textHeight + 2)
                )
            }
            page.drawWrappingText(
                text,
                font: font,
                color: level == 2 ? Self.ink : Self.accent,
                in: CGRect(
                    x: Self.margin + (level == 2 ? 10 : 0),
                    y: page.currentY - textHeight,
                    width: Self.contentWidth - (level == 2 ? 10 : 0),
                    height: textHeight
                ),
                lineSpacing: 1.5
            )
            page.moveDown(textHeight + bottomGap)

        case .bullet(let level, let text, let ordered, let number):
            let inset = CGFloat(min(level, 3)) * 12
            let markerWidth: CGFloat = ordered ? 18 : 10
            let font = NSFont.systemFont(ofSize: 10.2, weight: .regular)
            let textWidth = Self.contentWidth - inset - markerWidth
            let textHeight = height(for: text, font: font, width: textWidth, lineSpacing: 1.4)
            let blockHeight = max(14, textHeight) + 1
            page.ensureSpace(blockHeight)
            let markerX = Self.margin + inset
            if ordered {
                page.drawText(
                    "\(number ?? 1).",
                    font: .systemFont(ofSize: 9.3, weight: .semibold),
                    color: Self.accent,
                    in: CGRect(x: markerX, y: page.currentY - 13, width: markerWidth, height: 13)
                )
            } else {
                page.context.setFillColor(Self.accent.cgColor)
                page.context.fillEllipse(in: CGRect(x: markerX + 2, y: page.currentY - 8, width: 3.5, height: 3.5))
            }
            page.drawWrappingText(
                text,
                font: font,
                color: Self.body,
                in: CGRect(
                    x: markerX + markerWidth,
                    y: page.currentY - textHeight,
                    width: textWidth,
                    height: textHeight
                ),
                lineSpacing: 1.4
            )
            page.moveDown(blockHeight)

        case .paragraph(let text):
            let font = NSFont.systemFont(ofSize: 10.2, weight: .regular)
            let textHeight = height(for: text, font: font, width: Self.contentWidth, lineSpacing: 1.5)
            let blockHeight = textHeight + 2
            page.ensureSpace(blockHeight)
            page.drawWrappingText(
                text,
                font: font,
                color: Self.body,
                in: CGRect(x: Self.margin, y: page.currentY - textHeight, width: Self.contentWidth, height: textHeight),
                lineSpacing: 1.5
            )
            page.moveDown(blockHeight)

        default:
            draw(block: block, on: page)
        }
    }

    private func drawHeading(level: Int, text: String, on page: ReviewPDFPage) {
        let normalizedLevel = min(max(level, 1), 4)
        let fontSize: CGFloat
        let weight: NSFont.Weight
        let color: NSColor
        let topGap: CGFloat
        let bottomGap: CGFloat

        switch normalizedLevel {
        case 1:
            fontSize = 20
            weight = .bold
            color = Self.ink
            topGap = 9
            bottomGap = 10
        case 2:
            fontSize = 16
            weight = .bold
            color = Self.ink
            topGap = 13
            bottomGap = 10
        case 3:
            fontSize = 13.8
            weight = .semibold
            color = Self.accent
            topGap = 8
            bottomGap = 7
        default:
            fontSize = 11.8
            weight = .semibold
            color = Self.body
            topGap = 6
            bottomGap = 5
        }

        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let textWidth = Self.contentWidth - (normalizedLevel == 2 ? 12 : 0)
        let textHeight = height(for: text, font: font, width: textWidth, lineSpacing: 2)
        let blockHeight = topGap + textHeight + bottomGap
        page.ensureSpace(blockHeight)
        page.moveDown(topGap)

        if normalizedLevel == 2 {
            page.context.setFillColor(Self.accent.cgColor)
            page.context.fill(
                CGRect(x: Self.margin, y: page.currentY - textHeight - 1, width: 3, height: textHeight + 2)
            )
        }

        page.drawWrappingText(
            text,
            font: font,
            color: color,
            in: CGRect(
                x: Self.margin + (normalizedLevel == 2 ? 12 : 0),
                y: page.currentY - textHeight,
                width: textWidth,
                height: textHeight
            ),
            lineSpacing: 2
        )
        page.moveDown(textHeight + bottomGap)
    }

    private func drawBullet(
        level: Int,
        text: String,
        ordered: Bool,
        number: Int?,
        on page: ReviewPDFPage
    ) {
        let inset = CGFloat(min(level, 3)) * 16
        let markerWidth: CGFloat = ordered ? 20 : 12
        let font = NSFont.systemFont(ofSize: 11.1, weight: .regular)
        let textWidth = Self.contentWidth - inset - markerWidth
        let textHeight = height(for: text, font: font, width: textWidth, lineSpacing: 2.8)
        let blockHeight = max(17, textHeight) + 4
        page.ensureSpace(blockHeight)

        let markerX = Self.margin + inset
        if ordered {
            page.drawText(
                "\(number ?? 1).",
                font: .systemFont(ofSize: 10.2, weight: .semibold),
                color: Self.accent,
                in: CGRect(x: markerX, y: page.currentY - 15, width: markerWidth, height: 15)
            )
        } else {
            page.context.setFillColor(Self.accent.cgColor)
            page.context.fillEllipse(in: CGRect(x: markerX + 3, y: page.currentY - 9, width: 4, height: 4))
        }

        page.drawWrappingText(
            text,
            font: font,
            color: Self.body,
            in: CGRect(
                x: markerX + markerWidth,
                y: page.currentY - textHeight,
                width: textWidth,
                height: textHeight
            ),
            lineSpacing: 2.8
        )
        page.moveDown(blockHeight)
    }

    private func drawFormula(_ text: String, on page: ReviewPDFPage) {
        let fontSize: CGFloat = text.count > 58 ? 12.5 : 15
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textWidth = Self.contentWidth - 28
        let textHeight = height(for: text, font: font, width: textWidth, lineSpacing: 2)
        let blockHeight = textHeight + 18
        page.ensureSpace(blockHeight)

        let rect = CGRect(
            x: Self.margin,
            y: page.currentY - blockHeight,
            width: Self.contentWidth,
            height: blockHeight
        )
        fillRounded(rect, color: Self.accentLight, on: page)
        page.context.setFillColor(Self.accent.cgColor)
        page.context.fill(CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height))

        page.drawWrappingText(
            text,
            font: font,
            color: Self.accent,
            in: CGRect(x: rect.minX + 16, y: rect.minY + 9, width: textWidth, height: textHeight),
            lineSpacing: 2
        )
        page.moveDown(blockHeight + 6)
    }

    private func drawFlow(_ text: String, on page: ReviewPDFPage) {
        let font = NSFont.systemFont(ofSize: 11.1, weight: .semibold)
        let textWidth = Self.contentWidth - 24
        let textHeight = height(for: text, font: font, width: textWidth, lineSpacing: 2.5)
        let blockHeight = textHeight + 16
        page.ensureSpace(blockHeight)

        let rect = CGRect(
            x: Self.margin,
            y: page.currentY - blockHeight,
            width: Self.contentWidth,
            height: blockHeight
        )
        fillRounded(rect, color: Self.neutralLight, on: page)
        page.context.setStrokeColor(Self.rule.cgColor)
        page.context.setLineWidth(0.8)
        page.context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        page.drawWrappingText(
            text,
            font: font,
            color: Self.body,
            in: CGRect(x: rect.minX + 12, y: rect.minY + 8, width: textWidth, height: textHeight),
            lineSpacing: 2.5
        )
        page.moveDown(blockHeight + 5)
    }

    private func drawDiagram(_ lines: [String], on page: ReviewPDFPage) {
        let text = lines.map(cleanInlineMarkdown).joined(separator: "\n")
        let font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let textWidth = Self.contentWidth - 28
        let measuredTextHeight = height(for: text, font: font, width: textWidth, lineSpacing: 2.4)
        // AppKit's boundingRect can under-measure a mixed CJK/box-drawing
        // block by part of a line. Keep a full-line safety allowance so the
        // final branch is never painted underneath the rounded container.
        let textHeight = measuredTextHeight + 14
        // Do not cap the diagram height: a capped box would clip the last
        // branch of a longer decision tree. ensureSpace handles a page break
        // before the complete diagram when necessary.
        let blockHeight = max(textHeight + 20, 38)
        page.ensureSpace(blockHeight)

        let rect = CGRect(
            x: Self.margin,
            y: page.currentY - blockHeight,
            width: Self.contentWidth,
            height: blockHeight
        )
        fillRounded(rect, color: Self.neutralLight, on: page)
        page.context.setStrokeColor(Self.rule.cgColor)
        page.context.setLineWidth(0.8)
        page.context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        page.drawWrappingText(
            text,
            font: font,
            color: Self.body,
            in: CGRect(x: rect.minX + 14, y: rect.minY + 10, width: textWidth, height: textHeight),
            lineSpacing: 2.4
        )
        page.moveDown(blockHeight + 7)
    }

    private func drawCallout(
        kind: CalloutKind,
        title: String,
        lines: [String],
        on page: ReviewPDFPage
    ) {
        let titleFont = NSFont.systemFont(ofSize: 11.8, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 10.7, weight: .regular)
        let textWidth = Self.contentWidth - 38
        let titleHeight = height(for: title, font: titleFont, width: textWidth, lineSpacing: 2)
        let bodyText = lines.joined(separator: "\n")
        let bodyHeight = bodyText.isEmpty
            ? 0
            : height(for: bodyText, font: bodyFont, width: textWidth, lineSpacing: 2.4)
        let blockHeight = titleHeight + bodyHeight + (bodyText.isEmpty ? 20 : 30)
        page.ensureSpace(blockHeight)

        let rect = CGRect(
            x: Self.margin,
            y: page.currentY - blockHeight,
            width: Self.contentWidth,
            height: blockHeight
        )
        fillRounded(rect, color: kind.background, on: page)
        page.context.setFillColor(kind.tint.cgColor)
        page.context.fill(CGRect(x: rect.minX, y: rect.minY, width: 4, height: rect.height))

        page.drawWrappingText(
            title,
            font: titleFont,
            color: kind.tint,
            in: CGRect(x: rect.minX + 15, y: rect.maxY - 12 - titleHeight, width: textWidth, height: titleHeight),
            lineSpacing: 2
        )
        if !bodyText.isEmpty {
            page.drawWrappingText(
                bodyText,
                font: bodyFont,
                color: Self.body,
                in: CGRect(x: rect.minX + 15, y: rect.minY + 10, width: textWidth, height: bodyHeight),
                lineSpacing: 2.4
            )
        }
        page.moveDown(blockHeight + 8)
    }

    private func drawTable(headers: [String], rows: [[String]], on page: ReviewPDFPage) {
        let columnCount = headers.count
        guard columnCount > 0 else { return }

        let tableFont = NSFont.systemFont(ofSize: columnCount >= 8 ? 7.7 : 8.6, weight: .regular)
        let headerFont = NSFont.systemFont(ofSize: columnCount >= 8 ? 7.8 : 8.7, weight: .semibold)
        let widths = tableColumnWidths(
            headers: headers,
            rows: rows,
            font: tableFont,
            availableWidth: Self.contentWidth
        )

        if page.currentY - tableRowHeight(headers, widths: widths, font: headerFont) < Self.contentBottom {
            page.startNewPage()
        }
        drawTableRow(
            headers,
            widths: widths,
            font: headerFont,
            background: Self.accent,
            textColor: NSColor.white,
            on: page
        )

        for (index, row) in rows.enumerated() {
            let normalized = row + Array(repeating: "", count: max(0, columnCount - row.count))
            let clipped = Array(normalized.prefix(columnCount))
            let rowHeight = tableRowHeight(
                clipped,
                widths: widths,
                font: tableFont
            )
            if page.currentY - rowHeight < Self.contentBottom {
                page.startNewPage()
                drawTableRow(
                    headers,
                    widths: widths,
                    font: headerFont,
                    background: Self.accent,
                    textColor: NSColor.white,
                    on: page
                )
            }
            let background = index.isMultiple(of: 2) ? NSColor.white : Self.neutralLight
            drawTableRow(
                clipped,
                widths: widths,
                font: tableFont,
                background: background,
                textColor: Self.body,
                on: page
            )
        }
        page.moveDown(7)
    }

    private func drawTableRow(
        _ cells: [String],
        widths: [CGFloat],
        font: NSFont,
        background: NSColor,
        textColor: NSColor,
        on page: ReviewPDFPage
    ) {
        let padding: CGFloat = 4
        let lineSpacing: CGFloat = 1.5
        let heights = zip(cells, widths).map { cell, width in
            height(
                for: cell,
                font: font,
                width: max(12, width - padding * 2),
                lineSpacing: lineSpacing
            )
        }
        let rowHeight = max(18, (heights.max() ?? 18) + padding * 2)

        var x = Self.margin
        let rowRect = CGRect(
            x: Self.margin,
            y: page.currentY - rowHeight,
            width: Self.contentWidth,
            height: rowHeight
        )
        page.context.setFillColor(background.cgColor)
        page.context.fill(rowRect)

        page.context.setStrokeColor(Self.rule.cgColor)
        page.context.setLineWidth(0.55)
        page.context.stroke(rowRect.insetBy(dx: 0.25, dy: 0.25))

        for (index, cell) in cells.enumerated() {
            let width = widths[index]
            let cellHeight = heights[index]
            let cellRect = CGRect(
                x: x,
                y: page.currentY - rowHeight,
                width: width,
                height: rowHeight
            )
            page.context.stroke(cellRect.insetBy(dx: 0.25, dy: 0.25))
            page.drawWrappingText(
                cell,
                font: font,
                color: textColor,
                in: CGRect(
                    x: x + padding,
                    y: page.currentY - padding - cellHeight,
                    width: max(12, width - padding * 2),
                    height: cellHeight
                ),
                lineSpacing: lineSpacing
            )
            x += width
        }
        page.moveDown(rowHeight)
    }

    private func tableRowHeight(
        _ cells: [String],
        widths: [CGFloat],
        font: NSFont
    ) -> CGFloat {
        let padding: CGFloat = 4
        let lineSpacing: CGFloat = 1.5
        let heights = zip(cells, widths).map { cell, width in
            height(
                for: cell,
                font: font,
                width: max(12, width - padding * 2),
                lineSpacing: lineSpacing
            )
        }
        return max(18, (heights.max() ?? 18) + padding * 2)
    }

    private func tableColumnWidths(
        headers: [String],
        rows: [[String]],
        font: NSFont,
        availableWidth: CGFloat
    ) -> [CGFloat] {
        let columnCount = headers.count
        var preferred = headers.indices.map { columnIndex in
            let values = [headers[columnIndex]] + rows.compactMap { row in
                guard columnIndex < row.count else { return nil }
                return row[columnIndex]
            }
            let maxCharacters = min(
                13,
                values.map { $0.count }.max() ?? 4
            )
            return max(34, min(104, CGFloat(maxCharacters) * font.pointSize * 0.92 + 10))
        }

        let total = preferred.reduce(0, +)
        if total > availableWidth {
            let scale = availableWidth / total
            preferred = preferred.map { max(30, $0 * scale) }
        }

        let adjustedTotal = preferred.reduce(0, +)
        if adjustedTotal < availableWidth {
            let extra = (availableWidth - adjustedTotal) / CGFloat(columnCount)
            preferred = preferred.map { $0 + extra }
        } else if preferred.reduce(0, +) > availableWidth {
            let equal = availableWidth / CGFloat(columnCount)
            preferred = Array(repeating: equal, count: columnCount)
        }
        return preferred
    }

    private func fillRounded(_ rect: CGRect, color: NSColor, on page: ReviewPDFPage) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
        page.context.addPath(path)
        page.context.setFillColor(color.cgColor)
        page.context.fillPath()
    }

    private func height(
        for text: String,
        font: NSFont,
        width: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style
        ]
        let rect = NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(font.pointSize + lineSpacing, ceil(rect.height))
    }
}

// MARK: - PDF page state

private final class ReviewPDFPage {
    let context: CGContext
    private let pageRect: CGRect
    private let margin: CGFloat
    private let contentBottom: CGFloat
    private let contentTop: CGFloat
    private var pageNumber = 1
    var currentY: CGFloat
    private(set) var hasDrawnContent = false

    init(
        context: CGContext,
        pageRect: CGRect,
        margin: CGFloat,
        contentBottom: CGFloat,
        contentTop: CGFloat
    ) {
        self.context = context
        self.pageRect = pageRect
        self.margin = margin
        self.contentBottom = contentBottom
        self.contentTop = contentTop
        self.currentY = contentTop
    }

    func beginPage() {
        context.beginPDFPage(nil)
        currentY = contentTop
        hasDrawnContent = false
    }

    func endPage() {
        drawFooter()
        context.endPDFPage()
        pageNumber += 1
    }

    func startNewPage() {
        endPage()
        beginPage()
    }

    func ensureSpace(_ height: CGFloat) {
        guard currentY - height < contentBottom else { return }
        startNewPage()
    }

    func moveDown(_ delta: CGFloat) {
        currentY -= delta
        hasDrawnContent = true
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

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: attributes).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    func drawWrappingText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        in rect: CGRect,
        lineSpacing: CGFloat
    ) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawFooter() {
        drawText(
            "VideoNotes  ·  学习复盘",
            font: .systemFont(ofSize: 9.2, weight: .regular),
            color: NSColor(calibratedWhite: 0.48, alpha: 1),
            in: CGRect(x: margin, y: 30, width: 220, height: 13)
        )
        drawText(
            "\(pageNumber)",
            font: .systemFont(ofSize: 9.2, weight: .medium),
            color: NSColor(calibratedWhite: 0.48, alpha: 1),
            in: CGRect(x: pageRect.width - margin - 36, y: 30, width: 36, height: 13)
        )
    }
}
