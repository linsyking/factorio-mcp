"""Offline tests for checks.py, using the layout mistakes agents made in the
acceptance tests (research/factorio-agent/12-collab.md, 13-solo-queue)."""

import pytest

from factorio_mcp.checks import check_plan, context_request, inserter_direction, planned

BELT = {"entity": {"type": "transport-belt", "tile_width": 1, "tile_height": 1}}
INSERTER = {"entity": {"type": "inserter", "tile_width": 1, "tile_height": 1,
                       "inserter_pickup_offset": {"x": 0, "y": -1}, "inserter_drop_offset": {"x": 0, "y": 1.2}}}
FURNACE = {"entity": {"type": "furnace", "tile_width": 2, "tile_height": 2}}
CHEST = {"entity": {"type": "container", "tile_width": 1, "tile_height": 1}}
# live prototypes: the drop offset is a point inside the output tile, not its centre
DRILL = {"entity": {"type": "mining-drill", "tile_width": 3, "tile_height": 3,
                    "drop_offset": {"x": 0, "y": -1.85}}}
BURNER_DRILL = {"entity": {"type": "mining-drill", "tile_width": 2, "tile_height": 2,
                           "drop_offset": {"x": -0.5, "y": -1.3}}}
PROTOS = {"transport-belt": BELT, "burner-inserter": INSERTER, "stone-furnace": FURNACE, "iron-chest": CHEST,
          "electric-mining-drill": DRILL, "burner-mining-drill": BURNER_DRILL}
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


def existing_drill(x=29.5, y=-9.5, drop=(27.65, -9.5), into="nothing", itype=None,
                  status="working", direction=12, name="electric-mining-drill"):
    return {"x": x, "y": y, "name": name, "direction": direction,
            "drop": {"x": drop[0], "y": drop[1]}, "drop_into": into,
            "drop_into_type": itype, "status": status}


def test_drill_outputs_to_the_middle_tile_of_its_facing_side():
    # the coal-field audit: the drill at (30.5, -14.5) facing west feeds the
    # belt at (28.5, -14.5) — nothing else collects its ore
    steps = [{"item": "electric-mining-drill", "x": 30.5, "y": -14.5, "direction": 12}]
    plan = planned(steps, PROTOS)
    _, points = context_request(plan)
    assert abs(points[0]["x"] - 28.65) < 0.001 and abs(points[0]["y"] + 14.5) < 0.001
    w = warnings(steps)
    assert len(w) == 1 and "electric-mining-drill at (30.5, -14.5) facing west" in w[0]
    assert "(28.5, -14.5)" in w[0] and "one tile" in w[0].lower()


def test_burner_drill_output_tile():  # 2x2 drill: no middle tile, the drop point picks
    steps = [{"item": "burner-mining-drill", "x": 34, "y": -20, "direction": 0}]
    w = warnings(steps)
    assert len(w) == 1 and "burner-mining-drill at (34, -20) facing north" in w[0] and "(33.5, -21.5)" in w[0]


def test_drill_with_a_receiver_on_its_output_tile_is_quiet():
    steps = [{"item": "electric-mining-drill", "x": 30.5, "y": -14.5, "direction": 12},
              belt(28.5, -14.5, 4)]
    assert warnings(steps) == []
    steps[1] = {"item": "iron-chest", "x": 28.5, "y": -14.5, "direction": 0}
    assert warnings(steps) == []
    # already standing there: a chest or a belt
    assert warnings(steps[:1], {"belts": [], "at": ["iron-chest"]}) == []
    assert warnings(steps[:1], {"belts": [], "at": ["transport-belt"]}) == []


def test_drill_outputing_onto_a_planned_inserter_warns():
    steps = [{"item": "electric-mining-drill", "x": 30.5, "y": -14.5, "direction": 12},
             {"item": "burner-inserter", "x": 28.5, "y": -14.5, "direction": 4}]
    w = warnings(steps)
    assert any("places a burner-inserter there" in x for x in w)


def test_existing_drill_with_no_receiver_warns():
    ctx = {"belts": [], "at": [], "drills": [existing_drill()]}
    w = warnings([belt(0.5, 0.5, 4)], ctx)
    assert len(w) == 1 and "the electric-mining-drill at (29.5, -9.5) facing west" in w[0]
    assert "(27.5, -9.5)" in w[0] and "nowhere to go" in w[0]


def test_existing_drill_with_a_belt_on_its_output_is_quiet():
    ctx = {"belts": [], "at": [], "drills": [
        existing_drill(into="transport-belt", itype="transport-belt")]}
    assert warnings([belt(0.5, 0.5, 4)], ctx) == []
    # the plan itself puts the belt on the empty output tile: fixed, no warning
    ctx = {"belts": [], "at": [], "drills": [existing_drill()]}
    assert warnings([belt(27.5, -9.5, 4)], ctx) == []


def test_existing_drill_outputing_onto_a_non_receiver_warns():
    ctx = {"belts": [], "at": [], "drills": [
        existing_drill(into="small-electric-pole", itype="electric-pole")]}
    w = warnings([belt(0.5, 0.5, 4)], ctx)
    assert len(w) == 1 and "the small-electric-pole there cannot receive it" in w[0]


def test_dead_existing_drill_is_skipped():
    # no minable resources: nothing comes out, the output tile is moot
    ctx = {"belts": [], "at": [], "drills": [existing_drill(status="no_minable_resources")]}
    assert warnings([belt(0.5, 0.5, 4)], ctx) == []


def test_drill_points_come_after_the_inserter_points():
    # check_plan reads the at-answers in context_request's order
    steps = [{"item": "burner-inserter", "x": 78.5, "y": -16.5, "direction": 4},
             {"item": "electric-mining-drill", "x": 30.5, "y": -14.5, "direction": 12}]
    plan = planned(steps, PROTOS)
    area, points = context_request(plan)
    assert len(points) == 3
    assert (points[0]["x"], points[0]["y"]) == (79.5, -16.5)   # inserter pickup (it faces east)
    assert (points[1]["x"], points[1]["y"]) == (77.3, -16.5)   # inserter drop
    assert abs(points[2]["x"] - 28.65) < 0.001                 # drill output
    w, lines = check_plan(plan, {"belts": [], "at": ["stone-furnace", "iron-chest", "nothing"]})
    assert "picks from stone-furnace" in lines[0] and "drops into iron-chest" in lines[0]
    assert len(w) == 1 and "electric-mining-drill at (30.5, -14.5)" in w[0]
