"""Pins the calculator to numbers verified elsewhere (research/factorio-agent/05, 06)."""

import pytest

from factorio_calc_mcp import calc


def by_recipe(plan):
    return {m["recipe"]: m["count"] for m in plan.machines}


def test_green_circuits_45_per_min_on_am2():
    m = by_recipe(calc.solve_production({"electronic-circuit": 45}, machines=["assembling-machine-2"]))
    assert m["electronic-circuit"] == pytest.approx(0.5)
    assert m["copper-cable"] == pytest.approx(0.75)


def test_stone_furnaces_per_yellow_belt_is_48():
    r = calc.machines_per_belt("iron-plate", "stone-furnace")
    assert r["machines_to_fill_or_drain_one_belt"]["iron-plate"] == pytest.approx(48)


def test_plastic_cracking_matches_lp():
    m = by_recipe(calc.solve_production({"plastic-bar": 60}, preset="late", recipes=["advanced-oil-processing"]))
    assert m["advanced-oil-processing"] == pytest.approx(0.5128, abs=1e-3)
    assert m["light-oil-cracking"] == pytest.approx(0.4359, abs=1e-3)
    assert m["heavy-oil-cracking"] == pytest.approx(0.1282, abs=1e-3)


def test_space_age_skips_recycling_and_synthesis():
    plan = calc.solve_production({"iron-gear-wheel": 30}, game="space-age")
    assert set(by_recipe(plan)) == {"iron-gear-wheel", "iron-plate"}
    assert set(plan.inputs) == {"iron-ore", "coal"}


def test_burner_drills_for_60_iron_ore():
    r = calc.mining_drills("iron-ore", 60, "burner-mining-drill")
    assert r["drills"] == pytest.approx(4) and r["per_drill_per_min"] == pytest.approx(15)


def test_unknown_names_are_clear():
    with pytest.raises(ValueError, match="unknown item"):
        calc.solve_production({"iron-plat": 10})


def test_works_in_a_fresh_context():
    # MCP requests run in their own contextvars context; FactorioCalc's config
    # lives in context variables, so every call must set it up itself.
    import contextvars

    plan = contextvars.Context().run(calc.solve_production, {"iron-plate": 60})
    assert by_recipe(plan)["iron-plate"] == pytest.approx(3.2)


def test_rocket_part_uses_a_rocket_silo():
    # used to crash: "'NoneType' object has no attribute 'inner'" (the solver never picks the silo)
    p = calc.solve_production({"rocket-part": 1}, game="space-age", preset="late")
    silo = p.machines[0]
    assert silo["machine"] == "rocket-silo" and silo["count"] == 0.05
    assert p.outputs == {"rocket-part": 1.0}
    base = calc.solve_production({"rocket-part": 1}, preset="late")
    pu = next(m for m in base.machines if m["recipe"] == "processing-unit")
    assert pu["count"] > 1  # base needs 10 processing units per part, Space Age 1
