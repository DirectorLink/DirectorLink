"""The Jewish calendar's checks (1.2.0, ADR-037): check_package.py refuses a calendar file that
could reach the network, and driver/tests/run.lua runs only the suites it is given (CI runs the
calendar's suites again in two time zones) and splits them into CI's parts of about equal time,
every test in exactly one part.

    python -m unittest discover -s tests/scripts
"""

import contextlib
import io
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import check_package  # noqa: E402
import yaml  # noqa: E402

# The full path: on Windows "lua5.1" reads as a name with an extension, which CreateProcess takes as is.
LUA = shutil.which("lua5.1")

NETWORK_CALLS = (
    'C4:urlGet("https://example.com/", {}, false, function() end)',
    "C4 : urlPost(url, body)",
    "C4.urlGet(C4, url)",
    'C4:CreateNetworkConnection(6001, "example.com", "TCP")',
    'C4:SendToNetwork(6001, 80, "GET / HTTP/1.1")',
)


def refusal(check, *args):
    """The ERROR a check prints when it refuses, or None when it passes."""
    printed = io.StringIO()
    with contextlib.redirect_stderr(printed):
        try:
            check(*args)
        except SystemExit:
            return printed.getvalue()
    return None


def calendar_files():
    return {name: (ROOT / "driver" / name).read_text(encoding="utf-8") for name in check_package.CALENDAR_ENGINE}


class CalendarPrivacy(unittest.TestCase):
    def test_the_calendar_files_pass(self):
        self.assertIsNone(refusal(check_package.check_calendar_privacy, calendar_files()))

    def test_a_network_call_in_any_calendar_file_fails(self):
        for name in check_package.CALENDAR_ENGINE + (check_package.CALENDAR_SERVICE,):
            for call in NETWORK_CALLS:
                with self.subTest(name=name, call=call):
                    files = calendar_files()
                    files[name] = files.get(name, "") + "\n" + call + "\n"
                    printed = refusal(check_package.check_calendar_privacy, files)
                    self.assertIsNotNone(printed, "a calendar file that reaches the network passed")
                    self.assertIn(name, printed)

    def test_the_service_is_guarded_by_name(self):
        # jewish_calendar.lua comes from another branch: absent it passes, with a network call it fails.
        files = calendar_files()
        files.pop(check_package.CALENDAR_SERVICE, None)
        self.assertIsNone(refusal(check_package.check_calendar_privacy, files))
        files[check_package.CALENDAR_SERVICE] = "local JewishCalendar = {}\nreturn JewishCalendar\n"
        self.assertIsNone(refusal(check_package.check_calendar_privacy, files))
        files[check_package.CALENDAR_SERVICE] += "C4:urlGet(url)\n"
        self.assertIsNotNone(refusal(check_package.check_calendar_privacy, files))

    def test_a_missing_engine_file_fails(self):
        files = calendar_files()
        del files["src/core/holy_times.lua"]
        self.assertIn("src/core/holy_times.lua is missing", refusal(check_package.check_calendar_privacy, files) or "")

    def test_other_files_may_use_the_network(self):
        files = calendar_files()
        files["src/core/weather.lua"] = "C4:urlGet(url)\n"
        self.assertIsNone(refusal(check_package.check_calendar_privacy, files))

    def test_the_package_check_runs_it(self):
        source = (ROOT / "scripts" / "check_package.py").read_text(encoding="utf-8")
        main = source[source.index("def main():"):]
        self.assertIn("check_calendar_privacy(files)", main)


def run_lua_tables():
    """driver/tests/run.lua's suites, the seconds it lists for each, and its DEFAULT_SECONDS."""
    source = (ROOT / "driver" / "tests" / "run.lua").read_text(encoding="utf-8")
    start = source.index("local suites = {")
    listed = re.findall(r'^    "(test_\w+)",$', source[start:source.index("}", start)], re.M)
    seconds = {name: int(value) for name, value in re.findall(r"^    (test_\w+) = (\d+),$", source, re.M)}
    default = int(re.search(r"^local DEFAULT_SECONDS = (\d+)$", source, re.M).group(1))
    return listed, seconds, default


@unittest.skipUnless(LUA, "lua5.1 is not installed")
class DriverTestRunner(unittest.TestCase):
    def run_suites(self, *names):
        return subprocess.run([LUA, "driver/tests/run.lua", *names], cwd=ROOT, capture_output=True, text=True, timeout=300)

    def test_it_runs_only_the_suites_named(self):
        counts = {
            name: len(re.findall(r"^function tests\.", (ROOT / "driver" / "tests" / f"{name}.lua").read_text(encoding="utf-8"), re.M))
            for name in ("test_json", "test_router")
        }
        result = self.run_suites("test_json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"{counts['test_json']} passed, 0 failed", result.stdout)
        result = self.run_suites("test_json", "test_router")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"{counts['test_json'] + counts['test_router']} passed, 0 failed", result.stdout)

    def test_an_unknown_suite_fails(self):
        result = self.run_suites("test_json", "test_no_such_suite")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown suite test_no_such_suite", result.stdout)
        self.assertNotIn("passed", result.stdout, "nothing ran")

    # CI runs the suites in parts at once (.github/workflows/validate.yml): every test in exactly
    # one part, and no part much longer than the others by the times run.lua lists.
    def test_the_parts_run_every_suite_once(self):
        listed, seconds, default = run_lua_tables()
        job = yaml.safe_load((ROOT / ".github" / "workflows" / "validate.yml").read_text(encoding="utf-8"))["jobs"]["driver-tests"]
        count = len(job["strategy"]["matrix"]["part"])
        self.assertEqual(job["strategy"]["matrix"]["part"], list(range(1, count + 1)))
        self.assertIn(f"lua5.1 driver/tests/run.lua --shard ${{{{ matrix.part }}}}/{count}", [step.get("run") for step in job["steps"]])
        pieces, times = {}, []
        for index in range(1, count + 1):
            result = self.run_suites("--shard", f"{index}/{count}", "--list")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(result.stdout.split(), f"part {index} is empty")
            time = 0
            for entry in result.stdout.split():
                name, _, piece = entry.partition(":")
                piece, of = (int(number) for number in piece.split("/")) if piece else (1, 1)
                pieces.setdefault(name, []).append((piece, of))
                time += seconds.get(name, default) / of
            times.append(time)
        self.assertEqual(sorted(pieces), sorted(listed))
        for name, got in pieces.items():
            self.assertEqual(sorted(got), [(piece, got[0][1]) for piece in range(1, got[0][1] + 1)], name)
        self.assertLessEqual(max(times), 1.15 * sum(times) / count, f"seconds in each part: {times}")

    # A suite longer than a part should be (test_backup in six parts) is cut into pieces, its tests
    # dealt out in turn: here the quickest suite that is longer than another, in two parts.
    def test_a_suite_longer_than_a_part_is_cut_into_pieces(self):
        _, seconds, _ = run_lua_tables()
        small = min(seconds, key=lambda name: (seconds[name], name))
        cut = min((name for name in seconds if seconds[name] > seconds[small]), key=lambda name: (seconds[name], name))
        parts = [self.run_suites("--shard", f"{index}/2", "--list", cut, small).stdout.split() for index in (1, 2)]
        self.assertTrue(all(parts), parts)
        self.assertEqual(sorted(parts[0] + parts[1]), sorted([f"{cut}:1/2", f"{cut}:2/2", small]))
        whole = self.run_suites(cut, small)
        self.assertEqual(whole.returncode, 0, whole.stdout + whole.stderr)
        counts = []
        for index in (1, 2):
            result = self.run_suites("--shard", f"{index}/2", cut, small)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"part {index}/2: {' '.join(parts[index - 1])}\n", result.stdout)
            counts.append(int(re.search(r"^(\d+) passed, 0 failed", result.stdout, re.M).group(1)))
        self.assertTrue(all(counts), counts)
        self.assertIn(f"{sum(counts)} passed, 0 failed", whole.stdout)

    def test_a_part_of_the_named_suites_runs_only_those(self):
        result = self.run_suites("--shard", "1/2", "test_json", "test_http", "test_router")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("part 1/2: test_json test_router\n", result.stdout)
        counts = sum(
            len(re.findall(r"^function tests\.", (ROOT / "driver" / "tests" / f"{name}.lua").read_text(encoding="utf-8"), re.M))
            for name in ("test_json", "test_router")
        )
        self.assertIn(f"{counts} passed, 0 failed", result.stdout)
        result = self.run_suites("--shard", "2/2", "--list", "test_json", "test_http", "test_router")
        self.assertEqual(result.stdout.split(), ["test_http"])

    def test_a_bad_part_fails(self):
        for part in ("0/3", "4/3", "1", "a/b"):
            result = self.run_suites("--shard", part)
            self.assertEqual(result.returncode, 1, part)
            self.assertIn("--shard takes K/N", result.stdout)
            self.assertNotIn("passed", result.stdout, "nothing ran")
        result = self.run_suites("--shard")
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()
