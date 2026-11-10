#!/usr/bin/env bash
# The one local gate command (audit T1-3; no CI, CI minutes are an owner decision). Runs, in order:
#   1 lune suite (twice: flake check; compile_spec compiles every script)   2 check_luau (0 errors)
#   3 tools/tests python unit tests   4 tools/map/tests unit tests   5 offline preflight number scan (--strict: a new unledgered id fails unless it has a validated upload record, see preflight_scan.py)
#   6 launch-config listing (private view; the --public check is a separate refusal inside the publish path)
# Prints one GATE line per step and a final GATE_PASS / GATE_FAIL; exit 0 only when every step passed.
# lane.publish_checkpoint runs this before any publish and refuses on failure.   Usage: tools/gate.sh [--keep-going]
set -u
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."
mkdir -p out
keep=0; [ "${1:-}" = "--keep-going" ] && keep=1
fails=()
step() { # name, command...
	local name=$1; shift
	local log="out/gate_${name}.log"
	if "$@" >"$log" 2>&1; then echo "GATE ok   $name"; else echo "GATE FAIL $name (see $log)"; tail -n 8 "$log" | sed 's/^/    /'; fails+=("$name"); [ $keep -eq 1 ] || { echo "GATE_FAIL ${fails[*]}"; exit 1; }; fi
}
step lune_1 bash tools/tests/run_lune_tests.sh
step lune_2 bash tools/tests/run_lune_tests.sh
step check_luau bash tools/check_luau.sh
step py_tools python3 -m unittest discover -s tools/tests -p "test_*.py"
step py_map bash -c 'cd tools/map/tests && python3 -m unittest discover -s .'
step preflight_scan python3 tools/preflight_scan.py --strict
step launch_config python3 tools/launch_config_check.py
if [ ${#fails[@]} -eq 0 ]; then echo "GATE_PASS"; exit 0; fi
echo "GATE_FAIL ${fails[*]}"; exit 1
