"""The Jewish calendar's checks (1.2.0, ADR-037): check_package.py refuses a calendar file that
could reach the network, and driver/tests/run.lua runs only the suites it is given (CI runs the
calendar's suites again in two time zones).

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


if __name__ == "__main__":
    unittest.main()
