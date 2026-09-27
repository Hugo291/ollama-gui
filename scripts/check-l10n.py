#!/usr/bin/env python3
"""Lists the localizable strings used in the Swift sources and checks that each
translation (Resources/<lang>.lproj) covers them.

Usage: scripts/check-l10n.py [--list]
"""
import itertools
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"

# Initializers whose first string literal is a LocalizedStringKey / localization value.
CALLS = r"(?:Text|Button|Label|Toggle|Picker|Section|LabeledContent|TextField|Menu|TableColumn|LocalizedStringKey|CommandMenu|Window|Link)\(|String\(localized:\s*|\.help\(|\.navigationTitle\("
LITERAL_START = re.compile(r"(?:" + CALLS + r")\s*\"")


def read_literal(source: str, start: int):
    """Reads a Swift string literal starting after the opening quote.
    Returns (text with interpolations replaced by {i}, [expressions], end index)."""
    out, expressions, i = [], [], start
    while i < len(source):
        ch = source[i]
        if ch == "\\" and source[i + 1] == "(":
            depth, j = 1, i + 2
            while depth:
                if source[j] == "(":
                    depth += 1
                elif source[j] == ")":
                    depth -= 1
                j += 1
            expressions.append(source[i + 2:j - 1])
            out.append("{%d}" % (len(expressions) - 1))
            i = j
            continue
        if ch == "\\":
            escaped = source[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(escaped, escaped))
            i += 2
            continue
        if ch == '"':
            return "".join(out), expressions, i + 1
        out.append(ch)
        i += 1
    raise ValueError("unterminated literal")


def placeholder_options(expression: str):
    """Possible format specifiers for an interpolated expression."""
    if re.search(r"\.count\b|\bcount\b|\bstatus\b|\bupdates\b|\bindex\b", expression) and "format:" not in expression:
        return ["%lld", "%@"]
    return ["%@", "%lld"]


def keys_in_sources():
    keys = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        source = path.read_text()
        for match in LITERAL_START.finditer(source):
            text, expressions, _ = read_literal(source, match.end())
            if not text.strip():
                continue
            line = source.count("\n", 0, match.start()) + 1
            options = [placeholder_options(e) for e in expressions]
            candidates = []
            for combo in itertools.product(*options) if options else [()]:
                candidates.append(text.format(*combo) if combo else text)
            keys.setdefault(candidates[0], (candidates, f"{path.relative_to(ROOT)}:{line}"))
    return keys


def parse_strings(path: pathlib.Path):
    if not path.exists():
        return {}
    content = path.read_text()
    pattern = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
    unescape = lambda s: s.encode().decode("unicode_escape").encode("latin1").decode("utf-8")
    return {unescape(k): unescape(v) for k, v in pattern.findall(content)}


def parse_stringsdict(path: pathlib.Path):
    if not path.exists():
        return {}
    with path.open("rb") as handle:
        return plistlib.load(handle)


def main():
    keys = keys_in_sources()
    if "--list" in sys.argv:
        for key, (_, where) in sorted(keys.items()):
            print(f"{where}\t{key!r}")
        return 0

    failures = 0
    for lproj in sorted(RESOURCES.glob("*.lproj")):
        language = lproj.stem
        if language == "en":
            continue
        strings = parse_strings(lproj / "Localizable.strings")
        plurals = parse_stringsdict(lproj / "Localizable.stringsdict")
        known = set(strings) | set(plurals)
        missing = [(key, where) for key, (candidates, where) in keys.items() if not any(c in known for c in candidates)]
        used = {c for candidates, _ in keys.values() for c in candidates}
        unused = sorted(k for k in known if k not in used)
        print(f"[{language}] {len(keys)} keys used, {len(missing)} missing, {len(unused)} unused")
        for key, where in sorted(missing, key=lambda item: item[1]):
            print(f"  missing  {key!r}  ({where})")
        for key in unused:
            print(f"  unused   {key!r}")
        failures += len(missing)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
