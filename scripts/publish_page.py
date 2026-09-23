#!/usr/bin/env python3
"""Render the mod download page (index.html) for a directory of mod zips.

Usage: publish_page.py DIR [--server ADDRESS] [--title TITLE]
DIR holds factorio-mcp_<version>.zip files; the newest version is the current one.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import re
from datetime import datetime, timezone
from pathlib import Path

ZIP = re.compile(r"^factorio-mcp_(\d+)\.(\d+)\.(\d+)\.zip$")

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  :root {{ --bg:#f5f7f8; --fg:#17191a; --muted:#5b6166; --card:#ffffff; --line:#dde2e5; --accent:#c26a1b; --accent-fg:#fff; --code:#eef1f3; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#141617; --fg:#e8eaeb; --muted:#9aa1a6; --card:#1c1f21; --line:#2c3134; --accent:#e08a3c; --accent-fg:#141617; --code:#23272a; }}
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg);
         font:16px/1.55 Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif; }}
  main {{ max-width:720px; margin:0 auto; padding:48px 16px 64px; }}
  h1 {{ font-size:28px; margin:0 0 4px; }}
  .sub {{ color:var(--muted); margin:0 0 28px; }}
  .card {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:20px 22px; margin:0 0 20px; }}
  .dl {{ display:inline-block; background:var(--accent); color:var(--accent-fg); text-decoration:none;
         font-weight:600; padding:10px 18px; border-radius:8px; margin:6px 0 10px; }}
  .meta {{ color:var(--muted); font-size:14px; word-break:break-all; }}
  h2 {{ font-size:18px; margin:0 0 10px; }}
  ol {{ margin:0; padding-left:20px; }} li {{ margin:6px 0; }}
  code {{ background:var(--code); padding:1px 6px; border-radius:5px; font-size:14px; }}
  table {{ border-collapse:collapse; width:100%; font-size:14px; }}
  td {{ padding:6px 0; border-top:1px solid var(--line); }} td:last-child {{ text-align:right; }}
  a {{ color:var(--accent); }}
</style>
</head>
<body>
<main>
  <h1>{title}</h1>
  <p class="sub">The server runs this mod; install the same version to join.</p>

  <div class="card">
    <h2>Current version: {version}</h2>
    <a class="dl" href="{zip}">Download {zip}</a>
    <div class="meta">{size} · sha256 {sha}<br>updated {updated}</div>
  </div>

  <div class="card">
    <h2>Install</h2>
    <ol>
      <li>Download the zip above. Don't unzip it.</li>
      <li>Put it in your Factorio <code>mods</code> folder and delete any older <code>factorio-mcp_*.zip</code> there:
        <br>Windows <code>%APPDATA%\\Factorio\\mods</code>
        <br>Linux <code>~/.factorio/mods</code>
        <br>macOS <code>~/Library/Application Support/factorio/mods</code></li>
      <li>Start Factorio, open <b>Mods</b> and make sure <b>Factorio MCP</b> is enabled.</li>
      <li>{connect}</li>
      <li>When the server updates the mod, you'll get a mod mismatch error on joining. Download the new version here and repeat.</li>
    </ol>
  </div>

  <div class="card">
    <h2>What it does</h2>
    <p style="margin:0">It lets AI agents each control one character in the game over RCON, using only normal player mechanics (walking, hand mining, crafting, reach limits, fog of war). It adds no items or buildings, and agent characters show a name tag. Source: factorio-mcp.</p>
  </div>
{older}
</main>
</body>
</html>
"""


def human(n: int) -> str:
    return f"{n / 1024:.0f} KB" if n < 1024 * 1024 else f"{n / 1024 / 1024:.1f} MB"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--server", help="game server address shown to players, e.g. host:34197")
    ap.add_argument("--title", default="Factorio MCP mod")
    args = ap.parse_args()
    d = Path(args.dir)
    zips = sorted((p for p in d.iterdir() if ZIP.match(p.name)),
                  key=lambda p: tuple(int(x) for x in ZIP.match(p.name).groups()), reverse=True)
    if not zips:
        raise SystemExit(f"no factorio-mcp_<version>.zip in {d}")
    cur = zips[0]
    version = ".".join(ZIP.match(cur.name).groups())
    sha = hashlib.sha256(cur.read_bytes()).hexdigest()
    connect = (f"In Factorio choose <b>Multiplayer → Connect to address</b> and enter <code>{html.escape(args.server)}</code>."
               if args.server else "Join the server from <b>Multiplayer</b>.")
    older = ""
    if len(zips) > 1:
        rows = "".join(f'<tr><td><a href="{p.name}">{p.name}</a></td><td>{human(p.stat().st_size)}</td></tr>' for p in zips[1:])
        older = f'\n  <div class="card">\n    <h2>Older versions</h2>\n    <table>{rows}</table>\n  </div>\n'
    page = PAGE.format(
        title=html.escape(args.title), version=version, zip=cur.name, size=human(cur.stat().st_size), sha=sha,
        updated=datetime.fromtimestamp(cur.stat().st_mtime, timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        connect=connect, older=older)
    (d / "index.html").write_text(page)
    print(f"{d / 'index.html'}: current {cur.name}")


if __name__ == "__main__":
    main()
