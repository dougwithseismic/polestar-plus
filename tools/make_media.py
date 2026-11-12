"""Makes the pictures in docs/media from the real code, with no game running.

    cargo build --release
    python tools/make_media.py

- strip.png, strip-zoom.png: the strip PolestarLink paints, from the same
  stand-in game and stand-in Polestar the tests use.
- overlay.png: the overlay panel polestar-plus draws for that strip.
- dashboard.txt: the terminal view for it.
- timeline-*.svg: what the rotation planner lays out for a class, drawn from
  the planner's own output in the test harness. These are drawings of real
  planner output, not screenshots of the game.
- summaries.txt, share-string.txt: a rotation in the editor's plain words,
  and as a string to share.

Needs Python with lupa, and the built binary (POLESTAR_PLUS_BIN picks another build).
"""

import html
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

import addon_strip  # noqa: E402
import next_addon  # noqa: E402

OUT = ROOT / "docs" / "media"


def strip_and_overlay():
    to_byte = addon_strip.CONVERSIONS["rounding"]
    _, _, cells = addon_strip.run_addon()
    rows = addon_strip.paint(cells, to_byte)
    strip = OUT / "strip.png"
    addon_strip.write_png(strip, rows)

    # The first 120 cells of the strip, each pixel made 5 wide and 12 tall so the cells can be seen.
    wide, tall, across = 5, 12, 360
    zoom = []
    for row in rows[:6]:
        line = bytearray()
        for x in range(across):
            line += bytes(row[x * 3:x * 3 + 3]) * wide
        zoom += [line] * tall
    addon_strip.write_png(OUT / "strip-zoom.png", zoom)

    binary = str(addon_strip.BINARY)

    def run(*args):
        return subprocess.run([binary, *args], capture_output=True, text=True, encoding="utf-8", check=True).stdout

    (OUT / "dashboard.txt").write_text(run("decode", str(strip)), encoding="utf-8", newline="\n")
    run("decode", str(strip), "--png", str(OUT / "overlay.png"))


# ---------------------------------------------------------------------------------------- the planner's timeline

COLOURS = {"target": "#e5675a", "player": "#73d980"}
LEFT, WIDTH, SPAN = 150, 980, 30


def across(seconds):
    return LEFT + max(0, min(SPAN, seconds)) / SPAN * WIDTH


def chip(out, x, y, label, press):
    width = 6.4 * len(label) + 14
    if press:
        out.append(f'<rect x="{x:.1f}" y="{y}" width="{width:.1f}" height="18" rx="4" fill="#232b35" stroke="#ffd100" stroke-opacity="0.55"/>')
        out.append(f'<text x="{x + 7:.1f}" y="{y + 13}" fill="#ffffff" font-size="11">{html.escape(label)}</text>')
    else:
        out.append(f'<rect x="{x:.1f}" y="{y}" width="{width:.1f}" height="18" rx="4" fill="#1b222b" stroke="#3a4552"/>')
        out.append(f'<text x="{x + 7:.1f}" y="{y + 13}" fill="#c8d0d8" font-size="11">{html.escape(label)}</text>')
    return x + width + 4


def timeline(game, title, subtitle, name):
    """The editor's preview for the rotation `game` is using, as an SVG."""
    preview = game.ns.Edit.Preview()
    options = game.ns.Edit.PreviewOptions()
    steps = list(preview.steps.values())
    lanes = list(preview.lanes.values())[:3]
    rows = 3  # press chips are staggered over three rows so neighbours do not overlap
    axis = 106 + rows * 22 + 6
    height = axis + 30 + 22 * len(lanes) + 22
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {LEFT + WIDTH + 130} {height}" font-family="Segoe UI, Helvetica, Arial, sans-serif">',
           '<rect width="100%" height="100%" rx="10" fill="#0d1014"/>',
           f'<text x="20" y="30" fill="#ffd100" font-size="17" font-weight="600">{html.escape(title)}</text>',
           f'<text x="20" y="50" fill="#9aa3ad" font-size="12">{html.escape(subtitle)}</text>',
           '<text x="20" y="85" fill="#7d8791" font-size="11">beside a press</text>',
           '<text x="20" y="119" fill="#7d8791" font-size="11">one press each</text>']
    free_end, ends = -1e9, [-1e9] * rows
    for step in steps:
        label, at = step.state.name, across(step.at)
        if step.free:
            free_end = chip(out, max(at, free_end), 72, label, False)
            continue
        row = next((i for i in range(rows) if at >= ends[i]), min(range(rows), key=lambda i: ends[i]))
        y = 106 + row * 22
        long = max(step.cast or 0, step.channel or 0)
        if long:
            out.append(f'<rect x="{at:.1f}" y="{y + 19}" width="{across(step.at + long) - at:.1f}" height="2" fill="#7fb8ff"/>')
        out.append(f'<line x1="{at:.1f}" y1="{y + 18}" x2="{at:.1f}" y2="{axis}" stroke="#ffd100" stroke-opacity="0.18"/>')
        ends[row] = chip(out, at, y, label, True)
    out.append(f'<line x1="{LEFT}" y1="{axis}" x2="{LEFT + WIDTH}" y2="{axis}" stroke="#56606b"/>')
    for second in range(0, SPAN + 1, 5):
        out.append(f'<line x1="{across(second):.1f}" y1="{axis}" x2="{across(second):.1f}" y2="{axis + 5}" stroke="#56606b"/>')
        out.append(f'<text x="{across(second) + 3:.1f}" y="{axis + 15}" fill="#7d8791" font-size="10">{second}s</text>')
    for i, lane in enumerate(lanes):
        y = axis + 26 + i * 22
        stacks = f"  x{int(lane.most)}" if lane.cap > 1 else ""
        out.append(f'<text x="20" y="{y + 9}" fill="#9aa3ad" font-size="11">{html.escape(lane.name + stacks)}</text>')
        for span in lane.spans.values():
            a, b = across(span["from"]), across(span.to)
            out.append(f'<rect x="{a:.1f}" y="{y}" width="{max(2, b - a):.1f}" height="9" rx="2" fill="{COLOURS[lane.unit]}" fill-opacity="0.8"/>')
        if lane.cap > 1 and lane.full is not None:
            out.append(f'<rect x="{across(lane.full):.1f}" y="{y - 1}" width="2" height="11" fill="#ffd100"/>')
    note = f"{options.income} {options.bar} a second, {options.enemies} enemy. Drawn from the planner's own output; not a game screenshot."
    out.append(f'<text x="20" y="{height - 10}" fill="#56606b" font-size="10">{html.escape(note)}</text>')
    out.append("</svg>")
    (OUT / name).write_text("\n".join(out), encoding="utf-8", newline="\n")


def warrior():
    game = next_addon.fighter((7386, 772, 78, 2687, 6343, 71, 6673, 7384, 6572, 5308), (0, 0, 6), stance=2, level=15)
    game.spell(2687, next_addon.BLOODRAGE, cd=60000, off=True)
    game.spell(6673, "The warrior shouts, increasing the attack power of the party. Lasts 2 min.", cost=10)
    game.rebuild()
    return game


def timelines():
    timeline(warrior(), "Protection warrior, Defensive Stance, level 15", "The first 30 seconds of a fight, as the planner lays it out", "timeline-warrior.svg")
    timeline(next_addon.hero("ROGUE"), "Combat rogue, level 30", "Energy, a one-second global cooldown, combo points built and spent", "timeline-rogue.svg")
    timeline(next_addon.hero("MAGE"), "Frost mage, level 30", "Casts take their time (blue lines); the instant finisher comes at the end", "timeline-mage.svg")
    timeline(next_addon.hero("WARLOCK"), "Affliction warlock, level 30", "Effects go on once and are kept up; Life Tap when the mana runs low", "timeline-warlock.svg")


def summaries():
    """Each rule of a rotation in the editor's plain words, and the rotation as a string to share."""
    game = warrior()
    lines = [game.ns.Edit.Summary(rule) for rule in game.ns.Edit.Current().values() if game.ns.Engine.State(rule.spell).known]
    (OUT / "summaries.txt").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    (OUT / "share-string.txt").write_text(game.ns.Edit.Export() + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    strip_and_overlay()
    timelines()
    summaries()
    print("docs/media:", ", ".join(sorted(p.name for p in OUT.iterdir())))
