#!/usr/bin/env python3
"""Refresh the generated part of tools/map30/SOURCE.txt (hashes and unified diffs against the 30MAPS clone).

usage: python3 tools/map30/source_txt.py [--clone ./external/30MAPS] [--check]
The prose above BEGIN GENERATED is preserved except the private origin locator, which is normalized.
--check exits 1 when SOURCE.txt is stale.
Reads the clone only; never writes to it.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE_TXT = os.path.join(HERE, "SOURCE.txt")
BEGIN = "----- BEGIN GENERATED (python3 tools/map30/source_txt.py) -----"
END = "----- END GENERATED -----"
# vendored name -> path inside the 30MAPS repo
FILES = [
    ("build_plan.py", "tools/build_plan.py"),
    ("builder_template.luau", "tools/builder_template.luau"),
    ("overview_template.luau", "tools/overview_template.luau"),
    ("NOTES.md", "NOTES.md"),
]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def unified_diff(orig, vendored, orig_label, vendored_label):
    # labels instead of timestamps so the text is stable across checkouts
    r = subprocess.run(["diff", "-u", "--label", orig_label, "--label", vendored_label, orig, vendored],
                       capture_output=True, text=True)
    if r.returncode not in (0, 1):
        sys.exit(f"diff failed: {r.stderr}")
    # A removed workstation heading is private even in a minus-line.
    # Hashes still identify exact upstream bytes; this display diff redacts that heading.
    return re.sub(r"(?m)^-## Windows run .*?$", "-## Windows run ([private checkout omitted])", r.stdout)


def generated(clone):
    head = subprocess.run(["git", "-C", clone, "rev-parse", "HEAD"], capture_output=True, text=True,
                          check=True).stdout.strip()
    lines = [BEGIN, f"clone HEAD at generation: {head}", "",
             "sha256 (original at the commit above  ->  vendored copy in tools/map30)"]
    diffs = []
    for name, rel in FILES:
        orig, ours = os.path.join(clone, rel), os.path.join(HERE, name)
        a, b = sha256(orig), sha256(ours)
        lines.append(f"{name:<24}{a} -> {b}  {'unmodified' if a == b else 'PATCHED'}")
        if a != b:
            diffs.append(unified_diff(orig, ours, f"a/{rel}", f"b/tools/map30/{name}"))
    lines.append("")
    for d in diffs:
        lines.append(d.rstrip("\n"))
        lines.append("")
    lines.append(END)
    return "\n".join(lines) + "\n"


PUBLIC_ORIGIN = "origin    30MAPS compiler (owner-controlled upstream; private source locator omitted)"


def public_prose(text):
    """Keep attribution/revisions, but never re-emit the private upstream locator."""
    prose = text.split(BEGIN)[0]
    return re.sub(r"(?m)^origin[ \t]+[^\n]*$", PUBLIC_ORIGIN, prose)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clone", default=os.environ.get("MAP30_CLONE", "./external/30MAPS"))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    with open(SOURCE_TXT) as f:
        text = f.read()
    prose = public_prose(text)
    new = prose + generated(a.clone)
    if a.check:
        if new != text:
            sys.exit("tools/map30/SOURCE.txt is stale: run python3 tools/map30/source_txt.py")
        print("SOURCE.txt up to date")
        return
    with open(SOURCE_TXT, "w") as f:
        f.write(new)
    print(f"wrote {SOURCE_TXT}")


if __name__ == "__main__":
    main()
