"""Public provenance must retain evidence without reintroducing a private locator."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("source_txt_privacy", HERE / "source_txt.py")
source_txt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_txt)


class PublicProvenanceTests(unittest.TestCase):
    def test_private_locator_is_normalized_and_other_evidence_preserved(self):
        prose = "origin    https://example.invalid/private-owner/compiler.git\ncommit abc123\nThird party credit: Example Author\n"
        expected = source_txt.PUBLIC_ORIGIN + "\ncommit abc123\nThird party credit: Example Author\n"
        self.assertEqual(source_txt.public_prose(prose + source_txt.BEGIN + "\nold diff"), expected)
        self.assertEqual(source_txt.public_prose(expected), expected)

    def test_release_header_uses_neutral_locator_and_pinned_revision(self):
        text = (HERE / "SOURCE.txt").read_text()
        self.assertIn(source_txt.PUBLIC_ORIGIN + "\n", text)
        self.assertIn("aa9a4519513aa8dec9abf5151f657d22a41611fa", text)
        self.assertIn("sha256 (original at the commit above", text)
        self.assertEqual(source_txt.public_prose(text), text.split(source_txt.BEGIN)[0])
