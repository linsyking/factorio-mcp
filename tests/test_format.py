"""Offline tests for the scan formatter: the mining-drill footer (a drill
outputs onto ONE tile) and the legend's letter ordering (every letter
findable at a glance — a coal-field scan was read as missing legend entries
for k and q in a 22-line unordered wall)."""

from factorio_mcp.format import inspect as fmt_inspect, legend_lines, scan


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


# --------------------------------------------------- segment-scoped belt reads
# (0.2.21: 2.0 transport lines span whole runs of belts — the counts are the
# run's, and the read must say so, plus where items actually sit)

def belt_entity(**over):
    e = {
        "name": "transport-belt", "position": {"x": -1.5, "y": 4.5},
        "belt_lanes": {"left": {"logistic-science-pack": 4}, "right": {}},
        "belt_direction": 0,
        "belt_segment": {"tiles": 39, "positions": [
            {"lane": "left", "name": "logistic-science-pack", "count": 4,
             "at": {"x": -1.5, "y": 1.5}, "dist": 3.0},
        ]},
    }
    e.update(over)
    return e


def test_belt_reads_say_line_scoped_with_item_positions():
    out = fmt_inspect(belt_entity())
    assert "Belt reads are line-scoped, not tile-wide: the counts above are its whole transport line (39 tile(s))" in out
    assert "Items actually sit at: 4 logistic-science-pack (left lane) at (-1.5, 1.5), 3 tiles away." in out


def test_belt_line_note_without_positions():
    e = belt_entity(belt_segment={"tiles": 2, "positions": []})
    out = fmt_inspect(e)
    assert "its whole transport line (2 tile(s))" in out
    assert "Items actually sit at" not in out


def test_belt_line_note_without_segment_data():
    # a read from an older mod (no belt_segment field): the honesty note stands
    e = belt_entity(belt_segment=None)
    e.pop("belt_segment")
    out = fmt_inspect(e)
    assert "Belt reads are line-scoped, not tile-wide: the counts above are its whole transport line" in out
