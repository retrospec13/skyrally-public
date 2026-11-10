"""Guard the authoritative editable Luau source against accidental GLB rebakes."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("editable_baker", TOOLS / "bake_boss_clips.py")
baker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baker)


class EditableClipTests(unittest.TestCase):
    def test_authoritative_source_is_protected_without_modification(self):
        p = TOOLS.parent / "src/shared/bossclips/Frosthorn.luau"
        before = p.read_bytes()
        with self.assertRaisesRegex(baker.BakeError, "authoritative editable source"):
            baker.protect_editable_source(p)
        self.assertEqual(p.read_bytes(), before)

    def test_generated_or_new_comparison_paths_remain_allowed(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "comparison.luau"
            baker.protect_editable_source(p)
            p.write_text("-- AUTO-GENERATED\nreturn {}\n")
            baker.protect_editable_source(p)
