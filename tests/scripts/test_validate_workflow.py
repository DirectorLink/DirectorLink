"""Validate DirectorLink's own scripts (.github/workflows/validate.yml, ADR-075, 2026-10-10), run
here as GitHub runs them: "changes" skips the driver, time-zone, app and cloud tests only when a
pull request (or a push to a dev/ branch) changes nothing but the website and the docs, never on a
push to main, and runs everything when in doubt; the last job, "validate", passes only when every
job passed, or was skipped because "changes" said so.

    python -m unittest discover -s tests/scripts
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
VALIDATE = yaml.safe_load((ROOT / ".github" / "workflows" / "validate.yml").read_text(encoding="utf-8"))
DECIDE = next(step for step in VALIDATE["jobs"]["changes"]["steps"] if step.get("id") == "decide")
AGGREGATE = VALIDATE["jobs"]["validate"]["steps"][0]


def working_bash():
    """A bash that runs: on Windows, Git's (System32's bash.exe starts WSL, often not installed)."""
    path = shutil.which("bash")
    try:
        ok = path and subprocess.run([path, "-c", "echo ok"], capture_output=True, text=True, timeout=30).stdout.strip() == "ok"
    except (OSError, subprocess.SubprocessError):
        ok = False
    return path if ok else None


BASH = working_bash()
GIT = shutil.which("git")
# As GitHub runs a step without `shell:`.
STEP_SHELL = ["-e"]


@unittest.skipUnless(BASH and GIT, "bash and git are needed")
class ChangesDecidesWhetherTheTestsRun(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.env = {
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"),
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        (self.root / "gitconfig").write_text("[core]\n\tautocrlf = false\n[init]\n\tdefaultBranch = main\n", encoding="utf-8")
        (self.root / "decide.sh").write_text(DECIDE["run"], encoding="utf-8", newline="\n")
        self.origin = self.root / "origin.git"
        self.git(self.root, "init", "-q", "--bare", str(self.origin))
        seed = self.root / "seed"
        self.git(self.root, "init", "-q", str(seed))
        for path in ("driver/a.lua", "docs/d.md", "site/s.html", "README.md", "VERSION"):
            self.write(seed, path)
        self.commit(seed, "base")
        self.git(seed, "push", "-q", str(self.origin), "HEAD:refs/heads/main")
        self.clones = 0

    def git(self, cwd, *args):
        return subprocess.run([GIT, *args], cwd=cwd, env=self.env, check=True, capture_output=True, text=True).stdout

    def write(self, clone, path, text="changed\n"):
        (clone / path).parent.mkdir(parents=True, exist_ok=True)
        with open(clone / path, "a", encoding="utf-8", newline="\n") as file:
            file.write(text)

    def commit(self, clone, message):
        self.git(clone, "add", "-A")
        self.git(clone, "commit", "-q", "--allow-empty", "-m", message)

    def clone(self):
        self.clones += 1
        clone = self.root / f"clone{self.clones}"
        self.git(self.root, "clone", "-q", str(self.origin), str(clone))
        return clone

    def decide(self, clone, event, ref):
        output = self.root / "output"
        output.write_text("", encoding="utf-8")
        env = {
            **self.env,
            "GITHUB_EVENT_NAME": event,
            "GITHUB_REF": ref,
            "GITHUB_OUTPUT": output.as_posix(),
            "GITHUB_STEP_SUMMARY": (self.root / "summary").as_posix(),
            **DECIDE["env"],
        }
        result = subprocess.run([BASH, *STEP_SHELL, (self.root / "decide.sh").as_posix()], cwd=clone, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        said = [line for line in output.read_text(encoding="utf-8").splitlines() if line.startswith("tests=")]
        self.assertEqual(len(said), 1, result.stdout)
        return said[0] == "tests=true"

    def pull_request(self, change):
        """The decision for a pull request's merge commit, as GitHub checks it out."""
        clone = self.clone()
        self.git(clone, "checkout", "-q", "-b", "topic")
        change(clone)
        self.commit(clone, "change")
        self.git(clone, "checkout", "-q", "--detach", "origin/main")
        self.git(clone, "merge", "-q", "--no-ff", "--no-edit", "topic")
        return self.decide(clone, "pull_request", "refs/pull/1/merge")

    def test_only_the_website_and_the_docs_skip_the_tests(self):
        self.assertFalse(self.pull_request(lambda clone: self.write(clone, "docs/d.md")))
        self.assertFalse(self.pull_request(lambda clone: [self.write(clone, path) for path in ("site/s.html", "README.md", "docs/new.md", "github-link/worker.js")]))

    def test_anything_else_runs_them(self):
        for path in ("driver/a.lua", "VERSION", "app/x.js", "cloud/src/index.js", "tests/app/x.test.mjs", "scripts/build.py",
                     ".github/workflows/validate.yml", "api/openapi.yaml", "console/index.html", "app/docs/README.md"):
            with self.subTest(path=path):
                self.assertTrue(self.pull_request(lambda clone: [self.write(clone, "docs/d.md"), self.write(clone, path)]))

    def test_a_file_moved_or_deleted_counts_where_it_was(self):
        self.assertTrue(self.pull_request(lambda clone: self.git(clone, "mv", "driver/a.lua", "docs/a.lua")))
        self.assertTrue(self.pull_request(lambda clone: self.git(clone, "rm", "-q", "driver/a.lua")))

    def test_when_in_doubt_everything_runs(self):
        # Nothing changed, or not a merge commit.
        self.assertTrue(self.pull_request(lambda clone: None))
        clone = self.clone()
        self.write(clone, "docs/d.md")
        self.commit(clone, "docs")
        self.assertTrue(self.decide(clone, "pull_request", "refs/pull/2/merge"))

    def test_a_push_to_main_runs_everything(self):
        clone = self.clone()
        self.write(clone, "docs/d.md")
        self.commit(clone, "docs")
        self.assertTrue(self.decide(clone, "push", "refs/heads/main"))

    def test_a_push_to_a_dev_branch_is_compared_with_main(self):
        clone = self.clone()
        self.git(clone, "checkout", "-q", "-b", "dev/docs")
        self.write(clone, "docs/d.md")
        self.commit(clone, "docs")
        self.assertFalse(self.decide(clone, "push", "refs/heads/dev/docs"))
        # main has moved on with a driver change the branch lacks
        other = self.clone()
        self.write(other, "driver/a.lua")
        self.commit(other, "driver")
        self.git(other, "push", "-q", "origin", "HEAD:main")
        self.assertTrue(self.decide(clone, "push", "refs/heads/dev/docs"))
        # main cannot be fetched
        self.git(clone, "remote", "set-url", "origin", (self.root / "nowhere.git").as_posix())
        self.assertTrue(self.decide(clone, "push", "refs/heads/dev/docs"))


@unittest.skipUnless(BASH, "bash is needed")
class ValidatePassesOnlyWhenEveryJobDidItsPart(unittest.TestCase):
    def passes(self, run_tests, decision, changes="success", checks="success", tests=("success", "success", "success")):
        env = {
            **os.environ,
            "NEEDS": "{}",
            "DECISION": decision,
            "RUN_TESTS": run_tests,
            "ALWAYS": f"changes={changes} checks={checks}",
            "TESTS": " ".join(f"{job}={result}" for job, result in zip(("driver-tests", "time-zones", "app-and-cloud"), tests)),
        }
        result = subprocess.run([BASH, *STEP_SHELL, "-c", AGGREGATE["run"]], env=env, capture_output=True, text=True, timeout=60)
        return result.returncode == 0

    def test_every_job_passed(self):
        self.assertTrue(self.passes("true", "true"))

    def test_the_tests_skipped_for_the_website_and_the_docs(self):
        self.assertTrue(self.passes("false", "false", tests=("skipped", "skipped", "skipped")))

    def test_a_job_that_failed_was_cancelled_or_was_skipped_when_it_should_have_run(self):
        self.assertFalse(self.passes("true", "true", tests=("failure", "success", "success")))
        self.assertFalse(self.passes("true", "true", tests=("success", "cancelled", "success")))
        self.assertFalse(self.passes("true", "true", tests=("success", "success", "skipped")))
        self.assertFalse(self.passes("true", "false", tests=("skipped", "skipped", "skipped")))
        self.assertFalse(self.passes("false", "false", checks="failure", tests=("skipped", "skipped", "skipped")))
        self.assertFalse(self.passes("false", "false", checks="cancelled", tests=("skipped", "skipped", "skipped")))

    def test_changes_must_pass_and_say_true_or_false(self):
        self.assertFalse(self.passes("false", "", changes="failure", tests=("skipped", "skipped", "skipped")))
        self.assertFalse(self.passes("false", "", tests=("skipped", "skipped", "skipped")))
        self.assertFalse(self.passes("false", "maybe", tests=("skipped", "skipped", "skipped")))


if __name__ == "__main__":
    unittest.main()
