import Foundation

/// A block of a Markdown reply, as the Playground shows it.
public enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case quote(String)
    case list([MarkdownListItem])
    case table(MarkdownTable)
    case rule
}

public struct MarkdownListItem: Hashable, Sendable {
    /// The number of an ordered item, `nil` for a bullet.
    public var number: Int?
    /// Nesting depth, from 0.
    public var level: Int
    public var text: String

    public init(number: Int?, level: Int, text: String) {
        self.number = number
        self.level = level
        self.text = text
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case leading
        case center
        case trailing
    }

    public var header: [String]
    public var alignments: [Alignment]
    /// Every row has as many cells as the header.
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// Splits the Markdown written by models into blocks: paragraphs, headings, fenced code,
/// quotes, lists, tables (GitHub style) and rules. Inline formatting (bold, italic, code,
/// links) stays in the text, for `AttributedString(markdown:)`.
///
/// Replies are parsed while they stream: an unterminated code fence runs to the end.
public enum MarkdownParser {
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = fence(trimmed) {
                flushParagraph()
                let indent = line.prefix { $0 == " " }.count
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let codeLine = lines[index]
                    index += 1
                    if isClosingFence(codeLine.trimmingCharacters(in: .whitespaces), opening: fence) { break }
                    // Code under an indented fence (inside a list item) loses that indentation.
                    code.append(String(codeLine.dropFirst(min(indent, codeLine.prefix { $0 == " " }.count))))
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // A table: a row of cells, then a delimiter row with as many cells. List items and
            // quotes that contain a pipe stay what they are.
            if trimmed.contains("|"), !trimmed.hasPrefix(">"), listMarker(line) == nil,
               index + 1 < lines.count, let alignments = delimiterRow(lines[index + 1]),
               alignments.count == cells(trimmed).count
            {
                flushParagraph()
                let header = cells(trimmed)
                let columns = header.count
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(padded(cells(row), to: columns))
                    index += 1
                }
                blocks.append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    var rest = quoteLine.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                continue
            }

            if listMarker(line) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                var indents: [Int] = []
                while index < lines.count {
                    let itemLine = lines[index]
                    if let marker = listMarker(itemLine) {
                        while let last = indents.last, last > marker.indent { indents.removeLast() }
                        if indents.last.map({ marker.indent > $0 }) ?? true { indents.append(marker.indent) }
                        items.append(MarkdownListItem(number: marker.number, level: indents.count - 1, text: marker.text))
                        index += 1
                        continue
                    }
                    let rest = itemLine.trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty {
                        // A blank line between two items keeps the list going.
                        if index + 1 < lines.count, listMarker(lines[index + 1]) != nil {
                            index += 1
                            continue
                        }
                        break
                    }
                    // An indented line continues the previous item (a fence starts a code block).
                    guard itemLine.first == " " || itemLine.first == "\t", fence(rest) == nil else { break }
                    items[items.count - 1].text += "\n" + rest
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Lines

    /// The opening fence (three or more backticks or tildes), if the line is one.
    private static func fence(_ trimmed: String) -> String? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let marker = trimmed.prefix { $0 == first }
        guard marker.count >= 3 else { return nil }
        // A backtick fence can't have backticks in its info string.
        if first == "`", trimmed.dropFirst(marker.count).contains("`") { return nil }
        return String(marker)
    }

    private static func isClosingFence(_ trimmed: String, opening: String) -> Bool {
        guard let first = opening.first else { return false }
        let marker = trimmed.prefix { $0 == first }
        return marker.count >= opening.count && trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace)
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: `## Title ##`.
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) {
            text.removeSubrange(closing)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return .heading(level: hashes.count, text: text)
    }

    /// `---`, `***` or `___`, spaces allowed.
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func listMarker(_ line: String) -> (indent: Int, number: Int?, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(leading.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // `- - -` is a rule, not a list.
            if isRule(String(rest)) { return nil }
            return (indent, nil, text)
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return (indent, Int(digits), after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    // MARK: Tables

    /// Alignments of a table's delimiter row (`| --- | :---: | ---: |`), or `nil`.
    private static func delimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for part in parts {
            let dashes = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Cells of a table row: outer pipes are optional, `\|` is a literal pipe.
    private static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func padded(_ cells: [String], to count: Int) -> [String] {
        Array((cells + Array(repeating: "", count: max(0, count - cells.count))).prefix(count))
    }
}
