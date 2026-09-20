import json
from pathlib import Path
import tempfile
import unittest

from reports import SIGNED_KEYCHAIN_TEST, normalize_lcov, verify_results


class ResultTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text(json.dumps({"Module.Suite": ["one()"]}))
        self.report = self.root / "results.xml"

    def verify(self, cases, *, unsigned=False):
        self.report.write_text(f"<testsuites><testsuite>{cases}</testsuite></testsuites>")
        return verify_results(self.report, self.inventory, allow_unsigned_keychain_skip=unsigned)

    def test_exact_success(self):
        self.assertEqual(self.verify('<testcase classname="Module.Suite" name="one()"/>'), (1, 0))

    def test_empty_overwritten_report(self):
        with self.assertRaises(ValueError):
            self.verify("")

    def test_duplicate_or_wrong_suite(self):
        case = '<testcase classname="Module.Suite" name="one()"/>'
        for cases in (case + case, case.replace("Module.Suite", "Other.Suite")):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                self.verify(cases)

    def test_failure_error_and_unexpected_skip(self):
        for child in ("failure", "error", "skipped"):
            for unsigned in (False, True):
                with self.subTest(child=child, unsigned=unsigned), self.assertRaises(ValueError):
                    self.verify(f'<testcase classname="Module.Suite" name="one()"><{child}/></testcase>', unsigned=unsigned)

    def test_keychain_skip_requires_explicit_unsigned_lane(self):
        suite, name = SIGNED_KEYCHAIN_TEST
        self.inventory.write_text(json.dumps({suite: [name]}))
        case = f'<testcase classname="{suite}" name="{name}">'
        self.assertEqual(self.verify(case + '</testcase>'), (1, 0))
        skipped = case + '<skipped>Synchronizable Keychain requires the signed host lane</skipped></testcase>'
        with self.assertRaises(ValueError):
            self.verify(skipped)
        self.assertEqual(self.verify(skipped, unsigned=True), (0, 1))
        with self.assertRaises(ValueError):
            self.verify(case + '<skipped>unrelated condition</skipped></testcase>', unsigned=True)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()

    def record(self, source, hits=1):
        return f"SF:{self.root / source}\nDA:1,{hits}\nLF:1\nLH:{int(hits > 0)}\nend_of_record\n"

    def test_normalizes_and_excludes_dependencies_and_tests(self):
        raw = self.record("Sources/BleatCore/A.swift") + self.record("Sources/BleatTranscription/B.swift")
        result = normalize_lcov(raw + self.record("Tests/BleatCoreTests/A.swift") + self.record(".build/checkouts/dep/A.swift"), self.root)
        self.assertNotIn(str(self.root), result)
        self.assertNotIn("Tests/", result)
        self.assertNotIn("checkouts", result)
        self.assertIn("SF:Sources/BleatCore/A.swift", result)
        self.assertIn("SF:Sources/BleatTranscription/B.swift", result)

    def test_empty_missing_module_and_zero_execution(self):
        for raw in ("", self.record("Sources/BleatCore/A.swift"), self.record("Sources/BleatCore/A.swift") + self.record("Sources/BleatTranscription/B.swift", 0)):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                normalize_lcov(raw, self.root)

    def test_duplicate_sources_or_lines_rejected(self):
        raw = self.record("Sources/BleatCore/A.swift") + self.record("Sources/BleatTranscription/B.swift")
        for invalid in (raw + self.record("Sources/BleatCore/A.swift"), raw.replace("DA:1,1", "DA:1,1\nDA:1,2")):
            with self.subTest(raw=invalid), self.assertRaises(ValueError):
                normalize_lcov(invalid, self.root)


if __name__ == "__main__":
    unittest.main()
