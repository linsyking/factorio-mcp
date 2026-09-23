"""Offline tests for checks.py, using the layout mistakes agents made in the
acceptance tests (research/factorio-agent/12-collab.md, 13-solo-queue)."""

import pytest

from factorio_mcp.checks import check_plan, context_request, inserter_direction, planned

BELT = {"entity": {"type": "transport-belt", "tile_width": 1, "tile_height": 1}}
INSERTER = {"entity": {"type": "inserter", "tile_width": 1, "tile_height": 1,
                       "inserter_pickup_offset": {"x": 0, "y": -1}, "inserter_drop_offset": {"x": 0, "y": 1.2}}}
FURNACE = {"entity": {"type": "furnace", "tile_width": 2, "tile_height": 2}}
CHEST = {"entity": {"type": "container", "tile_width": 1, "tile_height": 1}}
PROTOS = {"transport-belt": BELT, "burner-inserter": INSERTER, "stone-furnace": FURNACE, "iron-chest": CHEST}
EMPTY = {"belts": [], "at": []}


def belt(x, y, d):
    return {"item": "transport-belt", "x": x, "y": y, "direction": d}


def warnings(steps, ctx=EMPTY):
    return check_plan(planned(steps, PROTOS), ctx)[0]


def test_corner_turned_north_instead_of_south():
    # solo-1: the trunk runs east on y=-12.5; the corner at x=70.5 must turn south onto the y=-11.5 line
    steps = [belt(69.5, -12.5, 4), belt(70.5, -12.5, 0), belt(70.5, -11.5, 4), belt(71.5, -11.5, 4)]
    w = warnings(steps)
    assert len(w) == 1 and "(70.5, -12.5) facing north" in w[0] and "face south (direction 8)" in w[0]
    steps[1]["direction"] = 8
    assert warnings(steps) == []


def test_corner_kept_going_east_instead_of_north():
    steps = [belt(91.5, -11.5, 4), belt(92.5, -11.5, 4), belt(92.5, -12.5, 0), belt(92.5, -13.5, 0)]
    w = warnings(steps)
    assert len(w) == 1 and "face north (direction 0)" in w[0]


def test_corner_joins_an_existing_line_on_the_ground():
    # the plan's corner points away from a line that is already built
    steps = [belt(9.5, 0.5, 4), belt(10.5, 0.5, 0)]
    ctx = {"belts": [{"x": 10.5, "y": 1.5, "direction": 4, "type": "transport-belt"}], "at": []}
    assert "face south" in warnings(steps, ctx)[0]


def test_plain_line_end_is_fine():
    assert warnings([belt(0.5, 0.5, 4), belt(1.5, 0.5, 4), belt(2.5, 0.5, 4)]) == []


def test_head_on_belts():
    w = warnings([belt(0.5, 0.5, 4), belt(1.5, 0.5, 12)])
    assert w and all("face each other" in x for x in w)


def test_inserter_direction_is_the_pickup_side():
    assert inserter_direction(78.5, -16.5, drop_to=(79.5, -16.5)) == 12  # drops east, picks from west
    assert inserter_direction(78.5, -16.5, pickup_from=(77.5, -16.5)) == 12
    assert inserter_direction(0.5, 0.5, drop_to=(0.5, -0.5)) == 8  # drops north, picks from south
    with pytest.raises(ValueError):
        inserter_direction(0.5, 0.5, drop_to=(0.5, 0.5))


def test_inserter_ends_and_wrong_way_warning():
    # solo-1: output inserters faced the chest; they picked from the new, empty chest
    steps = [{"item": "stone-furnace", "x": 77, "y": -16, "direction": 0},
             {"item": "burner-inserter", "x": 78.5, "y": -16.5, "direction": 4},
             {"item": "iron-chest", "x": 79.5, "y": -16.5, "direction": 0}]
    plan = planned(steps, PROTOS)
    area, points = context_request(plan)
    assert len(points) == 2
    w, lines = check_plan(plan, {"belts": [], "at": ["nothing", "nothing"]})
    assert "picks from iron-chest" in lines[0] and "drops into stone-furnace" in lines[0]
    assert len(w) == 1 and "wrong way" in w[0]
    steps[1]["direction"] = 12
    w, lines = check_plan(planned(steps, PROTOS), {"belts": [], "at": ["nothing", "nothing"]})
    assert "picks from stone-furnace" in lines[0] and "drops into iron-chest" in lines[0] and w == []


def test_inserter_picking_from_nothing():
    steps = [{"item": "burner-inserter", "x": 0.5, "y": 0.5, "direction": 0}]
    w, _ = check_plan(planned(steps, PROTOS), {"belts": [], "at": ["nothing", "stone-furnace"]})
    assert "picks up from an empty tile" in w[0]
