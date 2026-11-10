import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lane  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


class McpCallFiles(unittest.TestCase):
    def test_names_are_per_process(self):
        a, b = lane.mcp_call_name("console", pid=111), lane.mcp_call_name("console", pid=222)
        self.assertNotEqual(a, b)
        self.assertEqual(a, "console.p111")
        self.assertTrue(lane.mcp_call_name("console").endswith(f".p{__import__('os').getpid()}"))

    def test_mcp_uses_and_removes_own_files(self):
        sent, ssh_cmds = [], []
        tmp = Path(tempfile.mkdtemp())

        def fake_put(local, remote):
            sent.append(remote)

        def fake_ssh(cmd, check=True, timeout=600):
            ssh_cmds.append(cmd)
            return ""

        def fake_scp(src, dst, timeout=600):
            if str(dst).endswith(".out.json"):
                Path(dst).write_text(json.dumps({"results": [{"content": [{"type": "text", "text": "ok"}]}]}))

        with mock.patch.object(lane, "OUT", tmp), mock.patch.object(lane, "put", fake_put), \
                mock.patch.object(lane, "ssh", fake_ssh), mock.patch.object(lane, "scp", fake_scp), \
                mock.patch.object(lane.os, "getpid", return_value=4242):
            res = lane.mcp([{"name": "get_console_output", "arguments": {}}], "console")
        self.assertEqual(lane.text(res), "ok")
        self.assertEqual(sent, ["win/calls/console.p4242.json"])  # never the shared console.json
        run = next(c for c in ssh_cmds if "skyrally_mcp.js" in c)
        self.assertIn("calls\\console.p4242.json", run)
        self.assertIn("out\\mcp\\console.p4242.json", run)
        self.assertTrue(any(c.startswith('cmd /c "del /q') and "console.p4242" in c for c in ssh_cmds))
        self.assertEqual(list(tmp.iterdir()), [])  # local call and output files removed
        shutil.rmtree(tmp)

    def test_cleanup_runs_when_the_bridge_fails(self):
        ssh_cmds = []
        tmp = Path(tempfile.mkdtemp())

        def fake_ssh(cmd, check=True, timeout=600):
            ssh_cmds.append(cmd)
            if "skyrally_mcp.js" in cmd:
                raise RuntimeError("EBUSY")
            return ""

        with mock.patch.object(lane, "OUT", tmp), mock.patch.object(lane, "put", lambda *a: None), \
                mock.patch.object(lane, "ssh", fake_ssh):
            with self.assertRaises(RuntimeError):
                lane.mcp([{"name": "get_console_output", "arguments": {}}], "console")
        self.assertTrue(any("del /q" in c for c in ssh_cmds))
        self.assertEqual(list(tmp.iterdir()), [])
        shutil.rmtree(tmp)


@unittest.skipUnless(shutil.which("node"), "node not installed")
class PilotDecider(unittest.TestCase):
    """tools/windows/key_pilot.js builds the client decision function from its arguments; check the S1/S2b parts it injects."""

    def decide(self, *args):
        js = """const fs=require('fs');const cp=require('child_process');cp.spawn=()=>({stdout:{on(){}}});
process.argv=['node','k','/dev/null','1',...JSON.parse(process.env.A)];
const src=fs.readFileSync(process.env.F,'utf8').replace(/\\(async \\(\\) => \\{[\\s\\S]*$/,'console.log(DECIDE_DEF);');eval(src);"""
        import os
        env = dict(os.environ, A=json.dumps(list(args)), F=str(ROOT / "tools" / "windows" / "key_pilot.js"))
        return subprocess.run(["node", "-e", js], capture_output=True, text=True, env=env, check=True).stdout

    def test_route_and_verify_are_injected(self):
        q = self.decide("assist=off", "skill=1", "goal=qa", "route=-8000:55:40:9999/-8074:56:-115:70", "bad=1")
        self.assertIn("local ROUTE = {{-8000,55,40,9999},{-8074,56,-115,70}}", q)
        self.assertIn("local VERIFY = false", q)
        v = self.decide("assist=off", "skill=1", "goal=verify", "boost=1")
        self.assertIn("local VERIFY = true", v)
        self.assertIn("local BOOST = true", v)
        self.assertIn("local ROUTE = {}", v)
        self.assertIn("_G.PilotDecide = nil", v)  # E2: never reuse a previous run's decider

    def test_garbage_route_is_dropped(self):
        q = self.decide("assist=off", "skill=1", "goal=qa", "route=a:b:c/1:2")
        self.assertIn("local ROUTE = {}", q)


if __name__ == "__main__":
    unittest.main()
