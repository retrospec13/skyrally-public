"""V5-3: tools/clip.py + win/clip_rec.js. screen_capture answers JPEG; the recorder named every frame f_%05d.png and
ffmpeg refused the clip ("Invalid PNG signature 0xFFD8FFE0"). Frames are now named by their real format and the
encoder's input pattern follows timing.json's "ext"."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import clip  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


class FramePattern(unittest.TestCase):
    def test_jpeg_frames_get_a_jpg_pattern(self):
        self.assertEqual(clip.frame_pattern(r"C:\x\clips\t", {"fps": 3, "ext": "jpg"}), r"C:\x\clips\t\f_%05d.jpg")

    def test_png_frames_keep_png(self):
        self.assertEqual(clip.frame_pattern(r"C:\x", {"ext": "PNG"}), r"C:\x\f_%05d.png")

    def test_old_timing_without_ext_matches_the_old_names(self):
        self.assertTrue(clip.frame_pattern(r"C:\x", {"fps": 2}).endswith(".png"))

    def test_unknown_format_refused(self):
        with self.assertRaises(ValueError):
            clip.frame_pattern(r"C:\x", {"ext": "gif"})


class FinishCommand(unittest.TestCase):
    def test_ffmpeg_reads_the_recorded_extension(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            proc = mock.Mock()
            proc.communicate.return_value = ("CLIP frames=10 seconds=5.0 fps=2.00 ext=jpg mixed=0\n", None)

            def fake_get(remote, local):
                if str(remote).endswith("timing.json"):
                    Path(local).write_text(json.dumps({"frames": 10, "seconds": 5.0, "fps": 2.0, "ext": "jpg"}))

            with mock.patch.object(clip.lane, "OUT", out), mock.patch.object(clip.lane, "PCWIN", r"F:\lane"), \
                    mock.patch.object(clip.lane, "get", side_effect=fake_get), \
                    mock.patch.object(clip.lane, "ssh") as ssh:
                clip.finish({"tag": "battle_t", "proc": proc, "pc_dir": r"F:\lane\out\clips\battle_t"})
            cmd = ssh.call_args[0][0]
            self.assertIn(r"-i F:\lane\out\clips\battle_t\f_%05d.jpg ", cmd)
            self.assertNotIn(".png", cmd)


class Recorder(unittest.TestCase):
    def test_recorder_names_frames_by_their_bytes_and_reports_ext(self):
        js = (ROOT / "tools/windows/clip_rec.js").read_text()
        self.assertIn("function frameExt(", js)
        self.assertIn("0xd8", js)  # JPEG magic sniffed
        self.assertNotIn("padStart(5, '0')}.png`", js)  # the old fixed .png name is gone
        self.assertIn("ext: ext || 'jpg'", js)  # timing.json carries the extension clip.py reads


if __name__ == "__main__":
    unittest.main()
