"""Production math on top of FactorioCalc (AGPL-3.0, https://github.com/FactorioCalc/FactorioCalc).

Names use Factorio's internal spelling ("iron-plate", "assembling-machine-2");
rates are per minute. Pure functions — no game connection.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Any

import factoriocalc as fc
from factoriocalc import config, itm, mch, presets, produce, rcp
from factoriocalc.produce import MultipleChoiceError

GAMES = {"base": "v2.0", "space-age": "v2.0-sa"}
PRESETS = {
    "early": "MP_EARLY_GAME",       # assembling machine 1, stone furnace
    "early-mid": "MP_EARLY_MID_GAME",
    "late": "MP_LATE_GAME",         # assembling machine 3, electric furnace, ...
    "legendary": "MP_LEGENDARY",
}
# Recipes never picked automatically: recycling, space/planet-specific
# alternatives, quality variants and barrel handling.
_AUTO_SKIP = re.compile(r"recycling|asteroid|crushing|synthesis|^(uncommon|rare|epic|legendary)-|barrel")
# Treated as raw inputs unless raw_inputs is given explicitly.
RAW_DEFAULT = ["iron-ore", "copper-ore", "coal", "stone", "uranium-ore", "crude-oil", "water", "wood",
               "calcite", "tungsten-ore", "scrap", "holmium-ore", "lithium-brine", "fluorine", "lava",
               "ammoniacal-solution", "yumako", "jellynut", "spoilage"]

def _game(game: str) -> None:
    # FactorioCalc keeps its configuration in context variables, and every MCP
    # request runs in its own context — so set it on every call (3-35 ms).
    mode = GAMES.get(game)
    if mode is None:
        raise ValueError(f"game must be one of {', '.join(GAMES)}")
    fc.setGameConfig(mode)


def _py(name: str) -> str:
    return name.replace("-", "_")


def _item(name: str):
    try:
        return getattr(itm, _py(name))
    except AttributeError:
        raise ValueError(f"unknown item or fluid '{name}'") from None


def _recipe(name: str):
    try:
        return getattr(rcp, _py(name))
    except AttributeError:
        raise ValueError(f"unknown recipe '{name}'") from None


def _machine_cls(name: str):
    cls_name = "".join(part.capitalize() for part in name.split("-"))
    try:
        return getattr(mch, cls_name)
    except AttributeError:
        raise ValueError(f"unknown machine '{name}'") from None


def _dashed(s: Any) -> str:
    return str(s).replace("_", "-")


def _frac(v: float) -> Fraction:
    return Fraction(v).limit_denominator(10000)


def _num(v) -> float:
    return round(float(v), 4)


@dataclass
class Plan:
    machines: list[dict[str, Any]] = field(default_factory=list)
    outputs: dict[str, float] = field(default_factory=dict)
    inputs: dict[str, float] = field(default_factory=dict)
    electricity_mw: float = 0.0
    notes: list[str] = field(default_factory=list)

    def as_dict(self) -> dict[str, Any]:
        return {
            "machines": self.machines,
            "outputs_per_min": self.outputs,
            "inputs_per_min": self.inputs,
            "electricity_mw": self.electricity_mw,
            "notes": self.notes,
        }


def solve_production(
    targets_per_min: dict[str, float],
    *,
    machines: list[str] | None = None,
    preset: str = "early",
    recipes: list[str] | None = None,
    raw_inputs: list[str] | None = None,
    game: str = "base",
    fuel: str | None = "coal",
) -> Plan:
    """Machines needed to make `targets_per_min`, with raw inputs per minute."""
    if not targets_per_min:
        raise ValueError("give at least one target item with a rate per minute")
    _game(game)
    preset_name = PRESETS.get(preset)
    if preset_name is None:
        raise ValueError(f"preset must be one of {', '.join(PRESETS)}")
    # Explicit machines take precedence (first match wins); the preset covers the rest.
    chosen = [_machine_cls(m)() for m in (machines or [])]
    config.machinePrefs.set(fc.MachinePrefs(*chosen, *getattr(presets, preset_name)))

    outputs = [_item(n) @ _frac(r / 60) for n, r in targets_per_min.items()]
    using = [_recipe(r) for r in (recipes or [])]
    raw = RAW_DEFAULT if raw_inputs is None else raw_inputs
    stop_at = [getattr(itm, _py(n)) for n in raw if hasattr(itm, _py(n))]
    targets = set(targets_per_min)
    stop_at = [x for x in stop_at if _dashed(x) not in targets]
    notes: list[str] = []

    for _ in range(40):  # resolve "multiple ways to produce X" automatically
        try:
            res = produce(outputs, using=using, stopAt=stop_at, fuel=_item(fuel) if fuel else None)
            break
        except MultipleChoiceError as e:
            m = re.match(r"multiple ways to produce (\S+): (.*)", str(e))
            if not m:
                raise
            item_py, choices = m.group(1), m.group(2).split()
            item_dash = _dashed(item_py)
            if item_dash in choices and not _AUTO_SKIP.search(item_dash):
                using.append(_recipe(item_dash))
                pass  # the standard recipe named after the item — not worth a note
            else:
                usable = [c for c in choices if not _AUTO_SKIP.search(c)]
                if usable:
                    using.append(_recipe(usable[0]))
                    notes.append(f"{item_dash}: chose recipe '{usable[0]}' from {', '.join(choices[:6])}"
                                 + ("…" if len(choices) > 6 else "") + " (pass recipes=[...] to choose another)")
                else:
                    stop_at.append(getattr(itm, item_py))
                    notes.append(f"{item_dash}: treated as a raw input (only recycling/asteroid recipes make it)")
    else:
        raise ValueError("could not settle on recipes automatically; pass recipes=[...] explicitly")

    plan = Plan(notes=notes)
    factory = res.factory
    for mul in factory.inner:
        machine = mul.machine
        recipe = getattr(machine, "recipe", None)
        plan.machines.append({
            "recipe": _dashed(getattr(recipe, "name", recipe)),
            "machine": _machine_name(machine),
            "count": _num(mul.num),
            "count_rounded_up": math.ceil(float(mul.num) - 1e-9),
        })
    for flow in factory.flows():
        rate = float(flow.rate()) if callable(flow.rate) else float(flow.rate)
        name = _dashed(flow.item)
        if name == "electricity":
            plan.electricity_mw = round(-rate, 4)
        elif rate > 1e-9:
            plan.outputs[name] = round(rate * 60, 3)
        elif rate < -1e-9:
            plan.inputs[name] = round(-rate * 60, 3)
    return plan


def _machine_name(machine) -> str:
    cls = type(machine).__name__
    return re.sub(r"(?<!^)(?=[A-Z])|(?<=[a-z])(?=\d)", "-", cls).lower()


# ------------------------------------------------------------------ mining

# Vanilla 2.0 values: mining speed per drill (before research/modules) and
# mining time per resource (seconds per unit at speed 1).
DRILLS = {
    "burner-mining-drill": 0.25,
    "electric-mining-drill": 0.5,
    "big-mining-drill": 2.5,   # Space Age
}
MINING_TIME = {"iron-ore": 1, "copper-ore": 1, "coal": 1, "stone": 1, "uranium-ore": 2,
               "tungsten-ore": 5, "scrap": 0.5, "calcite": 1}  # Space Age extras
BELTS = {"transport-belt": 15, "fast-transport-belt": 30, "express-transport-belt": 45, "turbo-transport-belt": 60}


def mining_drills(resource: str, per_min: float, drill: str = "electric-mining-drill",
                  mining_productivity: float = 0.0) -> dict[str, Any]:
    if drill not in DRILLS:
        raise ValueError(f"drill must be one of {', '.join(DRILLS)}")
    if resource not in MINING_TIME:
        raise ValueError(f"unknown resource '{resource}' (known: {', '.join(MINING_TIME)})")
    per_drill_s = DRILLS[drill] / MINING_TIME[resource] * (1 + mining_productivity)
    per_drill_min = per_drill_s * 60
    n = per_min / per_drill_min
    return {
        "resource": resource,
        "drill": drill,
        "per_drill_per_min": round(per_drill_min, 3),
        "drills": round(n, 3),
        "drills_rounded_up": math.ceil(n - 1e-9),
        "note": "resource amount, depletion and uranium's sulfuric acid are not modelled",
    }


def belts_needed(per_min: float) -> dict[str, float]:
    return {b: round(per_min / (ips * 60), 3) for b, ips in BELTS.items()}


def machines_per_belt(recipe: str, machine: str, belt: str = "transport-belt", game: str = "base") -> dict[str, Any]:
    """How many machines of `recipe` one belt of its main product can feed or absorb."""
    if belt not in BELTS:
        raise ValueError(f"belt must be one of {', '.join(BELTS)}")
    _game(game)
    r = _recipe(recipe)
    cls = _machine_cls(machine)
    try:
        m = cls(r, fuel=itm.coal)   # burner machines need a fuel to compute flows
    except TypeError:
        m = cls(r)
    flows = (1 * m).flows()
    out = {}
    for flow in flows:
        rate = float(flow.rate()) if callable(flow.rate) else float(flow.rate)
        name = _dashed(flow.item)
        if name != "electricity" and abs(rate) > 1e-9:
            out[name] = round(rate * 60, 3)
    belt_min = BELTS[belt] * 60
    per_belt = {name: round(belt_min / abs(v), 3) for name, v in out.items()}
    return {"recipe": recipe, "machine": machine, "per_machine_per_min": out,
            "machines_to_fill_or_drain_one_belt": per_belt, "belt_items_per_min": belt_min}


def recipe_info(name: str, game: str = "base") -> dict[str, Any]:
    _game(game)
    r = _recipe(name)
    def parts(xs):
        return {_dashed(x.item): _num(x.num) for x in xs}
    return {
        "recipe": name,
        "time_s": _num(r.time),
        "ingredients": parts(r.inputs),
        "products": parts(r.outputs),
        "category": _dashed(getattr(getattr(r, "category", None), "name", getattr(r, "category", ""))),
    }
