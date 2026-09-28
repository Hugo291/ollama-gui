#!/usr/bin/env python3
"""Extracts the @tr strings of ui/*.slint into lang/<lang>/LC_MESSAGES/ollama-gui.po.

Existing translations are kept; new strings are added untranslated and listed.
Usage: scripts/update-po.py [lang]   (default: fr)
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANG = sys.argv[1] if len(sys.argv) > 1 else "fr"
PO = os.path.join(ROOT, "lang", LANG, "LC_MESSAGES", "ollama-gui.po")
HEADER = f'''msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\\n"
"Language: {LANG}\\n"
"Plural-Forms: nplurals=2; plural=(n > 1);\\n"
'''


def read_po(path):
    """msgid -> msgstr. Handles entries wrapped over several lines by PO editors."""
    translations = {}
    if not os.path.exists(path):
        return translations
    msgid = msgstr = field = None

    def flush():
        if msgid and msgstr is not None:
            translations[msgid] = msgstr

    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        m = re.match(r'^(msgid|msgstr) "(.*)"$', line)
        if m:
            if m.group(1) == "msgid":
                flush()
                msgid, msgstr = m.group(2), None
            else:
                msgstr = m.group(2)
            field = m.group(1)
            continue
        m = re.match(r'^"(.*)"$', line)
        if m and field == "msgid":
            msgid += m.group(1)
        elif m and field == "msgstr":
            msgstr += m.group(1)
        elif not line.strip() or line.startswith("#"):
            flush()
            msgid = msgstr = field = None
    flush()
    return translations


def extract():
    strings = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "ui", "*.slint"))):
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r'@tr\(\s*"((?:[^"\\]|\\.)*)"', text):
            line = text.count("\n", 0, m.start()) + 1
            strings.setdefault(m.group(1), []).append(f"ui/{os.path.basename(path)}:{line}")
    return strings


def main():
    existing = read_po(PO)
    strings = extract()
    os.makedirs(os.path.dirname(PO), exist_ok=True)
    missing = []
    with open(PO, "w", encoding="utf-8") as po:
        po.write(HEADER)
        for msgid, places in strings.items():
            msgstr = existing.get(msgid, "")
            if not msgstr:
                missing.append(msgid)
            po.write(f"\n#: {' '.join(places)}\nmsgid \"{msgid}\"\nmsgstr \"{msgstr}\"\n")
    print(f"{len(strings)} strings, {len(missing)} untranslated -> {os.path.relpath(PO, ROOT)}")
    for msgid in missing:
        print(f"  untranslated: {msgid}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
