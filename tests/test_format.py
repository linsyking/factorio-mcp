"""Offline tests for the scan formatter: the mining-drill footer (a drill
outputs onto ONE tile) and the legend's letter ordering (every letter
findable at a glance — a coal-field scan was read as missing legend entries
for k and q in a 22-line unordered wall)."""

from factorio_mcp.format import legend_lines, scan


def scan_result(**over):
    r = {
        "origin": {"x": 0, "y": 0}, "width": 3, "height": 1, "scale": 1,
        "grid": ["aaa"],
        "legend": {"?": "unexplored (fog of war)", ".": "buildable land", "A": "coal",
                   "a": "electric-mining-drill", "k": "wooden-chest", "q": "underground-belt"},
        "inserters": [],
    }
    r.update(over)
    return r


def test_legend_symbols_first_then_letters_alphabetically():
    lines = legend_lines({"?": "unexplored", "v": "your belt moving south", "c": "cliff",
                          "q": "underground-belt", "A": "coal", "b": "burner-mining-drill",
                          "*": "several different things (ran out of letters)"})
    assert lines == [
        "? = unexplored",
        "A = coal",
        "b = burner-mining-drill",
        "c = cliff",
        "q = underground-belt",
        "v = your belt moving south",
        "* = several different things (ran out of letters)",
    ]


def test_scan_renders_the_drill_footer():
    text = scan(scan_result(drills=[
        {"name": "electric-mining-drill", "position": {"x": 29.5, "y": -9.5}, "direction": 12,
         "status": "no_minable_resources", "output": {"x": 27.5, "y": -9.5},
         "output_into": "transport-belt"},
        {"name": "burner-mining-drill", "position": {"x": 34, "y": -20}, "direction": 0,
         "status": "working", "output": {"x": 33.5, "y": -21.5}, "output_into": "nothing"},
        {"name": "electric-mining-drill", "position": {"x": 30.5, "y": -14.5}, "direction": 12,
         "status": "waiting_for_space_in_destination", "output": {"x": 28.5, "y": -14.5},
         "output_into": "transport-belt"},
    ]))
    lines = text.splitlines()
    assert "Your mining drills (each outputs onto ONE tile — the middle tile of its facing side; a belt " \
           "anywhere else collects nothing):" in lines
    assert ("  electric-mining-drill at (29.5, -9.5) facing west: outputs onto transport-belt "
            "at (27.5, -9.5) — DEAD (no minable resources: the ore under it is gone)") in lines
    assert ("  burner-mining-drill at (34, -20) facing north: outputs onto NOTHING at (33.5, -21.5) "
            "— its ore has nowhere to go") in lines
    assert ("  electric-mining-drill at (30.5, -14.5) facing west: outputs onto transport-belt "
            "at (28.5, -14.5) (waiting for space in destination)") in lines


def test_scan_without_drills_has_no_footer():
    assert "mining drills" not in scan(scan_result())


def test_scan_renders_the_inserter_footer_with_direction():
    text = scan(scan_result(inserters=[{
        "name": "burner-inserter", "position": {"x": 28.5, "y": -16.5}, "direction": 0,
        "pickup": {"x": 28.5, "y": -17.5}, "pickup_from": "transport-belt",
        "drop": {"x": 28.5, "y": -15.3}, "drop_into": "iron-chest",
    }]))
    lines = text.splitlines()
    assert ("Your inserters (their direction is the side they PICK UP FROM — facing north they pick from "
            "the north tile and drop south):") in lines
    assert ("  burner-inserter at (28.5, -16.5) facing north: picks from transport-belt at (28.5, -17.5) "
            "-> drops into iron-chest at (28.5, -15.3)") in lines
