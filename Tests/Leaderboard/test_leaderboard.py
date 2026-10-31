"""U14 acceptance contract. Run with Python isolated mode and stdlib only."""
import copy
import ast
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts" / "leaderboard"
FIXTURES = ROOT / "Tests" / "Fixtures" / "leaderboard"
TODAY = "2025-01-10"
CAVEAT = ("Self-reported from one owner's councils on their own repositories. "
          "Not a general benchmark.")


def snapshot(directory):
    return {str(p.relative_to(directory)): p.read_bytes()
            for p in directory.rglob("*") if p.is_file() and ".git" not in p.parts}


class LeaderboardAcceptance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="u14-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.valid = json.loads((FIXTURES / "valid.json").read_text("ascii"))

    def run_process(self, args, cwd=None, expected=0):
        result = subprocess.run([str(a) for a in args], cwd=cwd, text=True,
                                capture_output=True)
        if expected is not None:
            self.assertEqual(result.returncode, expected,
                             result.stdout + result.stderr)
        return result

    def write_data(self, value=None, directory=None):
        directory = directory or self.base
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "data.json"
        path.write_text(json.dumps(self.valid if value is None else value,
                                   sort_keys=True, indent=2) + "\n", "ascii")
        return path

    def validate(self, value, expected=1, extra=()):
        path = self.write_data(value)
        result = self.run_process([sys.executable, "-I", SCRIPTS / "validate.py",
                                   path, *extra], expected=expected)
        if expected == 1:
            self.assertTrue(result.stdout.strip(), "Problems must be printed")
        return result

    def render(self, value=None, out=None, today=TODAY):
        path = self.write_data(value)
        out = out or self.base / "out"
        self.run_process([sys.executable, "-I", SCRIPTS / "render.py",
                          "--data", path, "--out", out, "--today", today])
        return out

    def git(self, directory, *args):
        return self.run_process(["git", "-c", "user.name=maya",
                                 "-c", "user.email=maya@example.invalid",
                                 *args], cwd=directory).stdout.strip()

    def test_shared_valid_fixture(self):
        self.assertEqual(self.validate(self.valid, expected=0).stdout.strip(), "ok")

    def test_shared_unknown_key_fixture(self):
        self.validate(json.loads((FIXTURES / "unknown-key.json").read_text()))

    def test_shared_bad_model_fixture(self):
        self.validate(json.loads((FIXTURES / "bad-model.json").read_text()))

    def test_shared_low_n_fixture(self):
        self.validate(json.loads((FIXTURES / "low-n.json").read_text()))

    def test_shared_bad_sum_fixture(self):
        self.validate(json.loads((FIXTURES / "bad-sum.json").read_text()))

    def test_shared_bad_kind_fixture(self):
        self.validate(json.loads((FIXTURES / "bad-kind.json").read_text()))

    def test_required_top_level_keys(self):
        for key in self.valid:
            with self.subTest(key=key):
                value = copy.deepcopy(self.valid)
                del value[key]
                self.validate(value)

    def test_window_allowlist_and_required_keys(self):
        for key in ("from", "to", "unknown"):
            with self.subTest(key=key):
                value = copy.deepcopy(self.valid)
                if key == "unknown":
                    value["window"][key] = "private"
                else:
                    del value["window"][key]
                self.validate(value)

    def test_required_cell_keys(self):
        optional = {"coverage", "coverage_ci", "golden_recall",
                    "median_seconds", "cost_per_confirmed_usd"}
        for key in self.valid["cells"][0].keys() - optional:
            with self.subTest(key=key):
                value = copy.deepcopy(self.valid)
                del value["cells"][0][key]
                self.validate(value)

    def test_unknown_cell_key_rejected(self):
        value = copy.deepcopy(self.valid)
        value["cells"][0]["claim_text"] = "private claim text"
        self.validate(value)

    def test_optional_values_omitted(self):
        value = copy.deepcopy(self.valid)
        for key in ("coverage", "coverage_ci", "golden_recall",
                    "median_seconds", "cost_per_confirmed_usd"):
            value["cells"][0].pop(key, None)
        value["cells"][0]["golden_n"] = 0
        self.validate(value, expected=0)

    def test_schema_and_minimum_and_total(self):
        for key, bad in (("schema", 2), ("schema", True), ("min_n", 9),
                         ("min_n", 10.5), ("outcomes_total", -1)):
            with self.subTest(key=key, value=bad):
                value = copy.deepcopy(self.valid)
                value[key] = bad
                self.validate(value)

    def test_counts_are_nonnegative_integers(self):
        for key in ("n", "confirmed", "refuted", "unresolved", "golden_n"):
            for bad in (-1, 0.5, True, "20", None):
                with self.subTest(key=key, value=bad):
                    value = copy.deepcopy(self.valid)
                    value["cells"][0][key] = bad
                    self.validate(value)

    def test_shares_and_recalls_are_bounded(self):
        for key in ("confirmed_share", "coverage", "golden_recall"):
            for bad in (-0.01, 1.01, "0.5", True):
                with self.subTest(key=key, value=bad):
                    value = copy.deepcopy(self.valid)
                    value["cells"][0][key] = bad
                    self.validate(value)

    def test_intervals_are_two_ordered_bounded_numbers(self):
        for key in ("confirmed_share_ci", "coverage_ci"):
            for bad in ([0], [0, 1, 1], [0.8, 0.2], [-0.1, 1], [0, 1.1], ["0", 1]):
                with self.subTest(key=key, value=bad):
                    value = copy.deepcopy(self.valid)
                    value["cells"][0][key] = bad
                    self.validate(value)

    def test_all_six_change_kinds(self):
        for kind in ("auth", "schema", "ui", "refactor", "infra", "other"):
            value = copy.deepcopy(self.valid)
            value["cells"][0]["change_kind"] = kind
            self.validate(value, expected=0)

    def test_harness_catalog_kinds_only(self):
        catalog = json.loads((ROOT / "Sources/AgencilCore/Harness/catalog.json").read_text())
        for kind in [e["kind"] for e in catalog["entries"]] + ["unknown"]:
            value = copy.deepcopy(self.valid)
            value["cells"][0]["harness"] = kind
            self.validate(value, expected=1 if kind == "unknown" else 0)

    def test_model_pattern_and_private_names(self):
        for model in ("client-project", "harbor/model", "harbor\\model", "UPPER",
                      "x" * 65, "", "private\nmodel", "m\u00e9del"):
            with self.subTest(model=model):
                value = copy.deepcopy(self.valid)
                value["cells"][0]["model"] = model
                self.validate(value)

    def test_strings_reject_paths_controls_and_non_ascii(self):
        for text in ("harbor/checkout", "harbor\\checkout", "x\ny", "x\x00y", "x\u00e9y"):
            value = copy.deepcopy(self.valid)
            value["generated_at"] = text
            self.validate(value)

    def test_custom_models_aliases_and_harness_files(self):
        models, aliases, harnesses = (self.base / name for name in
                                      ("models.json", "aliases.json", "harnesses.json"))
        models.write_text(json.dumps({"models": [
            {"id": "qwen3:32b", "provider": "harbor", "publishable": False}]}))
        aliases.write_text(json.dumps({"aliases": ["harbor-model"]}))
        harnesses.write_text(json.dumps({"harnesses": ["codex"]}))
        extra = ("--models", models, "--aliases", aliases, "--harnesses", harnesses)
        for model, status in (("harbor-model", 0), ("qwen3:32b", 1), ("gpt-5.x-codex", 1)):
            value = copy.deepcopy(self.valid)
            value["cells"][0]["model"] = model
            self.validate(value, expected=status, extra=extra)

    def test_default_public_lists_and_catalog_agree(self):
        models = json.loads((SCRIPTS / "public-models.json").read_text("ascii"))["models"]
        available = {m["id"] for m in models if m["publishable"] is True}
        self.assertTrue({"gpt-5.x-codex", "qwen3:32b"} <= available)
        self.assertNotIn("client-project", available)
        aliases = json.loads((SCRIPTS / "public-aliases.json").read_text("ascii"))["aliases"]
        for alias in aliases:
            self.assertRegex(alias, r"^[a-z0-9][a-z0-9._:-]{0,63}$")
        catalog = json.loads((ROOT / "Sources/AgencilCore/Harness/catalog.json").read_text())
        harnesses = json.loads((SCRIPTS / "harnesses.json").read_text("ascii"))["harnesses"]
        self.assertEqual(set(harnesses), {e["kind"] for e in catalog["entries"]})

    def test_python_tools_use_only_standard_library(self):
        local = {p.stem for p in SCRIPTS.glob("*.py")}
        for name in ("validate.py", "render.py"):
            tree = ast.parse((SCRIPTS / name).read_text("ascii"))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    modules = [a.name.split(".")[0] for a in node.names]
                elif isinstance(node, ast.ImportFrom) and node.module:
                    modules = [node.module.split(".")[0]]
                else:
                    continue
                for module in modules:
                    self.assertIn(module, sys.stdlib_module_names | local)

    def test_validator_reports_malformed_json_as_failure(self):
        path = self.base / "data.json"
        path.write_text("{invalid")
        result = self.run_process([sys.executable, "-I", SCRIPTS / "validate.py", path], expected=1)
        self.assertTrue(result.stdout.strip())

    def test_renderer_handles_empty_cells_without_fabricating_rates(self):
        value = copy.deepcopy(self.valid)
        value["cells"] = []
        value["outcomes_total"] = 0
        out = self.render(value)
        for theme in ("dark", "light"):
            text = " ".join(ET.parse(out / ("leaderboard-" + theme + ".svg")).getroot().itertext())
            self.assertIn("0 outcomes", text)
            self.assertNotIn("gpt-5.x-codex", text)

    def test_non_golden_recall_is_not_a_published_field(self):
        value = copy.deepcopy(self.valid)
        value["cells"][0]["recall"] = 0.5
        self.validate(value)

    def test_renderer_outputs_dimensions_ascii_and_history_copy(self):
        out = self.render()
        for theme in ("dark", "light"):
            raw = (out / ("leaderboard-" + theme + ".svg")).read_bytes()
            raw.decode("ascii")
            svg = ET.fromstring(raw)
            self.assertEqual(svg.attrib["width"], "880")
            self.assertEqual(svg.attrib["height"], "360")
            text = " ".join(svg.itertext())
            self.assertIn("updated 2025-01-01, 20 outcomes", text)
        self.assertEqual((out / "history" / (TODAY + ".json")).read_bytes(),
                         (self.base / "data.json").read_bytes())
        self.assertTrue((out / "LEADERBOARD.md").is_file())

    def test_renderer_is_deterministic(self):
        first = self.render(out=self.base / "one")
        second = self.render(out=self.base / "two")
        self.assertEqual(snapshot(first), snapshot(second))

    def test_renderer_has_no_input_order_dependency(self):
        value = copy.deepcopy(self.valid)
        other = copy.deepcopy(value["cells"][0])
        other["model"] = "qwen3:32b"
        value["cells"].append(other)
        first = snapshot(self.render(value, out=self.base / "one"))
        value["cells"].reverse()
        second = snapshot(self.render(value, out=self.base / "two"))
        # History must remain an exact input copy, including its ordering.
        for files in (first, second):
            files.pop("history/" + TODAY + ".json")
        self.assertEqual(first, second)

    def test_card_top_eight_by_lower_interval_bound_table_keeps_all(self):
        value = copy.deepcopy(self.valid)
        value["cells"] = []
        kinds = ["auth", "schema", "ui", "refactor", "infra", "other"]
        for index in range(10):
            cell = copy.deepcopy(self.valid["cells"][0])
            cell["model"] = "gpt-5.x-codex" if index < 6 else "qwen3:32b"
            cell["change_kind"] = kinds[index % 6]
            cell["confirmed_share_ci"] = [round(0.01 + index * 0.04, 2), 0.9]
            value["cells"].append(cell)
        out = self.render(value)
        for theme in ("dark", "light"):
            svg = ET.parse(out / ("leaderboard-" + theme + ".svg"))
            text = " ".join(svg.getroot().itertext())
            self.assertEqual(text.count("gpt-5.x-codex") + text.count("qwen3:32b"), 8)
            self.assertEqual(text.count("gpt-5.x-codex"), 4)
        table = (out / "LEADERBOARD.md").read_text("ascii")
        self.assertEqual(table.count("gpt-5.x-codex"), 6)
        self.assertEqual(table.count("qwen3:32b"), 4)

    def test_method_caveat_and_unresolved_rate_exclusion(self):
        text = (self.render() / "LEADERBOARD.md").read_text("ascii")
        self.assertIn(CAVEAT, text)
        self.assertRegex(text.lower(), r"unresolved[^.\n]*(?:no rate|none|excluded|do not count)")
        for word in ("wilson", "coverage", "golden", "window", "outcome"):
            self.assertIn(word, text.lower())

    def test_staleness_warn_boundary(self):
        for today, stale in (("2025-01-08", False), ("2025-01-09", True)):
            out = self.render(out=self.base / today, today=today)
            for theme in ("dark", "light"):
                svg = ET.parse(out / ("leaderboard-" + theme + ".svg"))
                dates = [e for e in svg.iter() if "2025-01-01" in (e.text or "")]
                self.assertTrue(dates)
                self.assertEqual(any("warn" in e.attrib.get("class", "").split()
                                         for e in dates), stale)

    def test_history_retention_boundary(self):
        out = self.base / "out"
        history = out / "history"
        history.mkdir(parents=True)
        now = datetime.date.fromisoformat(TODAY)
        for days in (364, 365, 366):
            (history / ((now - datetime.timedelta(days=days)).isoformat() + ".json")).write_text("{}")
        self.render(out=out)
        for days in (364, 365, 366):
            self.assertEqual((history / ((now - datetime.timedelta(days=days)).isoformat() + ".json")).exists(), days <= 365)

    def make_checkouts(self):
        main, data = self.base / "main", self.base / "leaderboard"
        main.mkdir()
        self.git(main, "init", "-b", "main")
        trusted = main / "scripts" / "leaderboard"
        trusted.mkdir(parents=True)
        for source in SCRIPTS.iterdir():
            if source.is_file():
                target = trusted / source.name
                target.write_bytes(source.read_bytes())
                target.chmod(source.stat().st_mode)
        (main / "README.md").write_text("harbor/checkout\n")
        self.git(main, "add", ".")
        self.git(main, "commit", "-m", "test: fixture")
        self.git(main, "worktree", "add", "--orphan", "-b", "leaderboard", data)
        self.write_data(directory=data)
        return main, data

    def test_run_render_separate_checkout_never_changes_main(self):
        main, data = self.make_checkouts()
        before, head = snapshot(main), self.git(main, "rev-parse", "HEAD")
        self.run_process(["bash", SCRIPTS / "run-render.sh", main, data, TODAY])
        self.assertEqual(snapshot(main), before)
        self.assertEqual(self.git(main, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(main, "status", "--porcelain"), "")
        for name in ("leaderboard-dark.svg", "leaderboard-light.svg", "LEADERBOARD.md", "history/" + TODAY + ".json"):
            self.assertTrue((data / name).is_file())

    def test_invalid_run_render_writes_nothing_in_either_checkout(self):
        main, data = self.make_checkouts()
        self.write_data(json.loads((FIXTURES / "unknown-key.json").read_text()), data)
        before = snapshot(main), snapshot(data)
        result = self.run_process(["bash", SCRIPTS / "run-render.sh", main, data, TODAY], expected=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((snapshot(main), snapshot(data)), before)

    def test_bootstrap_orphan_empty_data_rendered_files_and_no_push(self):
        directory = self.base / "bootstrap"
        result = self.run_process(["bash", SCRIPTS / "bootstrap.sh", directory])
        self.assertEqual(self.git(directory, "branch", "--show-current"), "leaderboard")
        self.assertEqual(self.git(directory, "rev-list", "--max-parents=0", "HEAD"),
                         self.git(directory, "rev-parse", "HEAD"))
        self.assertEqual(self.git(directory, "remote"), "")
        data = json.loads((directory / "data.json").read_text("ascii"))
        self.assertEqual(data["cells"], [])
        self.assertEqual(data["outcomes_total"], 0)
        self.assertRegex(result.stdout, r"git push[^\n]*leaderboard")
        self.assertEqual(len(re.findall(r"git push[^\n]*", result.stdout)), 1)
        for name in ("leaderboard-dark.svg", "leaderboard-light.svg", "LEADERBOARD.md"):
            self.assertTrue((directory / name).is_file())
        self.assertFalse((directory / ".github").exists())

    def workflow(self):
        return (ROOT / ".github/workflows/leaderboard.yml").read_text("ascii")

    def test_workflow_manual_and_nightly_triggers_only(self):
        text = self.workflow()
        self.assertRegex(text, r"(?m)^\s+workflow_dispatch\s*:")
        self.assertRegex(text, r"(?m)^\s+schedule\s*:")
        self.assertRegex(text, r"cron\s*:")
        self.assertRegex(text, r"cron\s*:\s*['\"][0-9*/,-]+\s+[0-9]+\s+\*\s+\*\s+\*['\"]")
        self.assertNotRegex(text, r"(?m)^\s*(push|pull_request|pull_request_target)\s*:")

    def test_workflow_serializes_without_cancellation(self):
        text = self.workflow()
        self.assertRegex(text, r"(?m)^concurrency:\s*\n\s+group:\s*['\"]?leaderboard['\"]?\s*\n\s+cancel-in-progress:\s*false")

    def test_workflow_contents_write_only(self):
        text = self.workflow()
        match = re.search(r"(?m)^permissions:\s*\n((?:[ \t]+[^\n]*\n)+)", text)
        self.assertIsNotNone(match)
        entries = re.findall(r"(?m)^\s+([\w-]+):\s*(\w+)", match.group(1))
        self.assertEqual(entries, [("contents", "write")])

    def test_workflow_all_actions_pinned(self):
        uses = re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", self.workflow())
        self.assertTrue(uses)
        for action in uses:
            self.assertRegex(action, r"^[^@]+@[0-9a-fA-F]{40}$")

    def test_workflow_two_checkouts_trusted_renderer_and_bot_commit(self):
        text = self.workflow()
        blocks = re.split(r"(?m)^\s*-\s+(?:name|uses):", text)
        checkouts = [b for b in blocks if "actions/checkout@" in b]
        self.assertEqual(len(checkouts), 2)
        paths = []
        for ref in ("main", "leaderboard"):
            block = next(b for b in checkouts if re.search(r"ref:\s*['\"]?" + ref + r"['\"]?\s*(?:\n|$)", b))
            paths.append(re.search(r"path:\s*['\"]?([\w/-]+)", block).group(1))
        self.assertNotEqual(paths[0], paths[1])
        self.assertIn("scripts/leaderboard/run-render.sh", text)
        self.assertIn("github-actions[bot]", text)
        self.assertRegex(text, r"git diff[^\n]*(?:--quiet|--exit-code)")
        commit = next(b for b in blocks if "git commit" in b)
        self.assertTrue("working-directory: " + paths[1] in commit
                        or "cd " + paths[1] in commit
                        or "git -C " + paths[1] in commit)


if __name__ == "__main__":
    unittest.main()
