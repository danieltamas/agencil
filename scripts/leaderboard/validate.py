"""Validates a leaderboard data.json against the published allowlist. Stdlib only.

Usage: validate.py <data.json> [--models F] [--aliases F] [--harnesses F]
Prints "ok" and exits 0, or prints one problem per line and exits 1. The Swift side applies the same rules
(Sources/AgencilCore/Leaderboard/LeaderboardValidator.swift).
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOP_KEYS = {"schema", "generated_at", "window", "outcomes_total", "min_n", "cells"}
REQUIRED = {"model", "harness", "change_kind", "n", "confirmed", "refuted", "unresolved",
            "confirmed_share", "confirmed_share_ci", "golden_n"}
OPTIONAL = {"coverage", "coverage_ci", "golden_recall", "median_seconds", "cost_per_confirmed_usd"}
KINDS = {"auth", "schema", "ui", "refactor", "infra", "other"}
MODEL = re.compile(r"[a-z0-9][a-z0-9._:-]{0,63}")
TIME = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
FLOOR = 10


def is_time(value):
    if not (isinstance(value, str) and TIME.fullmatch(value)):
        return False
    try:
        datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value == value \
        and value not in (float("inf"), float("-inf"))


def is_count(value):
    return is_number(value) and float(value).is_integer() and value >= 0


def is_unit(value):
    return is_number(value) and 0 <= value <= 1


def is_interval(value):
    return isinstance(value, list) and len(value) == 2 and all(is_unit(v) for v in value) and value[0] <= value[1]


def reject_constant(name):
    raise ValueError("non-finite number " + name)


def problems_in(data, public, aliases, harnesses):
    problems = []
    if not isinstance(data, dict):
        return ["the file is not a JSON object"]
    if set(data) != TOP_KEYS:
        problems.append("top-level keys differ from the schema: %s" % sorted(set(data) ^ TOP_KEYS))
    if data.get("schema") != 1 or isinstance(data.get("schema"), bool):
        problems.append("schema must be 1")
    if not is_count(data.get("outcomes_total")):
        problems.append("outcomes_total must be a non-negative integer")
    min_n = data.get("min_n")
    if not is_count(min_n) or min_n < FLOOR:
        problems.append("min_n must be an integer of at least %d" % FLOOR)
        min_n = FLOOR
    if not is_time(data.get("generated_at")):
        problems.append("generated_at must be a plain UTC time")
    window = data.get("window")
    if not isinstance(window, dict) or set(window) != {"from", "to"}:
        problems.append("window must hold exactly from and to")
    else:
        for key in ("from", "to"):
            if not is_time(window[key]):
                problems.append("window.%s must be a plain UTC time" % key)
    cells = data.get("cells")
    if not isinstance(cells, list):
        return problems + ["cells must be a list"]
    for index, cell in enumerate(cells):
        problems += ["cells[%d]: %s" % (index, p) for p in cell_problems(cell, public, aliases, harnesses, min_n)]
    return problems


def cell_problems(cell, public, aliases, harnesses, min_n):
    if not isinstance(cell, dict):
        return ["not an object"]
    problems = []
    keys = set(cell)
    if not REQUIRED <= keys or not keys <= REQUIRED | OPTIONAL:
        problems.append("keys differ from the schema: %s" % sorted(keys ^ (REQUIRED | (keys & OPTIONAL))))
    model = cell.get("model")
    if not (isinstance(model, str) and MODEL.fullmatch(model) and (model in public or model in aliases)):
        problems.append("model is not a public or approved alias name")
    if cell.get("harness") not in harnesses:
        problems.append("harness is not a catalog kind")
    if cell.get("change_kind") not in KINDS:
        problems.append("change_kind is not one of the six kinds")
    for key in ("n", "confirmed", "refuted", "unresolved", "golden_n"):
        if not is_count(cell.get(key)):
            problems.append("%s must be a non-negative integer" % key)
    if all(is_count(cell.get(k)) for k in ("n", "confirmed", "refuted")):
        if cell["n"] != cell["confirmed"] + cell["refuted"]:
            problems.append("n must equal confirmed + refuted")
        if cell["n"] < min_n:
            problems.append("n is below min_n")
    for key in ("confirmed_share", "coverage", "golden_recall"):
        if key in cell and not is_unit(cell[key]):
            problems.append("%s must be a number in [0,1]" % key)
    if is_count(cell.get("golden_n")) and (cell["golden_n"] > 0) != ("golden_recall" in cell):
        problems.append("golden_recall needs golden_n > 0 and the reverse")
    for key in ("confirmed_share_ci", "coverage_ci"):
        if key in cell and not is_interval(cell[key]):
            problems.append("%s must be an ordered pair in [0,1]" % key)
    for key in ("median_seconds", "cost_per_confirmed_usd"):
        if key in cell and not (is_number(cell[key]) and cell[key] >= 0):
            problems.append("%s must be a non-negative number" % key)
    return problems


def load_list(path, key, field=None):
    entries = json.loads(Path(path).read_text("ascii"))[key]
    return entries if field is None else [e for e in entries if e.get("publishable") is True]


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("data")
    parser.add_argument("--models", default=str(HERE / "public-models.json"))
    parser.add_argument("--aliases", default=str(HERE / "public-aliases.json"))
    parser.add_argument("--harnesses", default=str(HERE / "harnesses.json"))
    args = parser.parse_args(argv)
    public = {m["id"] for m in load_list(args.models, "models", "publishable")}
    aliases = set(load_list(args.aliases, "aliases"))
    harnesses = set(load_list(args.harnesses, "harnesses"))
    try:
        data = json.loads(Path(args.data).read_text("ascii"), parse_constant=reject_constant)
    except (ValueError, OSError) as error:
        print("cannot read the data file: %s" % error)
        return 1
    problems = problems_in(data, public, aliases, harnesses)
    print("\n".join(problems) if problems else "ok")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
