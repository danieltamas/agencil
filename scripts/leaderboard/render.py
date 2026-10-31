"""Renders the leaderboard card (dark and light SVG), LEADERBOARD.md and the history copy from a validated data.json.

Usage: render.py --data F --out DIR --today YYYY-MM-DD
Deterministic: no clock and no randomness; the date comes from --today. Stdlib only. The caller validates first.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

CAVEAT = "Self-reported from one owner's councils on their own repositories. Not a general benchmark."
CARD_ROWS = 8
STALE_DAYS = 7
KEEP_DAYS = 365
THEMES = {
    "dark": {"bg": "#0e1116", "fg": "#e6edf3", "muted": "#8b949e", "bar": "#3fb950", "track": "#21262d", "warn": "#f0883e"},
    "light": {"bg": "#ffffff", "fg": "#1f2328", "muted": "#59636e", "bar": "#1a7f37", "track": "#d8dee4", "warn": "#bc4c00"},
}
COLUMNS = [("model", 24), ("harness", 250), ("kind", 330), ("confirmed share", 410), ("coverage", 580),
           ("golden", 650), ("n", 720), ("median", 760), ("cost/conf.", 815)]


def order(cell):
    return (-cell["confirmed_share_ci"][0], cell["model"], cell["harness"], cell["change_kind"])


def percent(value):
    return "%d%%" % round(value * 100)


def interval(pair):
    return "%d-%d%%" % (round(pair[0] * 100), round(pair[1] * 100))


def seconds(value):
    return "%ds" % round(value) if value is not None else "-"


def dollars(value):
    return "$%.2f" % value if value is not None else "-"


def optional_percent(value):
    return percent(value) if value is not None else "-"


def card(data, today, theme):
    colors = THEMES[theme]
    generated = data["generated_at"][:10]
    age = (datetime.date.fromisoformat(today) - datetime.date.fromisoformat(generated)).days
    cells = sorted(data["cells"], key=order)[:CARD_ROWS]
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="880" height="360" viewBox="0 0 880 360" role="img">',
           '<style>text{font-family:Menlo,Consolas,monospace;font-size:12px}.warn{fill:%s}</style>' % colors["warn"],
           '<rect width="880" height="360" fill="%s"/>' % colors["bg"],
           '<text x="24" y="34" fill="%s" style="font-size:16px;font-weight:bold">Agencil seat leaderboard</text>' % colors["fg"],
           '<text x="24" y="56" fill="%s"%s>updated %s, %d outcomes</text>' % (
               colors["muted"], ' class="warn"' if age > STALE_DAYS else "", generated, data["outcomes_total"])]
    for label, x in COLUMNS:
        out.append('<text x="%d" y="84" fill="%s">%s</text>' % (x, colors["muted"], escape(label)))
    if not cells:
        out.append('<text x="24" y="120" fill="%s">No cell has reached %d decided findings yet.</text>' % (colors["muted"], data["min_n"]))
    for index, cell in enumerate(cells):
        y = 108 + index * 28
        low, high = cell["confirmed_share_ci"]
        out += [
            '<text x="24" y="%d" fill="%s">%s</text>' % (y, colors["fg"], escape(cell["model"])),
            '<text x="250" y="%d" fill="%s">%s</text>' % (y, colors["muted"], escape(cell["harness"])),
            '<text x="330" y="%d" fill="%s">%s</text>' % (y, colors["muted"], escape(cell["change_kind"])),
            '<rect x="410" y="%d" width="100" height="8" fill="%s"/>' % (y - 9, colors["track"]),
            '<rect x="410" y="%d" width="%.1f" height="8" fill="%s"/>' % (y - 9, cell["confirmed_share"] * 100, colors["bar"]),
            '<path d="M%.1f %d H%.1f M%.1f %d V%d M%.1f %d V%d" stroke="%s" fill="none"/>' % (
                410 + low * 100, y - 5, 410 + high * 100, 410 + low * 100, y - 8, y - 2,
                410 + high * 100, y - 8, y - 2, colors["fg"]),
            '<text x="518" y="%d" fill="%s">%s</text>' % (y, colors["fg"], percent(cell["confirmed_share"])),
            '<text x="580" y="%d" fill="%s">%s</text>' % (y, colors["fg"], optional_percent(cell.get("coverage"))),
            '<text x="650" y="%d" fill="%s">%s</text>' % (y, colors["fg"], optional_percent(cell.get("golden_recall"))),
            '<text x="720" y="%d" fill="%s">%d</text>' % (y, colors["fg"], cell["n"]),
            '<text x="760" y="%d" fill="%s">%s</text>' % (y, colors["fg"], seconds(cell.get("median_seconds"))),
            '<text x="815" y="%d" fill="%s">%s</text>' % (y, colors["fg"], dollars(cell.get("cost_per_confirmed_usd"))),
        ]
    out.append("</svg>")
    return "\n".join(out) + "\n"


def table(data):
    lines = ["# Seat leaderboard", "", CAVEAT, "",
             "Updated %s, %d outcomes. Window: %s to %s. Minimum sample per cell: %d decided findings." % (
                 data["generated_at"][:10], data["outcomes_total"], data["window"]["from"], data["window"]["to"], data["min_n"]),
             "",
             "| Model | Harness | Change kind | n | Confirmed share (Wilson 95%) | Coverage (Wilson 95%) | Golden recall | Golden n | Median | Cost per confirmed |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for cell in sorted(data["cells"], key=order):
        coverage = "-"
        if cell.get("coverage") is not None:
            coverage = "%s (%s)" % (percent(cell["coverage"]), interval(cell["coverage_ci"])) if "coverage_ci" in cell else percent(cell["coverage"])
        lines.append("| %s | %s | %s | %d | %s (%s) | %s | %s | %d | %s | %s |" % (
            cell["model"], cell["harness"], cell["change_kind"], cell["n"], percent(cell["confirmed_share"]),
            interval(cell["confirmed_share_ci"]), coverage, optional_percent(cell.get("golden_recall")), cell["golden_n"],
            seconds(cell.get("median_seconds")), dollars(cell.get("cost_per_confirmed_usd"))))
    lines += ["", "## Method", "",
              "- An outcome is a finding that was later confirmed or refuted by adjudication or by the owner. n counts those outcomes per cell.",
              "- Confirmed share is confirmed over n. The interval is the Wilson score interval at 95%.",
              "- Coverage is the share of confirmed findings in the sittings where the seat gave a valid answer that the seat also raised.",
              "- Golden recall comes only from the golden set of known defects; there is no recall anywhere else.",
              "- Unresolved findings are shown in the data but count in no rate.",
              "- A cell appears only with at least %d outcomes. The window above is the span of the decided findings." % data["min_n"],
              "- Model names are public model ids or aliases approved in this repository.", ""]
    return "\n".join(lines)


def prune_history(history, today):
    for path in history.glob("*.json"):
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\.json", path.name):
            continue
        try:
            age = (today - datetime.date.fromisoformat(path.stem)).days
        except ValueError:
            continue
        if age > KEEP_DAYS:
            path.unlink()


def plain(path):
    """The data checkout is untrusted: an output path that is a symlink would redirect the write elsewhere."""
    if path.is_symlink():
        raise SystemExit("refusing to write through a symlink: %s" % path.name)
    return path


def write(path, text):
    plain(path).write_bytes(text.encode("ascii", "xmlcharrefreplace"))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--today", required=True)
    args = parser.parse_args(argv)
    today = datetime.date.fromisoformat(args.today)
    raw = Path(args.data).read_bytes()
    data = json.loads(raw.decode("ascii"))
    out = Path(args.out)
    plain(out / "history").mkdir(parents=True, exist_ok=True)
    for theme in THEMES:
        write(out / ("leaderboard-%s.svg" % theme), card(data, args.today, theme))
    write(out / "LEADERBOARD.md", table(data))
    plain(out / "history" / (args.today + ".json")).write_bytes(raw)
    prune_history(out / "history", today)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
