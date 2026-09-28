import Testing
@testable import OllamaKit

@Suite("Markdown blocks")
struct MarkdownTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = MarkdownParser.blocks("# Title ##\nSome **bold** text\non two lines.\n\n---\n### Sub")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\non two lines."),
            .rule,
            .heading(level: 3, text: "Sub"),
        ])
        // Not headings: no space after the hashes, or more than six.
        #expect(MarkdownParser.blocks("#hashtag") == [.paragraph("#hashtag")])
        #expect(MarkdownParser.blocks("####### seven") == [.paragraph("####### seven")])
    }

    @Test func fencedCode() {
        let blocks = MarkdownParser.blocks("Run:\n```bash\nls -l\n\necho ok\n```\nDone.")
        #expect(blocks == [.paragraph("Run:"), .code(language: "bash", text: "ls -l\n\necho ok"), .paragraph("Done.")])
        // While a reply streams, an open fence runs to the end.
        #expect(MarkdownParser.blocks("```\nlet x = 1") == [.code(language: nil, text: "let x = 1")])
        // A shorter fence doesn't close a longer one; tildes work too.
        #expect(MarkdownParser.blocks("````\n```\n````") == [.code(language: nil, text: "```")])
        #expect(MarkdownParser.blocks("~~~\na\n~~~") == [.code(language: nil, text: "a")])
    }

    @Test func listsWithNestingAndContinuation() {
        let blocks = MarkdownParser.blocks("1. First\n   more text\n2. Second\n   - nested\n     - deeper\n\n3) Third\n* bullet")
        #expect(blocks == [.list([
            MarkdownListItem(number: 1, level: 0, text: "First\nmore text"),
            MarkdownListItem(number: 2, level: 0, text: "Second"),
            MarkdownListItem(number: nil, level: 1, text: "nested"),
            MarkdownListItem(number: nil, level: 2, text: "deeper"),
            MarkdownListItem(number: 3, level: 0, text: "Third"),
            MarkdownListItem(number: nil, level: 0, text: "bullet"),
        ])])
        // `- - -` and `* * *` are rules.
        #expect(MarkdownParser.blocks("- - -") == [.rule])
        #expect(MarkdownParser.blocks("* * *") == [.rule])
    }

    @Test func codeInsideAListItem() {
        let blocks = MarkdownParser.blocks("1. Install:\n   ```sh\n   brew install ollama\n   ```\n2. Run it")
        #expect(blocks == [
            .list([MarkdownListItem(number: 1, level: 0, text: "Install:")]),
            .code(language: "sh", text: "brew install ollama"),
            .list([MarkdownListItem(number: 2, level: 0, text: "Run it")]),
        ])
    }

    @Test func tables() {
        let blocks = MarkdownParser.blocks("| Model | Size | Speed |\n|:---|:---:|---:|\n| `gemma3` | 4B | 60 t/s |\n| a \\| b | 8B\n\nAfter")
        #expect(blocks == [
            .table(MarkdownTable(
                header: ["Model", "Size", "Speed"],
                alignments: [.leading, .center, .trailing],
                rows: [["`gemma3`", "4B", "60 t/s"], ["a | b", "8B", ""]]
            )),
            .paragraph("After"),
        ])
        // A paragraph with a pipe above a rule is not a table, nor is a list item.
        #expect(MarkdownParser.blocks("a | b\n---") == [.paragraph("a | b"), .rule])
        #expect(MarkdownParser.blocks("- npm | pnpm\n--- | ---") == [
            .list([MarkdownListItem(number: nil, level: 0, text: "npm | pnpm")]),
            .paragraph("--- | ---"),
        ])
    }

    @Test func quotes() {
        let blocks = MarkdownParser.blocks("> Quoted\n> *text*\n\nNext")
        #expect(blocks == [.quote("Quoted\n*text*"), .paragraph("Next")])
    }
}
