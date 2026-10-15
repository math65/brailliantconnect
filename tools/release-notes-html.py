#!/usr/bin/env python3
"""Print one version's release notes as HTML, for Sparkle's update window.

    python3 -I tools/release-notes-html.py RELEASE_NOTES.fr.md 1.2.0

Sparkle shows an item's description as a web page unless the item says
`sparkle:format="markdown"`, in which case it renders the Markdown as styled
text in a plain text view. Tried with VoiceOver and a braille display on 15 Oct
2026, the author preferred the web page: real headings and lists, announced
and navigable as on any page. Hence this converter.

It covers what the notes actually use — `#` headings, paragraphs wrapped over
several lines, `-` lists whose items continue on indented lines, `code`,
**bold**, *italics* and [links](url) — and nothing else, so it needs no
dependency (pandoc would do it, and a contributor would have to install it).
Headings are shifted so the section's highest becomes <h2>: Sparkle titles the
window with the version itself.
"""

import html
import io
import re
import sys


def section(path, version):
    """The body of `## v<version>` in a release notes file."""
    text = io.open(path, encoding="utf-8").read()
    start = text.index("## v" + version)
    end = text.find("\n## v", start + 1)
    return text[start : end if end > 0 else len(text)].split("\n", 1)[1].strip()


INLINE = [
    (re.compile(r"`([^`]+)`"), r"<code>\1</code>"),
    (re.compile(r"\*\*([^*]+)\*\*"), r"<strong>\1</strong>"),
    (re.compile(r"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])"), r"<em>\1</em>"),
    (re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)"), r'<a href="\2">\1</a>'),
]


def inline(text):
    out = html.escape(text, quote=False)
    for pattern, replacement in INLINE:
        out = pattern.sub(replacement, out)
    return out


def blocks(markdown):
    """Headings, paragraphs and lists, each joined across its wrapped lines."""
    current = None  # ("p", [lines]) or ("ul", [[lines], ...])
    for line in markdown.splitlines():
        stripped = line.strip()
        heading = re.match(r"(#{1,6})\s+(.*)", stripped)
        if not stripped:
            if current:
                yield current
            current = None
        elif heading:
            if current:
                yield current
            current = None
            yield ("h", len(heading.group(1)), heading.group(2))
        elif re.match(r"[-*]\s+", stripped) and not line.startswith(("  ", "\t")):
            if current and current[0] != "ul":
                yield current
                current = None
            if current is None:
                current = ("ul", [])
            current[1].append([re.sub(r"^[-*]\s+", "", stripped)])
        elif current and current[0] == "ul":
            current[1][-1].append(stripped)
        else:
            if current is None:
                current = ("p", [])
            current[1].append(stripped)
    if current:
        yield current


def convert(markdown, lang):
    parsed = list(blocks(markdown))
    levels = [b[1] for b in parsed if b[0] == "h"]
    shift = (min(levels) - 2) if levels else 0
    out = []
    for block in parsed:
        if block[0] == "h":
            level = max(2, min(6, block[1] - shift))
            out.append(f"<h{level}>{inline(block[2])}</h{level}>")
        elif block[0] == "p":
            out.append(f"<p>{inline(' '.join(block[1]))}</p>")
        else:
            items = "".join(f"<li>{inline(' '.join(item))}</li>" for item in block[1])
            out.append(f"<ul>{items}</ul>")
    body = "\n".join(out)
    assert "]]>" not in body, "would end the CDATA section in the appcast"
    return f'<div lang="{lang}">\n{body}\n</div>'


if __name__ == "__main__":
    path, version = sys.argv[1:]
    lang = "fr" if path.endswith(".fr.md") else "en"
    print(convert(section(path, version), lang))
