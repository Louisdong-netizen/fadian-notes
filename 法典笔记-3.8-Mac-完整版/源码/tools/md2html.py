#!/usr/bin/env python3
"""Small, dependency-free Markdown -> standalone HTML converter for the bundled docs."""
import html
import re
import sys
from pathlib import Path

INLINE_CODE = re.compile(r"`([^`]+)`")
BOLD = re.compile(r"\*\*(.+?)\*\*")
ITALIC = re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)")
LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")


def inline(text: str) -> str:
    placeholders = {}

    def stash(value: str) -> str:
        key = f"\x00{len(placeholders)}\x00"
        placeholders[key] = value
        return key

    text = INLINE_CODE.sub(lambda m: stash(f"<code>{html.escape(m.group(1))}</code>"), text)
    text = html.escape(text, quote=False)
    text = LINK.sub(lambda m: f'<a href="{html.escape(m.group(2), quote=True)}" target="_blank" rel="noopener">{m.group(1)}</a>', text)
    text = BOLD.sub(r"<strong>\1</strong>", text)
    text = ITALIC.sub(r"<em>\1</em>", text)
    for key, value in placeholders.items():
        text = text.replace(html.escape(key, quote=False), value)
    return text


def convert(md: str) -> str:
    lines = md.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []
    i = 0
    n = len(lines)

    while i < n:
        line = lines[i]
        stripped = line.strip()

        if not stripped:
            i += 1
            continue

        # Fenced code
        if stripped.startswith("```"):
            lang = stripped[3:].strip()
            i += 1
            buf = []
            while i < n and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            cls = f' class="language-{html.escape(lang)}"' if lang else ""
            out.append(f"<pre><code{cls}>{html.escape(chr(10).join(buf))}</code></pre>")
            continue

        # Heading
        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level = len(m.group(1))
            out.append(f"<h{level}>{inline(m.group(2).strip())}</h{level}>")
            i += 1
            continue

        # Horizontal rule
        if re.fullmatch(r"(?:-{3,}|\*{3,}|_{3,})", stripped):
            out.append("<hr>")
            i += 1
            continue

        # Table
        if "|" in line and i + 1 < n and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1]):
            header = [c.strip() for c in line.strip().strip("|").split("|")]
            aligns = []
            for cell in lines[i + 1].strip().strip("|").split("|"):
                cell = cell.strip()
                if cell.startswith(":") and cell.endswith(":"):
                    aligns.append("center")
                elif cell.endswith(":"):
                    aligns.append("right")
                else:
                    aligns.append("left")
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            out.append("<table><thead><tr>")
            for idx, cell in enumerate(header):
                align = aligns[idx] if idx < len(aligns) else "left"
                out.append(f'<th style="text-align:{align}">{inline(cell)}</th>')
            out.append("</tr></thead><tbody>")
            for row in rows:
                out.append("<tr>")
                for idx in range(len(header)):
                    cell = row[idx] if idx < len(row) else ""
                    align = aligns[idx] if idx < len(aligns) else "left"
                    out.append(f'<td style="text-align:{align}">{inline(cell)}</td>')
                out.append("</tr>")
            out.append("</tbody></table>")
            continue

        # Blockquote
        if stripped.startswith(">"):
            buf = []
            while i < n and lines[i].strip().startswith(">"):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i]))
                i += 1
            out.append(f"<blockquote>{convert(chr(10).join(buf))}</blockquote>")
            continue

        # Lists (nested by indentation)
        if re.match(r"^(\s*)([-*+]|\d+\.)\s+", line):
            out.append(render_list(lines, i))
            while i < n and (re.match(r"^(\s*)([-*+]|\d+\.)\s+", lines[i]) or
                             (lines[i].strip() and lines[i].startswith(("  ", "\t")) and
                              not re.match(r"^(\s*)([-*+]|\d+\.)\s+", lines[i]))):
                i += 1
            continue

        # Paragraph
        buf = []
        while i < n and lines[i].strip() and not re.match(
            r"^(#{1,6}\s|```|>\s*|(\s*)([-*+]|\d+\.)\s+)", lines[i]
        ):
            if "|" in lines[i] and i + 1 < n and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1]):
                break
            buf.append(lines[i].strip())
            i += 1
        out.append(f"<p>{inline(' '.join(buf))}</p>")

    return "\n".join(out)


def render_list(lines, start):
    items = []  # (indent, ordered, text, children)
    i = start
    n = len(lines)
    while i < n:
        m = re.match(r"^(\s*)([-*+]|\d+\.)\s+(.*)$", lines[i])
        if not m:
            if lines[i].strip() and lines[i].startswith(("  ", "\t")) and items:
                items[-1][2] += " " + lines[i].strip()
                i += 1
                continue
            break
        indent = len(m.group(1).replace("\t", "    "))
        ordered = m.group(2)[0].isdigit()
        text = m.group(3).strip()
        i += 1
        # Continuation lines (indented, not a new bullet)
        while i < n and lines[i].strip() and lines[i].startswith(("  ", "\t")) and not re.match(r"^(\s*)([-*+]|\d+\.)\s+", lines[i]):
            text += " " + lines[i].strip()
            i += 1
        items.append([indent, ordered, text, []])

    if not items:
        return ""

    # Build a tree by indentation.
    root = {"indent": -1, "children": []}
    stack = [(root, -1)]
    for item in items:
        node = {"indent": item[0], "ordered": item[1], "text": item[2], "children": []}
        while stack and item[0] <= stack[-1][1]:
            stack.pop()
        stack[-1][0]["children"].append(node)
        stack.append((node, item[0]))

    def render(node, ordered):
        tag = "ol" if ordered else "ul"
        parts = [f"<{tag}>"]
        for child in node["children"]:
            parts.append(f"<li>{inline(child['text'])}")
            if child["children"]:
                parts.append(render(child, child["children"][0]["ordered"]))
            parts.append("</li>")
        parts.append(f"</{tag}>")
        return "".join(parts)

    return render(root, root["children"][0]["ordered"] if root["children"] else False)


def wrap(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
  :root {{ --ink:#3a322c; --ink2:#5b4c40; --muted:#8a7c6c; --accent:#8a5a2b;
           --paper:#faf6ef; --card:#fffdf8; --line:#e2d7c6; }}
  * {{ box-sizing:border-box; }}
  html {{ background:var(--paper); }}
  body {{ margin:0; color:var(--ink); background:var(--paper);
          font-family:"Songti SC","SimSun","Noto Serif CJK SC",serif; font-size:16px; line-height:1.95; }}
  .topbar {{ position:sticky; top:0; z-index:2; display:flex; align-items:center; gap:16px;
             padding:12px 28px; background:rgba(250,246,239,.94);
             border-bottom:1px solid var(--line); backdrop-filter:blur(8px); }}
  .topbar a {{ color:var(--accent); text-decoration:none; font-size:13px; }}
  .topbar a:hover {{ text-decoration:underline; }}
  .topbar .sep {{ color:#c8b9a5; }}
  main {{ width:min(820px,92vw); margin:0 auto; padding:46px 0 96px; }}
  h1 {{ font-size:30px; line-height:1.4; letter-spacing:.03em; margin:0 0 24px; }}
  h2 {{ font-size:22px; margin:46px 0 14px; padding-top:14px; border-top:1px solid var(--line); }}
  h3 {{ font-size:18px; margin:30px 0 10px; color:var(--ink2); }}
  h4 {{ font-size:16px; margin:24px 0 8px; }}
  p {{ margin:12px 0; }}
  strong {{ color:#2f2620; }}
  a {{ color:var(--accent); }}
  blockquote {{ margin:18px 0; padding:12px 20px; background:#f4ecdf;
                border-left:3px solid #c9a877; color:#5c4c3c; }}
  blockquote p {{ margin:4px 0; }}
  code {{ font-family:"SF Mono","Menlo",monospace; font-size:.86em; background:#f1e9dc;
          padding:1px 6px; border-radius:5px; }}
  pre {{ background:#2f2925; color:#f4ecdf; padding:18px 20px; border-radius:10px;
         overflow:auto; line-height:1.7; }}
  pre code {{ background:none; padding:0; color:inherit; font-size:13px; }}
  table {{ width:100%; border-collapse:collapse; margin:18px 0; font-size:14px;
           background:var(--card); border:1px solid var(--line); }}
  th, td {{ padding:9px 12px; border-bottom:1px solid var(--line); vertical-align:top; }}
  th {{ background:#f3eadc; font-weight:600; }}
  tr:last-child td {{ border-bottom:0; }}
  hr {{ border:0; border-top:1px solid var(--line); margin:34px 0; }}
  ul, ol {{ padding-left:1.6em; margin:12px 0; }}
  li {{ margin:7px 0; }}
  .foot {{ margin-top:48px; padding-top:18px; border-top:1px solid var(--line);
           color:var(--muted); font-size:12px; }}
  .app-note {{ margin:0 0 26px; padding:12px 18px; border:1px solid #e3cfad; border-radius:10px;
               background:#fbf3e4; color:#775f43; font-size:13px; line-height:1.8; }}
  .app-note b {{ color:#8a5a2b; }}
</style>
</head>
<body>
<nav class="topbar">
  <a href="打开法典笔记.html">← 返回首页</a>
  <span class="sep">·</span>
  <a href="使用说明.html">使用说明</a>
  <a href="关系说明.html">关系说明</a>
</nav>
<main>
<div class="app-note"><b>macOS 独立版提示：</b>你正在应用内阅读说明书，无需双击 HTML 文件；在首页选择法典，或用工具栏的「首页」按钮随时返回。</div>
{body}
<div class="foot">法典笔记 3.8 · macOS 独立版 · 本页内容离线保存在应用内</div>
</main>
</body>
</html>
"""


def main():
    if len(sys.argv) < 3:
        print("usage: md2html.py input.md output.html", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    target = Path(sys.argv[2])
    title = source.stem
    body = convert(source.read_text(encoding="utf-8"))
    target.write_text(wrap(title, body), encoding="utf-8")
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
