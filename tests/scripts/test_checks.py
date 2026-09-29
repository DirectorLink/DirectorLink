"""The release checks themselves (scripts/build.py, check_package.py and check_repo.py): the relay's
CA file holds exactly the pinned roots however its blocks are written, nothing else in driver/certs
reaches the package, line endings do not change it, and check_repo vets what is staged.

    python -m unittest discover -s tests/scripts
"""

import base64
import contextlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import build  # noqa: E402
import check_package  # noqa: E402
import check_repo  # noqa: E402

CA_FILE = "certs/directorlink-roots.pem"
PEM = (ROOT / "driver" / CA_FILE).read_bytes().replace(b"\r\n", b"\n")
WEBSOCKET = (ROOT / "driver" / "src" / "cloud" / "websocket.lua").read_text(encoding="utf-8")
SPEC = {"openapi": "3.1.0", "info": {"title": "test", "version": "1.1.0"}}

# A block OpenSSL would load as one more trust anchor: any base64 body, as the checks never parse
# the certificate itself, only its SHA-256.
EXTRA = base64.encodebytes(b"a tenth root, not one of the pinned ones" * 3).decode("ascii")
# A key block with a made-up body, its markers split so no scanner takes this file for a key.
KEY_LABEL = "PRIVATE" + " KEY"
KEY = f"-----BEGIN {KEY_LABEL}-----\n" + base64.encodebytes(b"not a real key" * 4).decode("ascii") + f"-----END {KEY_LABEL}-----\n"


def refusal(check, *args):
    """The ERROR a check prints when it refuses, or None when it passes."""
    printed = io.StringIO()
    with contextlib.redirect_stderr(printed):
        try:
            check(*args)
        except SystemExit:
            return printed.getvalue()
    return None


def relay_roots(pem):
    return refusal(check_package.check_relay_roots, {"src/cloud/websocket.lua": WEBSOCKET, CA_FILE: pem})


class RelayRoots(unittest.TestCase):
    def test_the_real_file_passes(self):
        self.assertIsNone(relay_roots(PEM.decode("ascii")))

    def test_crlf_line_endings_read_like_lf(self):
        # A Windows checkout with core.autocrlf=true, before .gitattributes.
        self.assertIsNone(relay_roots(PEM.decode("ascii").replace("\n", "\r\n")))

    def test_every_block_openssl_would_load_is_counted(self):
        for begin, end in (
            ("-----BEGIN TRUSTED CERTIFICATE----- ", "-----END TRUSTED CERTIFICATE-----"),
            ("-----BEGIN TRUSTED CERTIFICATE-----", "-----END TRUSTED CERTIFICATE-----"),
            ("-----BEGIN X509 CERTIFICATE-----", "-----END X509 CERTIFICATE-----"),
            ("-----BEGIN CERTIFICATE----- ", "-----END CERTIFICATE-----"),
            ("-----BEGIN CERTIFICATE-----\t", "-----END CERTIFICATE-----"),
            ("-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----"),
        ):
            with self.subTest(begin=begin):
                pem = PEM.decode("ascii") + f"\n# Extra Root\n{begin}\n{EXTRA}{end}\n"
                self.assertIsNotNone(relay_roots(pem), "a tenth trust anchor passed")
                self.assertIsNotNone(relay_roots(pem.replace("\n", "\r\n")), "a tenth trust anchor passed with CRLF")

    def test_a_key_or_any_other_block_fails(self):
        for extra in (KEY, KEY.replace(f"-----BEGIN {KEY_LABEL}-----", f"-----BEGIN EC {KEY_LABEL}----- "), "-----BEGIN X509 CRL-----\nAAAA\n-----END X509 CRL-----\n"):
            with self.subTest(extra=extra.splitlines()[0]):
                self.assertIsNotNone(relay_roots(PEM.decode("ascii") + extra))
                self.assertIsNotNone(relay_roots((PEM.decode("ascii") + extra).replace("\n", "\r\n")))

    def test_a_root_missing_or_twice_fails(self):
        text = PEM.decode("ascii")
        first = text.index("# ISRG Root X1\n")
        block = text[first:text.index("-----END CERTIFICATE-----", first) + len("-----END CERTIFICATE-----\n")]
        self.assertIsNotNone(relay_roots(text.replace(block, "")))
        self.assertIsNotNone(relay_roots(text + "\n" + block))


class Build(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.driver = self.temp / "driver"
        shutil.copytree(ROOT / "driver", self.driver, ignore=shutil.ignore_patterns("tests"))
        self.saved = build.DRIVER
        build.DRIVER = self.driver

    def tearDown(self):
        build.DRIVER = self.saved
        shutil.rmtree(self.temp, ignore_errors=True)

    def entries(self):
        return build.package_entries("1.1.0", 10100, SPEC)

    def test_only_the_ca_file_is_packaged(self):
        certs = sorted(name for name in self.entries() if name.startswith("certs/"))
        self.assertEqual(certs, [CA_FILE])

    def test_anything_else_in_certs_stops_the_build(self):
        # Git ignores other .pem files, so git status would not show this one.
        (self.driver / "certs" / "local-test-key.pem").write_text(KEY, encoding="ascii")
        printed = refusal(self.entries)
        self.assertIsNotNone(printed, "a key in driver/certs was packaged")
        self.assertIn("local-test-key.pem", printed)

    def test_a_crlf_checkout_gives_the_same_package(self):
        path = self.driver / CA_FILE
        path.write_bytes(PEM.replace(b"\n", b"\r\n"))
        self.assertEqual(self.entries()[CA_FILE], PEM)

    def test_the_wrong_roots_package_trusts_one_root(self):
        pem = build.roots_only(PEM, "ISRG_Root_X1")
        self.assertEqual(check_package.pem_certificates(pem), [("ISRG Root X1", check_package.RELAY_ROOTS["ISRG Root X1"])])
        self.assertIsNotNone(check_package.relay_roots_problem(pem), "check_package would pass it as a release")
        self.assertIsNotNone(refusal(build.roots_only, PEM, "No Such Root"))


class StagedRoots(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        subprocess.run(["git", "init", "-q", str(self.temp)], check=True)
        (self.temp / "driver" / "certs").mkdir(parents=True)
        self.saved = check_repo.ROOT
        check_repo.ROOT = self.temp

    def tearDown(self):
        check_repo.ROOT = self.saved
        shutil.rmtree(self.temp, ignore_errors=True)

    def stage(self, staged, working):
        path = self.temp / "driver" / CA_FILE
        path.write_bytes(staged)
        subprocess.run(["git", "-c", "core.autocrlf=false", "add", "--", f"driver/{CA_FILE}"], check=True, cwd=self.temp)
        path.write_bytes(working)

    def test_a_key_staged_fails_even_when_the_working_file_is_clean(self):
        self.stage(PEM + KEY.encode("ascii"), PEM)
        self.assertIsNotNone(refusal(check_repo.main), "the staged key would be committed")

    def test_the_staged_roots_pass_whatever_the_working_file_holds(self):
        self.stage(PEM, PEM + KEY.encode("ascii"))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertIsNone(refusal(check_repo.main))


if __name__ == "__main__":
    unittest.main()
