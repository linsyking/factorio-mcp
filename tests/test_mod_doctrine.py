"""The require doctrine (0.2.17): `require` only works while control.lua is
parsed — at runtime (an RPC handler via RCON) it raises "Require can't be
used outside of control.lua parsing". In 0.2.16 the underground-belt notes
in build_plan and the underground render in inspect both lazily required
scripts.belts from inside a function, so UG placements reported FAILED
after actually placing (cancelling the rest of the chain) and inspect_entity
could not render underground belts at all.

Every module require in the mod must be a load-time, top-level assignment
(module header or the tasks table, indent <= 2 spaces) whose result is used
as-is — `local x = require("a.b")` or `name = require("a.b"),` or the
field-letting form `name = require("a.b").field,` that tasks.lua uses.
"""
import re
from pathlib import Path

MOD = Path(__file__).resolve().parents[1] / "mod" / "factorio-mcp"

# a module require: require("dotted.name") — captures what comes before/after
REQUIRE = re.compile(r'^(.*?)require\("([\w_.]+)"\)(.*)$')


def _load_time(line: str, is_control: bool) -> str | None:
    """Returns None when the line is doctrine-clean, else the reason."""
    line = line.split("--", 1)[0]  # comments can say anything
    m = REQUIRE.match(line)
    if not m:
        return None  # no module require on this line
    indent = len(re.match(r"\s*", line).group(0))
    if indent > 2:
        return "indented inside a body (runs at runtime)"
    if is_control and indent == 0:
        return None  # control.lua's top-level statements all run at load
    before, _module, after = m.groups()
    if not re.search(r"=\s*$", before):
        return "not an assignment's right-hand side"
    # after must be "", ",", ".field" or ".field," — the require result used as-is
    tail = after.strip()
    if tail.startswith("."):
        tail = tail[1:]
    if tail.endswith(","):
        tail = tail[:-1]
    if not re.fullmatch(r"[\w]*", tail):
        return f"require result used mid-expression ({after.strip()[:24]!r})"
    return None


def test_every_module_require_is_load_time():
    files = sorted(MOD.rglob("*.lua"))
    assert len(files) > 10, f"the scan found too few files: {files}"
    bad = []
    for f in files:
        for n, line in enumerate(f.read_text().splitlines(), 1):
            why = _load_time(line, f.name == "control.lua")
            if why:
                bad.append(f"{f.relative_to(MOD)}:{n} [{why}] {line.strip()}")
    assert not bad, "runtime `require` found (fails live with 'Require can't " \
                    "be used outside of control.lua parsing'):\n" + "\n".join(bad)


def test_the_doctrine_catches_the_0216_bug_forms():
    # the exact shipped bug lines must be rejected (runtime requires)
    assert _load_time('    if e.type == "underground-belt" then out.underground '
                      '= require("scripts.belts").underground_note(e) end', False)  # inspect.lua
    assert _load_time('        require("scripts.belts").underground_note(e))', False)  # build_plan.lua
    assert _load_time('    local note, paired = require("scripts.belts").underground_note(built)', False)  # build.lua
    assert _load_time('    local belts = require("scripts.belts")  -- lazy, inside a function', False)
    # the load-time forms must pass
    assert _load_time('local belts = require("scripts.belts")', False) is None
    assert _load_time('  measure_belt = require("scripts.belts").measure,', False) is None
    assert _load_time('  defend_area = require("scripts.actions.defend"),', False) is None
    assert _load_time('-- a comment may mention require("anything") freely', False) is None
    assert _load_time('rpc.register("trace_belt", require("scripts.belts").trace)', True) is None  # control.lua top level
    assert _load_time('  rpc.register("trace_belt", require("scripts.belts").trace)', True)  # but not nested
