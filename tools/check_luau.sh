#!/usr/bin/env bash
# Static Luau check on the lane host (same analysis the PC launcher runs): rojo sourcemap + luau-lsp analyze.
# Usage: tools/check_luau.sh [paths...]   (default: src and the mounted builders). Prints errors; exit 1 on any error.
set -u
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."
rojo sourcemap default.project.json -o out/sourcemap.json >/dev/null
paths=("$@")
[ ${#paths[@]} -eq 0 ] && paths=(src builder_dino4.luau)
out=$(luau-lsp analyze --sourcemap=out/sourcemap.json --definitions=tools/luau-types/globalTypes.d.luau "${paths[@]}" 2>&1)
echo "$out" | grep -v "LocalUnused\|ImportUnused\|FunctionUnused" | grep -E "Error|error" 
n=$(echo "$out" | grep -E "TypeError|SyntaxError|UnknownGlobal" | grep -vc "^$")
echo "LUAU_ERRORS=$n"
[ "$n" -eq 0 ]
