//! Turns model replies into what the interface can show.
//!
//! Slint's styled text supports paragraphs, lists, emphasis, links and inline
//! code, and rejects everything else. Code blocks and tables therefore become
//! separate monospace blocks, and other syntax is simplified before parsing.

use std::sync::LazyLock;

use regex::Regex;

#[derive(Debug, Clone, PartialEq)]
pub enum Part {
    /// Markdown limited to what `slint::StyledText::from_markdown` accepts.
    Text(String),
    Code {
        language: String,
        text: String,
    },
}

/// Splits a reply into text and code blocks. Works on partial replies too: an
/// unterminated code fence runs to the end.
pub fn split(markdown: &str) -> Vec<Part> {
    let mut parts = Vec::new();
    let mut text = String::new();
    let lines: Vec<&str> = markdown.lines().collect();
    // Models often wrap a whole reply in a ```markdown fence: show its content as text.
    // Only a plain fence on the first line counts; elsewhere it is an example to show as is.
    let first_line = lines.iter().position(|line| !line.trim().is_empty());
    let mut markdown_wrapper = false;
    let mut index = 0;
    while index < lines.len() {
        let line = lines[index];
        if let Some((marker, language)) = opening_fence(line) {
            if Some(index) == first_line && marker.len() == 3 && matches!(language.to_lowercase().as_str(), "markdown" | "md") {
                markdown_wrapper = true;
                index += 1;
                continue;
            }
            if markdown_wrapper && language.is_empty() && is_closing_fence(line, &marker) {
                // Closes the wrapper.
                markdown_wrapper = false;
                index += 1;
                continue;
            }
            flush_text(&mut parts, &mut text);
            // Fences inside list items are indented: remove that indentation from the code.
            let indent = line.len() - line.trim_start().len();
            let mut code = Vec::new();
            index += 1;
            while index < lines.len() && !is_closing_fence(lines[index], &marker) {
                let code_line = lines[index];
                let removable = code_line.len() - code_line.trim_start_matches(' ').len();
                code.push(&code_line[removable.min(indent)..]);
                index += 1;
            }
            index += 1;
            let code = code.join("\n");
            // A fence that just opened while streaming has nothing to show yet.
            if !code.trim().is_empty() {
                parts.push(Part::Code { language, text: code });
            }
            continue;
        }
        if is_table_row(line) && lines.get(index + 1).is_some_and(|next| is_table_separator(next)) {
            flush_text(&mut parts, &mut text);
            let start = index;
            while index < lines.len() && is_table_row(lines[index]) {
                index += 1;
            }
            parts.push(Part::Code { language: String::new(), text: format_table(&lines[start..index]) });
            continue;
        }
        text.push_str(&simplify_line(line));
        text.push('\n');
        index += 1;
    }
    flush_text(&mut parts, &mut text);
    parts
}

fn flush_text(parts: &mut Vec<Part>, text: &mut String) {
    let trimmed = text.trim_matches('\n');
    if !trimmed.trim().is_empty() {
        parts.push(Part::Text(trimmed.to_owned()));
    }
    text.clear();
}

/// Returns the fence (```` ``` ```` or `~~~`, possibly longer) and the language.
fn opening_fence(line: &str) -> Option<(String, String)> {
    // Any indentation: models indent fences under list items.
    let trimmed = line.trim_start();
    let first = trimmed.chars().next().filter(|c| *c == '`' || *c == '~')?;
    let count = trimmed.chars().take_while(|c| *c == first).count();
    if count < 3 {
        return None;
    }
    let info = trimmed[count..].trim();
    // A backtick fence's info string cannot contain backticks (that is inline code).
    if first == '`' && info.contains('`') {
        return None;
    }
    let language = info.split_whitespace().next().unwrap_or_default().to_owned();
    Some((first.to_string().repeat(count), language))
}

fn is_closing_fence(line: &str, marker: &str) -> bool {
    let trimmed = line.trim();
    let first = marker.chars().next().unwrap_or('`');
    trimmed.len() >= marker.len() && trimmed.chars().all(|c| c == first)
}

fn is_table_row(line: &str) -> bool {
    let trimmed = line.trim();
    trimmed.starts_with('|') && trimmed.matches('|').count() >= 2
}

fn is_table_separator(line: &str) -> bool {
    static SEPARATOR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\|?(\s*:?-+:?\s*\|)+\s*(:?-+:?)?\s*$").expect("regex"));
    SEPARATOR.is_match(line.trim())
}

/// Aligns the columns of a Markdown table for a monospace block.
fn format_table(lines: &[&str]) -> String {
    let rows: Vec<Option<Vec<String>>> = lines
        .iter()
        .map(|line| {
            if is_table_separator(line) {
                return None;
            }
            let inner = line.trim().trim_start_matches('|');
            let inner = inner.strip_suffix('|').unwrap_or(inner);
            Some(inner.split('|').map(|cell| plain_cell(cell.trim())).collect())
        })
        .collect();
    let columns = rows.iter().flatten().map(Vec::len).max().unwrap_or(0);
    let mut widths = vec![0; columns];
    for row in rows.iter().flatten() {
        for (index, cell) in row.iter().enumerate() {
            widths[index] = widths[index].max(cell.chars().count());
        }
    }
    rows.iter()
        .map(|row| match row {
            None => widths.iter().map(|w| "─".repeat(*w)).collect::<Vec<_>>().join("──"),
            Some(cells) => {
                let padded: Vec<String> = widths
                    .iter()
                    .enumerate()
                    .map(|(index, width)| {
                        let cell = cells.get(index).map(String::as_str).unwrap_or("");
                        format!("{cell}{}", " ".repeat(width - cell.chars().count()))
                    })
                    .collect();
                padded.join("  ").trim_end().to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Table cells are shown as plain text: drop emphasis and code markers.
fn plain_cell(cell: &str) -> String {
    static BREAK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)<br\s*/?>").expect("regex"));
    BREAK.replace_all(cell, " ").replace("**", "").replace("__", "").replace('`', "")
}

/// Rewrites one line of text into the supported subset.
fn simplify_line(line: &str) -> String {
    static HEADING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s{0,3}#{1,6}\s+(.*?)(\s+#+)?\s*$").expect("regex"));
    static RULE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s{0,3}(([-*_])(\s*[-*_]){2,}|=+|-+)\s*$").expect("regex"));
    static QUOTE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s{0,3}(>\s?)+").expect("regex"));
    static TASK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\s*[-*+]\s+)\[([ xX])\]\s+").expect("regex"));
    static IMAGE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"!\[([^\]]*)\]\(([^)\s]*)[^)]*\)").expect("regex"));
    static AUTOLINK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"<(https?://[^>\s]+)>").expect("regex"));
    static BREAK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)<br\s*/?>").expect("regex"));

    // Slint reserves this private-use character for its own interpolation.
    let line = line.replace('\u{e541}', "");
    if RULE.is_match(&line) {
        return String::new();
    }
    if let Some(captures) = HEADING.captures(&line) {
        let title = captures[1].replace("**", "");
        return if title.is_empty() { String::new() } else { format!("**{}**", escape_html(&title)) };
    }
    let line = QUOTE.replace(&line, "");
    let line = TASK.replace(&line, |c: &regex::Captures| format!("{}{} ", &c[1], if &c[2] == " " { "☐" } else { "☑" }));
    let line = IMAGE.replace_all(&line, "[$1]($2)");
    let line = AUTOLINK.replace_all(&line, "[$1]($1)");
    let line = BREAK.replace_all(&line, " ");
    escape_html(&line)
}

/// Escapes `<` outside inline code, so HTML-looking text stays literal.
fn escape_html(line: &str) -> String {
    let mut output = String::with_capacity(line.len() + 8);
    let chars: Vec<char> = line.chars().collect();
    let mut code_run: Option<usize> = None;
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if c == '`' {
            let run = chars[index..].iter().take_while(|c| **c == '`').count();
            code_run = match code_run {
                None => Some(run),
                Some(open) if open == run => None,
                other => other,
            };
            output.extend(std::iter::repeat_n('`', run));
            index += run;
            continue;
        }
        if c == '<' && code_run.is_none() && (index == 0 || chars[index - 1] != '\\') {
            output.push('\\');
        }
        output.push(c);
        index += 1;
    }
    output
}

/// Styled text for a text part, or plain text when the Markdown is still rejected.
/// Styled text for a text part. When Slint still rejects the Markdown, only the paragraphs
/// it rejects fall back to plain text.
pub fn styled(markdown: &str) -> Vec<slint::StyledText> {
    if let Ok(styled) = slint::StyledText::from_markdown(markdown) {
        return vec![styled];
    }
    markdown
        .split("\n\n")
        .filter(|block| !block.trim().is_empty())
        .map(|block| slint::StyledText::from_markdown(block).unwrap_or_else(|_| slint::StyledText::from_plain_text(block)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_code_blocks() {
        let parts = split("Intro **bold**\n\n```rust\nfn main() {}\n```\nAfter");
        assert_eq!(
            parts,
            vec![Part::Text("Intro **bold**".into()), Part::Code { language: "rust".into(), text: "fn main() {}".into() }, Part::Text("After".into()),]
        );
    }

    #[test]
    fn unterminated_fence_runs_to_the_end() {
        let parts = split("Text\n```python\nprint(1)");
        assert_eq!(parts[1], Part::Code { language: "python".into(), text: "print(1)".into() });
    }

    #[test]
    fn longer_fences_contain_shorter_ones() {
        let parts = split("````md\n```\ninner\n```\n````");
        assert_eq!(parts, vec![Part::Code { language: "md".into(), text: "```\ninner\n```".into() }]);
    }

    #[test]
    fn markdown_fences_are_unwrapped() {
        let reply = "```markdown\n## Fruits\n\n- **Pomme**\n\n```python\nprint(1)\n```\n\nFin\n```";
        assert_eq!(
            split(reply),
            vec![Part::Text("**Fruits**\n\n- **Pomme**".into()), Part::Code { language: "python".into(), text: "print(1)".into() }, Part::Text("Fin".into()),]
        );
    }

    #[test]
    fn indented_fences_under_list_items() {
        let parts = split("1. Install:\n    ```bash\n    pip install x\n      --upgrade\n    ```\n2. Done");
        assert_eq!(parts[1], Part::Code { language: "bash".into(), text: "pip install x\n  --upgrade".into() });
        assert_eq!(parts[2], Part::Text("2. Done".into()));
    }

    #[test]
    fn rejected_paragraphs_fall_back_alone() {
        // An indented code block (4 spaces after a blank line) is rejected by Slint.
        let styled = styled("**Bold** intro\n\n    indented code\n\nEnd");
        assert_eq!(styled.len(), 3);
    }

    #[test]
    fn markdown_examples_stay_code() {
        let parts = split("Example:\n```markdown\n# Title\n```");
        assert_eq!(parts[1], Part::Code { language: "markdown".into(), text: "# Title".into() });
    }

    #[test]
    fn tables_become_aligned_blocks() {
        let parts = split("| Name | Size |\n|---|---:|\n| **qwen3** | 5 GB |\n| gemma | 12 GB |");
        assert_eq!(parts, vec![Part::Code { language: String::new(), text: "Name   Size\n────────────\nqwen3  5 GB\ngemma  12 GB".into() }]);
    }

    #[test]
    fn simplifies_unsupported_syntax() {
        assert_eq!(simplify_line("## Title ##"), "**Title**");
        assert_eq!(simplify_line("---"), "");
        assert_eq!(simplify_line("> quoted"), "quoted");
        assert_eq!(simplify_line("- [x] done"), "- ☑ done");
        assert_eq!(simplify_line("![logo](https://a.b/c.png)"), "[logo](https://a.b/c.png)");
        assert_eq!(simplify_line("see <https://ollama.com>"), "see [https://ollama.com](https://ollama.com)");
        assert_eq!(simplify_line("a <b> c `<b>`"), "a \\<b> c `<b>`");
    }

    #[test]
    fn simplified_markdown_parses() {
        let reply =
            "# Title\n\nSome *text* with `code` and <html>.\n\n> Quote\n\n---\n\n1. one\n2. two\n   - nested\n\n- [ ] task\n\nSetext\n======\n\n![img](x.png)";
        for part in split(reply) {
            if let Part::Text(text) = part {
                assert!(slint::StyledText::from_markdown(&text).is_ok(), "rejected: {text}");
            }
        }
    }
}
