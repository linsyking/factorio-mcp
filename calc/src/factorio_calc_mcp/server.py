"""factorio-calc-mcp: Factorio production math as MCP tools (stdio).

Separate from factorio-mcp on purpose: it needs no game connection and no
character, and it links FactorioCalc (AGPL-3.0)."""

from __future__ import annotations

from typing import Annotated, Literal

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pydantic import Field

from . import calc

Game = Literal["base", "space-age"]
app = MCPServer(
    name="factorio-calc",
    version="0.1.0",
    instructions=(
        "Factorio 2.0 production calculator (FactorioCalc LP solver). Internal names (\"iron-plate\", "
        "\"assembling-machine-2\"); rates are per minute; machine counts are exact (fractional) plus rounded up. "
        "game=\"space-age\" uses Space Age data; recycling, asteroid, quality-variant and barrel recipes are never "
        "picked automatically, and ores, water and crude oil are raw inputs unless raw_inputs says otherwise. "
        "Mining drills are computed from vanilla drill speeds (no resource depletion)."
    ),
)


def _fmt(v: float) -> str:
    return f"{v:,.4g}"


def _guard(fn):
    import functools

    @functools.wraps(fn)
    async def wrapper(*a, **kw):
        try:
            return await fn(*a, **kw)
        except ToolError:
            raise
        except Exception as e:  # FactorioCalc raises ValueError / its own errors with useful text
            raise ToolError(f"{type(e).__name__}: {e}") from e

    return wrapper


def tool(description: str):
    def deco(fn):
        app.tool(name=fn.__name__, description=description)(_guard(fn))
        return fn
    return deco


@tool("Machines needed to produce target items per minute, with raw inputs, byproducts and electricity. Solves "
      "cycles and byproducts (oil cracking etc.) exactly.")
async def solve_production(
    targets: Annotated[dict[str, float], Field(description='item -> items per minute, e.g. {"electronic-circuit": 45}')],
    machines: Annotated[list[str] | None, Field(description='machines to use first, e.g. ["assembling-machine-2", "steel-furnace"]')] = None,
    preset: Literal["early", "early-mid", "late", "legendary"] = "early",
    recipes: Annotated[list[str] | None, Field(description='force these recipes, e.g. ["advanced-oil-processing"]')] = None,
    raw_inputs: Annotated[list[str] | None, Field(description="items treated as inputs (default: ores, water, crude oil, wood and Space Age raw resources)")] = None,
    game: Game = "base",
    fuel: Annotated[str | None, Field(description="fuel for burner machines")] = "coal",
) -> str:
    plan = calc.solve_production(targets, machines=machines, preset=preset, recipes=recipes,
                                 raw_inputs=raw_inputs, game=game, fuel=fuel)
    lines = [f"Plan for {', '.join(f'{n} {_fmt(r)}/min' for n, r in targets.items())} ({game}):"]
    for m in plan.machines:
        lines.append(f"  {_fmt(m['count'])} x {m['machine']} on {m['recipe']} (build {m['count_rounded_up']})")
    lines.append("Outputs: " + ", ".join(f"{n} {_fmt(r)}/min" for n, r in plan.outputs.items()))
    lines.append("Inputs: " + (", ".join(f"{n} {_fmt(r)}/min" for n, r in plan.inputs.items()) or "none"))
    if plan.electricity_mw > 0:
        lines.append(f"Electricity: {_fmt(plan.electricity_mw)} MW")
    lines.extend("Note: " + n for n in plan.notes)
    return "\n".join(lines)


@tool("Mining drills needed for a resource rate (vanilla drill speeds; optional mining productivity bonus).")
async def mining_drills(
    resource: str,
    per_min: Annotated[float, Field(gt=0)],
    drill: Literal["burner-mining-drill", "electric-mining-drill", "big-mining-drill"] = "electric-mining-drill",
    mining_productivity: Annotated[float, Field(ge=0, le=10, description="research bonus, e.g. 0.2 for +20%")] = 0.0,
) -> str:
    r = calc.mining_drills(resource, per_min, drill, mining_productivity)
    return (f"{_fmt(r['drills'])} x {drill} (build {r['drills_rounded_up']}) for {resource} {_fmt(per_min)}/min "
            f"— {_fmt(r['per_drill_per_min'])}/min per drill. {r['note']}.")


@tool("Per-machine flows of one recipe and how many machines fill (or drain) one belt of each item.")
async def machines_per_belt(
    recipe: str,
    machine: str,
    belt: Literal["transport-belt", "fast-transport-belt", "express-transport-belt", "turbo-transport-belt"] = "transport-belt",
    game: Game = "base",
) -> str:
    r = calc.machines_per_belt(recipe, machine, belt, game)
    flows = ", ".join(f"{n} {'+' if v > 0 else ''}{_fmt(v)}/min" for n, v in r["per_machine_per_min"].items())
    fill = ", ".join(f"{n}: {_fmt(v)}" for n, v in r["machines_to_fill_or_drain_one_belt"].items())
    return f"One {machine} on {recipe}: {flows}.\nMachines per full {belt} ({r['belt_items_per_min']}/min): {fill}."


@tool("Belts of each tier needed to carry a rate (items per minute).")
async def belts_needed(per_min: Annotated[float, Field(gt=0)]) -> str:
    return ", ".join(f"{b}: {_fmt(n)}" for b, n in calc.belts_needed(per_min).items())


@tool("Ingredients, products, time and category of a recipe.")
async def recipe_info(name: str, game: Game = "base") -> str:
    r = calc.recipe_info(name, game)
    ing = " + ".join(f"{_fmt(v)} {k}" for k, v in r["ingredients"].items())
    prod = " + ".join(f"{_fmt(v)} {k}" for k, v in r["products"].items())
    return f"{name}: {ing} -> {prod} in {_fmt(r['time_s'])} s (category {r['category']})."


def main() -> None:
    app.run()


if __name__ == "__main__":
    main()
