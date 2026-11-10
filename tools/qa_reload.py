#!/usr/bin/env python3
"""Hot-reload the own Studio window from a clean worktree of HEAD plus the lane checkout's working-tree changes under
src/ and build/, except paths starting with an --exclude prefix (work another agent is still editing).
Usage: qa_reload.py [--exclude src/client/BossAnimator.luau --exclude src/shared/bossclips ...]"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lane  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--exclude", action="append", default=[])
args = ap.parse_args()

st = subprocess.run(["git", "-C", str(lane.ROOT), "status", "--porcelain", "--untracked-files=all", "src", "build"],
                    capture_output=True, text=True, check=True).stdout.splitlines()
changed = [line[3:] for line in st if line[:2] != " D"]
overlay = [p for p in changed if not any(p.startswith(e) for e in args.exclude)]
wt = lane.OUT / "qa_worktree"
lane.sh(["git", "-C", str(lane.ROOT), "worktree", "remove", "--force", str(wt)], check=False)
lane.sh(["git", "-C", str(lane.ROOT), "worktree", "add", "--detach", str(wt), "HEAD"])
for p in overlay:
    (wt / p).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(lane.ROOT / p, wt / p)
print("overlay:", len(overlay), "files;", "skipped:", sorted(set(changed) - set(overlay)))
saved = lane.ROOT
lane.ROOT = wt
try:
    print(lane.hot_reload())
finally:
    lane.ROOT = saved
    lane.sh(["git", "-C", str(saved), "worktree", "remove", "--force", str(wt)], check=False)
