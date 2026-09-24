#!/usr/bin/env python3
"""Run the offline mod tests (tests/mod/*.lua) without a system `lua` binary,
using lupa's embedded Lua:

    uv run --with lupa python scripts/run_mod_tests.py [test.lua ...]

Equivalent to the README's `for t in tests/mod/*.lua; do lua $t; done`: each
test stubs the game API itself and ends with os.exit(0) or os.exit(1). lupa
cannot exit mid-script, so os.exit is shimmed to record its code in a global
that this runner reads after the script returns.
"""
from __future__ import annotations

import glob
import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("lupa is required: uv run --with lupa python scripts/run_mod_tests.py")
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[1]
EXIT_SHIM = """
os.exit = function(code)
  if code == nil or code == true then code = 0 end
  _TEST_EXIT = code
end
"""


def run_one(path: Path) -> tuple[int, list[str]]:
    """Returns (exit code the test asked for, its printed lines)."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(EXIT_SHIM)
    lua.execute(f"arg = {{ [0] = '{path}' }}")
    lines: list[str] = []

    def collect(*parts: object) -> None:
        lines.append(" ".join(str(p) for p in parts).rstrip())

    lua.globals()["print"] = collect
    rc = 0
    try:
        lua.execute(f'dofile("{path}")')  # a test error (not os.exit) raises
    except Exception as e:
        lines.append(f"(lua error: {str(e)[:300]})")
        rc = 1
    if rc == 0:
        asked = lua.globals()["_TEST_EXIT"]
        if asked is not None:
            rc = int(asked)
    return rc, lines


def main(argv: list[str]) -> int:
    args = argv[1:]
    tests = [Path(a) for a in args] if args else [Path(p) for p in sorted(glob.glob(str(ROOT / "tests" / "mod" / "*.lua")))]
    if not tests:
        print("no tests found")
        return 2
    failed: list[Path] = []
    for path in tests:
        try:
            rel = path.relative_to(ROOT)
        except ValueError:
            rel = path
        rc, lines = run_one(path)
        if rc == 0:
            print(f"PASS {rel}")
        else:
            failed.append(path)
            print(f"FAIL {rel}")
            for line in lines[-40:]:
                print("  " + line)
    if failed:
        print(f"\n{len(failed)} test file(s) FAILED")
        return 1
    print("\nALL MOD TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
