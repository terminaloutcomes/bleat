import contextlib
import io
import runpy
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

verifier = runpy.run_path(str(Path(__file__).with_name("verify-results.py")))


class ResultVerificationTests(unittest.TestCase):
    def report(self):
        root = ET.Element("testsuites")
        # Deliberately unreliable aggregate count: check individual outcomes.
        suite = ET.SubElement(root, "testsuite", tests="0")
        for name in sorted(verifier["EXPECTED"]):
            case = ET.SubElement(suite, "testcase", name=name)
            if name == "intentionalSkip()":
                ET.SubElement(case, "skipped")
        return root, suite

    def verify(self, root):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.xml"
            ET.ElementTree(root).write(path)
            with contextlib.redirect_stdout(io.StringIO()):
                verifier["verify"](path)

    def test_accepts_exact_individual_outcomes(self):
        self.verify(self.report()[0])

    def test_rejects_zero_tests(self):
        with self.assertRaises(ValueError):
            self.verify(ET.Element("testsuites"))

    def test_rejects_missing_test(self):
        root, suite = self.report()
        suite.remove(suite[-1])
        with self.assertRaises(ValueError):
            self.verify(root)

    def test_rejects_duplicate_test(self):
        root, suite = self.report()
        ET.SubElement(suite, "testcase", name=suite[-1].get("name"))
        with self.assertRaises(ValueError):
            self.verify(root)

    def test_rejects_failure_and_error(self):
        for kind in ("failure", "error"):
            with self.subTest(kind=kind):
                root, suite = self.report()
                ET.SubElement(suite[-1], kind)
                with self.assertRaises(ValueError):
                    self.verify(root)

    def test_rejects_unexpected_skip(self):
        root, suite = self.report()
        ET.SubElement(suite[-1], "skipped")
        with self.assertRaises(ValueError):
            self.verify(root)

    def test_rejects_missing_intentional_skip(self):
        root, suite = self.report()
        case = next(case for case in suite if case.get("name") == "intentionalSkip()")
        case.remove(case.find("skipped"))
        with self.assertRaises(ValueError):
            self.verify(root)


if __name__ == "__main__":
    unittest.main()
