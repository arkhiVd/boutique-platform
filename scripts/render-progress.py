#!/usr/bin/env python3
"""Render PROGRESS.md into a self-contained docs/progress.html.

No third-party dependencies: the page must open anywhere, with no build step.
Run it after every edit to PROGRESS.md. It is a one-way render — PROGRESS.md is
the source of truth, docs/progress.html is never hand-edited.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "PROGRESS.md"
DST = ROOT / "docs" / "progress.html"

CSS = """
:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--fg:#e6edf3;--dim:#8b949e;
--cyan:#39c5cf;--green:#3fb950;--amber:#d29922;--red:#f85149;--blue:#58a6ff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:32px 20px 96px}
h1{font-size:26px;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:19px;margin:36px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line);
letter-spacing:-.01em}
h3{font-size:15px;margin:24px 0 8px;color:var(--cyan)}
p{margin:10px 0}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}
code{background:#1f2630;border:1px solid var(--line);border-radius:4px;
padding:1px 5px;font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px;
overflow:auto;font:12.5px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre code{background:none;border:0;padding:0}
table{border-collapse:collapse;width:100%;margin:14px 0;font-size:13.5px}
th,td{border:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top}
th{background:var(--panel);font-weight:600;color:var(--dim);text-transform:uppercase;
font-size:11px;letter-spacing:.05em}
tr:nth-child(even) td{background:#11161d}
ul,ol{margin:10px 0;padding-left:24px}li{margin:4px 0}
hr{border:0;border-top:1px solid var(--line);margin:32px 0}
.meta{color:var(--dim);font-size:13px;margin-bottom:24px}
.card{background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--cyan);
border-radius:8px;padding:14px 18px;margin:16px 0}
.tag{display:inline-block;border-radius:20px;padding:1px 9px;font-size:11px;
font-weight:600;vertical-align:middle;margin-right:6px}
.tag.done{background:rgba(63,185,80,.15);color:var(--green);border:1px solid rgba(63,185,80,.4)}
.tag.wip{background:rgba(210,153,34,.15);color:var(--amber);border:1px solid rgba(210,153,34,.4)}
.tag.block{background:rgba(248,81,73,.15);color:var(--red);border:1px solid rgba(248,81,73,.4)}
.tag.wait{background:rgba(88,166,255,.13);color:var(--blue);border:1px solid rgba(88,166,255,.35)}
"""


def inline(text: str) -> str:
    """Escape HTML, then re-apply the inline markdown we actually use."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', out)
    return out


def render(md: str) -> str:
    lines = md.splitlines()
    body: list[str] = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]

        # fenced code block
        if line.lstrip().startswith("```"):
            i += 1
            buf: list[str] = []
            while i < n and not lines[i].lstrip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1  # closing fence
            body.append(
                '<pre><code>' + html.escape("\n".join(buf), quote=False) + "</code></pre>"
            )
            continue

        # table: a header row, a separator row, then body rows
        if "|" in line and i + 1 < n and re.match(r"^\s*\|?[\s:|-]+\|[\s:|-]*$", lines[i + 1]):
            def cells(row: str) -> list[str]:
                row = row.strip()
                if row.startswith("|"):
                    row = row[1:]
                if row.endswith("|"):
                    row = row[:-1]
                return [c.strip() for c in row.split("|")]

            head = cells(line)
            i += 2
            rows = []
            while i < n and "|" in lines[i]:
                rows.append(cells(lines[i]))
                i += 1
            t = ["<table><thead><tr>"]
            t += [f"<th>{inline(c)}</th>" for c in head]
            t.append("</tr></thead><tbody>")
            for r in rows:
                r = (r + [""] * len(head))[: len(head)]
                t.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            t.append("</tbody></table>")
            body.append("".join(t))
            continue

        # headings
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            body.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            i += 1
            continue

        # horizontal rule
        if re.match(r"^\s*---+\s*$", line):
            body.append("<hr>")
            i += 1
            continue

        # blank line
        if not line.strip():
            i += 1
            continue

        # list (flat, one level is all PROGRESS.md uses)
        if re.match(r"^\s*[-*]\s+", line):
            items = []
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                items.append(re.sub(r"^\s*[-*]\s+", "", lines[i]))
                i += 1
            body.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>")
            continue

        # paragraph
        buf = [line]
        i += 1
        while i < n and lines[i].strip() and not re.match(
            r"^(#{1,6}\s|\s*[-*]\s|```|\s*---+\s*$|.*\|\s*[\s:|-]+\|)", lines[i]
        ):
            buf.append(lines[i])
            i += 1
        body.append("<p>" + inline(" ".join(buf)) + "</p>")

    return "\n".join(body)


def status_badges(html_body: str) -> str:
    """Turn the [~] / [x] / [!] / [ ] phase markers into real badges."""
    for marker, cls, label in (
        ("[~]", "wip", "in progress"),
        ("[x]", "done", "done"),
        ("[!]", "block", "blocked"),
        ("[ ]", "wait", "not started"),
    ):
        html_body = html_body.replace(
            f"<code>{marker}</code>", f'<span class="tag {cls}">{label}</span>'
        )
        html_body = html_body.replace(marker, f'<span class="tag {cls}">{label}</span>')
    return html_body


def main() -> int:
    if not SRC.exists():
        print(f"missing {SRC}", file=sys.stderr)
        return 1

    md = SRC.read_text(encoding="utf-8")
    rendered = status_badges(render(md))

    updated = "never"
    m = re.search(r"\*\*Last updated:\s*([^*]+)\*\*", md)
    if m:
        updated = m.group(1).strip()

    page = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>boutique-platform — live progress</title>
<meta http-equiv="refresh" content="30">
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<p class="meta">rendered from <code>PROGRESS.md</code> · last updated {html.escape(updated)} ·
auto-refreshes every 30s</p>
{rendered}
</div>
</body>
</html>
"""
    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_text(page, encoding="utf-8")
    print(f"wrote {DST} ({len(page)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
