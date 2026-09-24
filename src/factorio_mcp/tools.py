"""MCP tools. Capability-only: tools describe what they do, never why or when an
agent should use them. Every tool acts as the ONE character this MCP instance
is bound to."""

from __future__ import annotations

import asyncio
import functools
import time
from collections import Counter
from typing import Annotated, Any, Literal

from mcp.server.mcpserver import MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pydantic import BaseModel, Field

from . import checks
from . import format as fmt
from .bridge import JobResult, ModError, as_list
from .game import Game

Coord = Annotated[float, Field(description="map coordinate in tiles (x grows east, y grows south)")]
Direction = Annotated[int, Field(ge=0, le=15, description="16-way direction: 0=north, 4=east, 8=south, 12=west")]
Items = Annotated[
    dict[str, int],
    Field(description='item name -> count, e.g. {"coal": 10}; other qualities as "name@quality", e.g. "iron-plate@rare"'),
]
WaitS = Annotated[
    float | None,
    Field(ge=0, le=600, description="seconds to wait for the job to finish (default 0: queue it behind your other jobs and return at once; if a queued job fails, the jobs behind it are cancelled and you are told on your next call)"),
]
Replace = Annotated[bool, Field(description="cancel your running and queued jobs first instead of queueing behind them")]
class Endpoint(BaseModel):
    """A route endpoint."""
    x: float
    y: float
    direction: int | None = Field(None, ge=0, le=15, description="required belt direction at this end (16-way)")
    port: Literal["tile", "drop", "pickup", "belt", "fluid"] = Field("tile", description=(
        'tile = this tile; drop = the output tile of the drill/inserter at x,y; pickup = the pickup tile of the '
        'inserter at x,y; belt = start: continue the belt at x,y, end: join the belt at x,y from behind or the side; '
        'fluid = (pipes) a free fluid connection of the entity at x,y'))


class Point(BaseModel):
    x: float
    y: float


class Placement(BaseModel):
    item: str | None = Field(None, description="defaults to the top-level item")
    x: float
    y: float
    direction: int | None = Field(None, ge=0, le=15)


class Point(BaseModel):
    x: float
    y: float


DROP_TO = "inserters: the tile to drop into (a furnace, chest, belt...). Sets the direction for you"
PICKUP_FROM = "inserters: the tile to pick up from. Sets the direction for you"


class BuildStep(BaseModel):
    item: str = Field(description='item to place, e.g. "burner-mining-drill" (or "name@quality")')
    x: float
    y: float
    direction: int | None = Field(None, ge=0, le=15, description="16-way; an inserter's direction is the side it picks up from")
    drop_to: Point | None = Field(None, description=DROP_TO)
    pickup_from: Point | None = Field(None, description=PICKUP_FROM)
    fast_replace: bool | None = Field(None, description="swap one of your buildings standing there (else the step fails)")
    recipe: str | None = Field(None, description="recipe to set on the placed machine")
    insert: dict[str, int] | None = Field(None, description="items to move from your inventory into the placed entity")
    underground_type: Literal["input", "output"] | None = Field(None, description="underground belts: input = entrance, output = exit")


class PlanStep(BaseModel):
    type: Literal["craft", "insert", "extract", "mine", "place", "set_recipe", "rotate", "walk_to", "wait_until", "say"]
    text: str | None = Field(None, max_length=4000, description="say: what to say when this step runs (cut to 400 characters)")
    recipe: str | None = Field(None, description="craft: the recipe to craft; place / set_recipe: the recipe to set on the machine")
    count: int | None = Field(None, ge=1, le=10000, description="craft: recipe executions (a belt craft makes 2); "
                              "mine: mining operations; wait_until: the item count to wait for")
    seconds: float | None = Field(None, ge=0, le=3600, description="wait_until: wait this long")
    research: str | None = Field(None, description="wait_until: wait until this technology is researched")
    timeout_s: float | None = Field(None, ge=1, le=3600, description="wait_until: fail after this long (default 300)")
    x: float | None = None
    y: float | None = None
    items: dict[str, int] | None = None
    all: bool | None = None
    resource: str | None = None
    item: str | None = None
    direction: int | None = Field(None, ge=0, le=15)
    drop_to: Point | None = Field(None, description=DROP_TO)
    pickup_from: Point | None = Field(None, description=PICKUP_FROM)
    optional: bool | None = Field(None, description="true: if this step fails, the steps after it still run (e.g. a fuel top-up)")
    fast_replace: bool | None = Field(None, description="place: swap one of your buildings standing there (else the step fails)")


class TrainStop(BaseModel):
    station: str = Field(description="exact train stop name (case matters)")
    wait: Literal["full", "empty"] | float | None = Field(None, description='"full", "empty" or seconds (default 5)')


def _tool_errors(fn):
    """Game-side failures become MCP tool errors (isError) with the message."""

    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        try:
            return await fn(*args, **kwargs)
        except ToolError:
            raise
        except (ModError, ValueError) as e:
            raise ToolError(str(e)) from e

    return wrapper


# Tools that already return chat, or run before a binding exists.
NO_INBOX = {"read_chat", "wait_for_events", "status"}


def register(app: MCPServer, game: Game) -> None:
    async def inbox() -> str:
        """Unread chat (players and other agents) since this character's cursor, as a
        footer. Reading advances the cursor, so each line is delivered once."""
        try:
            b = await game.bridge()
            msgs = as_list((await b.read_chat()).get("messages"))
            evs = as_list((await b.read_events()).get("events"))
        except Exception:
            return ""
        out = ""
        if evs:
            failed = any(e.get("kind") == "job_failed" for e in evs)
            if failed:
                game.new_queue()
            more = f" (last 20 of {len(evs)})" if len(evs) > 20 else ""
            out += f"\n\nEvents since your last call{more}:\n" + event_lines(evs[-20:])
            if failed:
                out += "\n(Jobs queued after a failed job were cancelled. Your next job starts a new queue.)"
        if msgs:
            more = f" (last 20 of {len(msgs)})" if len(msgs) > 20 else ""
            out += f"\n\nNew chat{more}:\n" + chat_lines(msgs[-20:])
        return out

    def with_inbox(fn):
        @functools.wraps(fn)
        async def wrapper(*args, **kwargs):
            try:
                out = await fn(*args, **kwargs)
            except ToolError as e:
                raise ToolError(str(e) + await inbox()) from e
            return out + await inbox() if isinstance(out, str) else out

        return wrapper

    def tool(description: str):
        def deco(fn):
            wrapped = _tool_errors(fn)
            if game.cfg.inbox and fn.__name__ not in NO_INBOX:
                wrapped = with_inbox(wrapped)
            app.tool(name=fn.__name__, description=description)(wrapped)
            return fn

        return deco

    def wait_default(wait_s: float | None) -> float:
        return game.cfg.default_wait_s if wait_s is None else wait_s

    def describe(res: JobResult, waited: float) -> str:
        if res.status == "done":
            return f"Job #{res.job_id} ({res.type}) done: {res.detail}"
        if res.status in ("failed", "cancelled"):
            game.new_queue()  # the agent is being told: start a fresh queue
        if res.status == "failed":
            raise ToolError(f"Job #{res.job_id} ({res.type}) failed: {res.detail}")
        if res.status == "cancelled":
            raise ToolError(f"Job #{res.job_id} ({res.type}) was cancelled{': ' + res.detail if res.detail else ''}")
        return (
            f"Job #{res.job_id} ({res.type}) is still {res.status} after {waited:g}s and keeps running. "
            f"Use job_wait / job_status with job_id={res.job_id}, or job_cancel."
        )

    def skipped() -> ToolError:
        game.new_queue()
        return ToolError("Not queued: a job queued earlier failed, so it and everything queued after it were "
                         "cancelled (the failure is listed below or in get_events). Nothing from this call runs; "
                         "your next job starts a new queue.")

    def resolve_direction(x: float, y: float, direction: int | None, drop_to: Point | None,
                          pickup_from: Point | None) -> int | None:
        """drop_to / pickup_from -> the inserter direction (the side it picks up from)."""
        if drop_to is None and pickup_from is None:
            return direction
        d = checks.inserter_direction(x, y, (drop_to.x, drop_to.y) if drop_to else None,
                                      (pickup_from.x, pickup_from.y) if pickup_from else None)
        if drop_to is not None and pickup_from is not None:
            d2 = checks.inserter_direction(x, y, pickup_from=(pickup_from.x, pickup_from.y))
            if d2 != d:
                raise ValueError(f"drop_to and pickup_from at ({x}, {y}) aren't on opposite sides of the inserter")
        if direction is not None and direction != d:
            raise ValueError(f"direction {direction} at ({x}, {y}) contradicts drop_to/pickup_from, which need "
                             f"direction {d} (an inserter's direction is the side it picks up from)")
        return d

    async def layout_check(steps: list[dict[str, Any]], protos: dict[str, Any] | None = None
                           ) -> tuple[list[str], list[str]]:
        """Belt-flow and inserter-end checks for planned placements (see checks.py)."""
        try:
            if protos is None:
                names = sorted({st["item"].split("@")[0] for st in steps})
                protos = {}
                for i in range(0, len(names), 10):
                    protos.update(await game.call("describe_prototype", {"names": names[i:i + 10]}))
            plan = checks.planned(steps, protos)
            if not any(pl.kind in ("transport-belt", "inserter") for pl in plan):
                return [], []
            area, points = checks.context_request(plan)
            ctx = await game.call("layout_context", {"area": area, "points": points})
            return checks.check_plan(plan, ctx)
        except Exception as e:  # never let a check break a build
            return [f"(layout check unavailable: {e})"], []

    async def run_job(task: dict[str, Any], wait_s: float | None, replace: bool = False,
                      optional: bool = False) -> str:
        b = await game.bridge()
        if replace:
            game.new_queue()
        r = await b.enqueue(task, replace=replace, chain=game.queue, optional=optional)
        if r.get("cancelled"):
            raise skipped()
        job_id = int(r["task_id"])
        waited = wait_default(wait_s)
        if waited <= 0:
            return f"Job #{job_id} ({task['type']}) queued."
        return describe(await b.wait_job(job_id, waited), waited)

    def xy(x: float | None, y: float | None, what: str = "position") -> dict[str, float] | None:
        if (x is None) != (y is None):
            raise ValueError(f"give both x and y for the {what}, or neither")
        return None if x is None else {"x": x, "y": y}

    # ------------------------------------------------------------ status

    @tool("Connect (if needed) and report the connection, your character's binding, and a summary of its surroundings.")
    async def status() -> str:
        b = await game.bridge()
        ping = await b.call("ping")
        st = await game.call("get_state", {})
        bound = game.bound_info or {}
        body = bound.get("body", {})
        head = (
            f"Connected to Factorio {ping.get('factorio_version')} (mod {ping.get('mod_version')}"
            f"{', Space Age' if ping.get('space_age') else ''}), tick {ping.get('tick')}. "
            f"You control character '{game.character}'"
            f"{' (taken over from an idle session)' if body.get('took_over') else ''}."
        )
        kit = body.get("kit")
        if kit:
            head += f" Scenario start kit received: {fmt.items_text(kit)}."
        return head + "\n" + fmt.state(st)

    # -------------------------------------------------------- perception

    @tool("Your character's position, inventory, equipment and jobs, plus what it knows around it: players and other "
          "agent characters in view, resource patches and trees on explored ground, your force's buildings with "
          "status counts, visible enemies, research, power and top production.")
    async def look_around(radius: Annotated[float, Field(ge=5, le=150, description="tiles, default 40")] = 40) -> str:
        return fmt.state(await game.call("get_state", {"radius": radius}))

    @tool("Your character's inventory and equipment.")
    async def check_inventory() -> str:
        r = await game.call("check_inventory", {})
        inv = r.get("inventory") or {}
        text = f"{r['owner']}: {fmt.items_text(inv) or 'empty inventory'}."
        eq = r.get("equipment")
        if eq:
            text += f" Equipped: gun {eq.get('gun') or 'none'}; ammo {fmt.items_text(eq.get('ammo')) or 'none'}; armor {eq.get('armor') or 'none'}."
        return text

    @tool("Details of entities near map positions (searched within 1.5 tiles; explored ground only; other forces only "
          "while visible): type, status, recipe, crafting progress, inventories, fuel burning, energy buffer (kJ), belt "
          "contents, fluids, and for mining drills the ore left in their mining area. Up to 16 per call.")
    async def inspect_entity(
        x: float | None = None,
        y: float | None = None,
        targets: Annotated[list[Point] | None, Field(max_length=16, description="batch of positions")] = None,
    ) -> str:
        if targets:
            r = await game.call("inspect", {"targets": [t.model_dump() for t in targets]})
            out = []
            for t, e in zip(targets, as_list(r.get("entities"))):
                out.append(f"({t.x}, {t.y}): {e['error']}" if e.get("error") else fmt.inspect(e))
            return "\n".join(out)
        pos = xy(x, y)
        if pos is None:
            raise ValueError("give x and y, or targets")
        return fmt.inspect(await game.call("inspect", {"position": pos}))

    @tool("ASCII tile grid of a square area (radius up to 120): one character per tile, or per scale x scale tiles "
          "for large scans (automatic above radius 40), rows north to south. Unexplored tiles are '?'. "
          "The legend explains every symbol (uppercase = resources, lowercase = your force's buildings, @ = you).")
    async def scan_area(
        x: float | None = None,
        y: float | None = None,
        radius: Annotated[int, Field(ge=5, le=120, description="half-width in tiles, default 15")] = 15,
        scale: Annotated[int | None, Field(ge=1, le=8, description="tiles per character; default 1 up to radius 40, "
                                           "then automatic so the grid stays about 81 wide")] = None,
    ) -> str:
        params: dict[str, Any] = {"center": xy(x, y, "scan center"), "radius": radius}
        if scale:
            params["scale"] = scale
        return fmt.scan(await game.call("scan_area", params))

    @tool("The map screen: resource patches, rock clusters, forests, water and enemy bases on all ground you know "
          "(explored or charted) within radius tiles (default 320, max 640), grouped by connected chunks and listed "
          "nearest first with centre, area, size and a tile of each patch to walk to. Chunk resolution; use "
          "look_around / scan_area for detail.")
    async def map_overview(x: float | None = None, y: float | None = None,
                           radius: Annotated[int, Field(ge=32, le=640, description="tiles, default 320")] = 320) -> str:
        return fmt.overview(await game.call("map_overview", {"center": xy(x, y, "overview center"), "radius": radius}))

    @tool("Everything about up to 10 names at once — the item (stack size, fuel value), the entity it places (footprint, "
          "power use in kW, crafting/mining speed, mining area, drill drop offset, inserter pickup/drop offsets, module "
          "slots, belt speed) and the recipe that makes it (ingredients, products, time, unlocked or not).")
    async def describe_prototype(names: Annotated[list[str], Field(min_length=1, max_length=10)]) -> str:
        r = await game.call("describe_prototype", {"names": names})
        return "\n".join(fmt.prototype(n, r.get(n) or {"kind": "unknown"}) for n in names)

    @tool("The map screen's warning icons as one list: every machine of your force on charted ground with a "
          "problem status (not plugged into the electric network, no power, low power, no fuel, no recipe, missing "
          "ingredients or fluid, output full, no minable resources, ...), grouped by problem with each machine's "
          "position, nearest first. Ends with a separate, clearly-marked idle section (inserters waiting for items — "
          "no map warning, usually normal). The whole-factory punch list; analyze_factory is the detailed local version.")
    async def map_warnings() -> str:
        r = await game.call("map_warnings", {})
        groups = as_list(r.get("groups"))
        problems = [g for g in groups if not g.get("idle")]
        lines = [f"Checked {r['entities_checked']} of your force's entities on charted ground of '{r['surface']}': "
                 f"{r.get('with_problems', 0)} with problems in {len(problems)} group(s)."]
        for g in problems:
            names = ", ".join(f"{n} x{cnt}" for n, cnt in sorted(g.get("by_name", {}).items(), key=lambda kv: -kv[1]))
            more = f" (+{g['more']} more)" if g.get("more") else ""
            lines.append(f"{g['problem'].replace('_', ' ')}: {g['count']} machine(s) [{names}]{more}")
            for ent in as_list(g.get("entities")):
                lines.append(f"  {ent['name']} at ({ent['x']}, {ent['y']})")
        if not problems:
            lines.append("No machines with problems — nothing on the map is showing a warning.")
        for g in groups:
            if g.get("idle"):
                names = ", ".join(f"{n} x{cnt}" for n, cnt in sorted(g.get("by_name", {}).items(), key=lambda kv: -kv[1]))
                more = f" (+{g['more']} more)" if g.get("more") else ""
                lines.append(f"idle (no map warning, usually normal — the machine that should feed them is the real "
                             f"signal): {g['problem'].replace('_', ' ')}: {g['count']} machine(s) [{names}]{more}")
                for ent in as_list(g.get("entities")):
                    lines.append(f"  {ent['name']} at ({ent['x']}, {ent['y']})")
        return "\n".join(lines)

    @tool("The game's alert panel, read through any connected player of your force — the same warnings the human "
          "player's map shows (under attack, turret out of ammo, entity destroyed, no items for construction, ...), "
          "grouped by alert type with each alert's target, position and the tick it was raised. Force-wide "
          "information; battle_report is the headless snapshot of the same ground.")
    async def alerts() -> str:
        r = await game.call("alerts", {})
        if r.get("note"):
            return f"Alert panel ('{r['surface']}'): {r['note']}."
        groups = as_list(r.get("groups"))
        if not groups:
            return f"Alert panel ('{r['surface']}'): no alerts."
        lines = [f"Alert panel ('{r['surface']}'), {len(groups)} type(s):"]
        for g in groups:
            lines.append(f"{g['type'].replace('_', ' ')}: {g['count']} alert(s)")
            for a in as_list(g.get("alerts"))[:30]:
                at = f" at ({a['x']}, {a['y']})" if a.get("x") is not None else ""
                lines.append(f"  {a['name']}{at} (since tick {a['tick']})")
        return "\n".join(lines)

    @tool("Battlefield snapshot: your force's damaged entities (health below max, worst first — walls, turrets, "
          "machines that took hits and need repair), turrets with no ammo, enemy clusters on charted ground with "
          "the distance to your nearest entity (closest threat first), and recent combat events (attacked, under "
          "attack, destroyed). Works headless — the alert panel read needs a connected player, this doesn't.")
    async def battle_report(recent_s: Annotated[int, Field(ge=0, le=600)] = 60) -> str:
        r = await game.call("battle_report", {"recent_s": recent_s})
        lines = [f"Battlefield on '{r['surface']}' at tick {r['tick']}."]
        damaged = as_list(r.get("damaged"))
        if damaged:
            lines.append(f"damaged (needs repair), {len(damaged)} entity(ies), worst first:")
            for d in damaged:
                lines.append(f"  {d['name']} at ({d['x']}, {d['y']}): {d['hp']}/{d['max_hp']} ({d['pct']}%)")
        else:
            lines.append("damaged: none — everything of ours is at full health.")
        dry = as_list(r.get("turrets_no_ammo"))
        if dry:
            lines.append(f"turrets with NO ammo: {len(dry)}:")
            for t in dry:
                lines.append(f"  {t['name']} at ({t['x']}, {t['y']})")
        clusters = as_list(r.get("enemy_clusters"))
        if clusters:
            lines.append("enemy clusters on charted ground, closest to our things first:")
            for cl in clusters:
                near = f", {cl['nearest']['distance']} tiles from our {cl['nearest']['name']}" if cl.get("nearest") else ""
                types = ", ".join(f"{n} x{cnt}" for n, cnt in sorted(cl.get("types", {}).items(), key=lambda kv: -kv[1]))
                names = ", ".join(cl.get("top_names") or [])
                lines.append(f"  {cl['count']} enemies at ({cl['center']['x']}, {cl['center']['y']}) [{types}] "
                             f"({names}){near}")
        else:
            lines.append("enemies on charted ground: none.")
        recent = as_list(r.get("recent"))
        if recent:
            lines.append(f"recent combat (last {recent_s}s):")
            for e in recent:
                lines.append(f"  tick {e['tick']} [{e['kind'].replace('_', ' ')}] {e['text']}")
        return "\n".join(lines)

    @tool("Machines of your force in an area (explored ground) grouped by problem — no power, low power, no fuel, "
          "missing ingredients (with which ingredient when detectable), output full, depleted ore, idle — plus power summary.")
    async def analyze_factory(radius: Annotated[float, Field(ge=5, le=150)] = 40) -> str:
        r = await game.call("analyze_factory", {"radius": radius})
        lines = [f"Checked {r['machines_checked']} entities with a status within {r['radius']} tiles: "
                 f"{r['working']} working, {r.get('with_problems', 0)} with problems, "
                 f"{r.get('in_other_states', 0)} in other states."]
        problems = as_list(r.get("problems"))
        for p in problems:
            missing = f" — missing: {p['missing']}" if p.get("missing") else ""
            lines.append(f"{p['count']}x {p['name']}: {p['problem'].replace('_', ' ')}{missing} (e.g. at ({p['sample']['x']}, {p['sample']['y']}))")
        if not problems:
            lines.append("No machines with problems.")
        others = as_list(r.get("other_states"))
        if others:
            lines.append("Other states: " + "; ".join(f"{o['count']}x {o['name']} {o['state'].replace('_', ' ')}" for o in others) + ".")
        pw = r.get("power")
        if pw:
            lines.append(f"Power: {fmt.num(pw.get('production_kw', 0))} kW produced, {fmt.num(pw.get('consumption_kw', 0))} kW consumed, {pw['networks']} network(s).")
        return "\n".join(lines)

    @tool("Check whether items could be placed at explored positions right now (no side effects). Up to 24 placements "
          "per call. Answers yes, or no with the blocker when identifiable.")
    async def can_place(
        item: str | None = None,
        x: float | None = None,
        y: float | None = None,
        direction: Direction | None = None,
        placements: Annotated[list[Placement] | None, Field(max_length=24)] = None,
    ) -> str:
        if placements:
            r = await game.call("can_place", {"item": item, "placements": [
                {"item": p.item, "position": {"x": p.x, "y": p.y}, "direction": p.direction} for p in placements]})
            return "\n".join(
                f"({p.x}, {p.y}) {p.item or item}: " + ("yes" if res.get("can_place") else f"NO — {res.get('reason', 'blocked')}")
                for p, res in zip(placements, as_list(r.get("results"))))
        if item is None or x is None or y is None:
            raise ValueError("give item + x + y, or placements")
        r = await game.call("can_place", {"item": item, "position": {"x": x, "y": y}, "direction": direction})
        return f"Yes — {item} can be placed at ({x}, {y})." if r.get("can_place") else f"No — {r.get('reason', 'blocked')}."

    @tool("Nearest width x height rectangle of free land (no water, cliffs or entities; trees allowed and counted) on "
          "explored ground near a point.")
    async def find_buildable_area(
        width: Annotated[int, Field(ge=1, le=50)],
        height: Annotated[int, Field(ge=1, le=50)],
        x: float,
        y: float,
        max_distance: Annotated[float, Field(ge=5, le=100)] = 50,
    ) -> str:
        r = await game.call("find_buildable_area", {"width": width, "height": height, "near": {"x": x, "y": y}, "max_distance": max_distance})
        return (f"Free {width}x{height} area: top-left ({r['top_left']['x']}, {r['top_left']['y']}), "
                f"center ({r['center']['x']}, {r['center']['y']}); {r['trees_in_area']} tree(s) inside.")

    @tool("Your force's item and fluid production and consumption on your surface, per minute over a time window "
          "(like the production statistics window), plus all-time totals.")
    async def production_stats(
        window: Literal["5s", "1m", "10m", "1h", "10h", "50h", "250h", "1000h"] = "1m",
        names: Annotated[list[str] | None, Field(description="only these items/fluids (default: all seen)")] = None,
        kind: Literal["both", "item", "fluid"] = "both",
        top: Annotated[int, Field(ge=1, le=200)] = 20,
    ) -> str:
        r = await game.call("production_stats", {"window": window, "names": names, "kind": kind, "top": top})
        rows = as_list(r.get("rows"))
        if not rows:
            return f"No production or consumption recorded on {r.get('surface')} (window {window})."
        lines = [f"Production on {r['surface']}, window {window} (per minute; {r['total_rows']} entries, showing {len(rows)}):"]
        for row in rows:
            lines.append(
                f"{row['name']} ({row['kind']}): +{fmt.num(row['produced_per_min'])}/min, -{fmt.num(row['consumed_per_min'])}/min, "
                f"net {fmt.num(row['net_per_min'])}/min; all-time +{fmt.num(row['produced_all_time'])} / -{fmt.num(row['consumed_all_time'])}")
        return "\n".join(lines)

    @tool("Trains on your surface (id, state, mode, cars, position, station, schedule, cargo) and the known train stop names.")
    async def list_trains() -> str:
        r = await game.call("list_trains", {})
        trains = as_list(r.get("trains"))
        lines = [] if trains else ["No trains on this surface."]
        for t in trains:
            bits = [f"train #{t['id']}: {t.get('locomotives', '?')} loco + {t.get('wagons', 0)} wagon(s)",
                    "manual" if t.get("manual") else "automatic", f"state {str(t.get('state')).replace('_', ' ')}"]
            if t.get("position"):
                bits.append(f"at ({t['position']['x']}, {t['position']['y']})")
            if t.get("at_station"):
                bits.append(f'stopped at "{t["at_station"]}"')
            if t.get("schedule"):
                bits.append("route: " + " -> ".join(as_list(t["schedule"])))
            if t.get("cargo"):
                bits.append("cargo: " + fmt.items_text(t["cargo"]))
            lines.append("; ".join(bits))
        stations = as_list(r.get("stations"))
        lines.append("Train stops: " + ", ".join(f'"{s}"' for s in stations) + "." if stations else "No known train stops.")
        return "\n".join(lines)

    @tool("Blueprints your character carries (inventory and books, nested books included).")
    async def list_blueprints() -> str:
        r = await game.call("list_blueprints", {})
        bps = as_list(r.get("blueprints"))
        if not bps:
            return "Your character carries no blueprints."
        return "\n".join(f'"{b.get("label") or "(unnamed)"}" ({b["entity_count"]} entities) — {b["where"]}' for b in bps)

    @tool("Decode a carried blueprint by label into relative entity positions and its item bill (read in windows).")
    async def read_blueprint(
        label: str | None = None,
        book: str | None = None,
        offset: Annotated[int, Field(ge=0)] = 0,
        limit: Annotated[int, Field(ge=1, le=200)] = 100,
    ) -> str:
        return fmt.blueprint(await game.call("read_blueprint", {"label": label, "book": book, "offset": offset, "limit": limit}))

    @tool("Decode a blueprint export string into relative entity positions (top-left entity at 0,0), directions, "
          "recipes and the item bill. Does not build.")
    async def import_blueprint(
        string: Annotated[str, Field(min_length=10)],
        offset: Annotated[int, Field(ge=0)] = 0,
        limit: Annotated[int, Field(ge=1, le=200)] = 100,
    ) -> str:
        return fmt.blueprint(await game.call("import_blueprint", {"string": string, "offset": offset, "limit": limit}))

    @tool("Capture your force's buildings in an explored rectangle (max 200x200 tiles) as a blueprint export string, "
          "with entity counts and the map anchor of its top-left entity.")
    async def export_blueprint(x1: float, y1: float, x2: float, y2: float, label: str | None = None) -> str:
        r = await game.call("export_blueprint", {"area": [{"x": x1, "y": y1}, {"x": x2, "y": y2}], "label": label})
        counts = ", ".join(f"{n} x{c}" for n, c in sorted((r.get("entity_counts") or {}).items()))
        return (f"Exported {r['total_entities']} entities ({counts}), footprint {r['size']['w']}x{r['size']['h']}.\n"
                f"Blueprint string:\n{r['string']}")

    # ------------------------------------------------------- chat/events

    def chat_lines(msgs: list[dict[str, Any]]) -> str:
        return "\n".join(f"[chat #{m['id']}] <{m['player']}{' (agent)' if m.get('bot') else ''}> {m['text']}" for m in msgs)

    def acknowledge(evs: list[dict[str, Any]]) -> str:
        """A job_failed event shown to the agent counts as acknowledged: the next
        job starts a new queue instead of being refused."""
        if any(e.get("kind") == "job_failed" for e in evs):
            game.new_queue()
            return "\n(Jobs queued after the failed job were cancelled. Your next job starts a new queue.)"
        return ""

    def event_lines(evs: list[dict[str, Any]]) -> str:
        return "\n".join(f"[event #{e['id']} {e['kind']}] {e['text']}" for e in evs)

    @tool("Chat messages since your last read (or since since_id): players and other agents. Your own lines are "
          "left out unless include_self (use since_id=0, include_self=true for a full transcript).")
    async def read_chat(since_id: Annotated[int | None, Field(ge=0)] = None, include_self: bool = False) -> str:
        b = await game.bridge()
        r = await b.read_chat(since_id, include_self)
        msgs = as_list(r.get("messages"))
        return chat_lines(msgs[-50:]) if msgs else f"No new chat (last id {r.get('last_id')})."

    @tool("Events since your last read (or since since_id): your jobs finishing or failing, your character attacked "
          "or killed, research finished, supply warnings of duties.")
    async def get_events(since_id: Annotated[int | None, Field(ge=0)] = None) -> str:
        b = await game.bridge()
        r = await b.read_events(since_id)
        evs = as_list(r.get("events"))
        return (event_lines(evs[-50:]) + acknowledge(evs)) if evs else f"No new events (last id {r.get('last_id')})."

    @tool("Block until new chat or a new event arrives (returns as soon as anything arrives), or timeout_s passes. "
          "Use one wait per call and react to what it returns.")
    async def wait_for_events(timeout_s: Annotated[float, Field(ge=1, le=3600)] = 30) -> str:
        b = await game.bridge()
        deadline = time.monotonic() + timeout_s
        while True:
            chat = as_list((await b.read_chat()).get("messages"))
            evs = as_list((await b.read_events()).get("events"))
            if chat or evs:
                return "\n".join(x for x in (chat_lines(chat), event_lines(evs)) if x) + acknowledge(evs)
            if time.monotonic() >= deadline:
                return f"Nothing new in {timeout_s:g}s."
            await asyncio.sleep(0.5)

    # --------------------------------------------------- instant actions

    @tool("Show people watching a short line about what you are doing (up to 120 characters). It appears under "
          "your character's name in the game and under your camera in /follow-cam and /follow-cams, followed by what "
          "your character is doing right now. It replaces the previous line; an empty text clears it.")
    async def set_status(text: Annotated[str, Field(max_length=120)] = "") -> str:
        r = await game.call("set_status", {"text": text})
        return "Status cleared." if r.get("cleared") else f"Status: {r.get('status')}"

    @tool("Say something in game chat as your character: at once, or with queued=true when the jobs queued before "
          "it have run (so an announcement doesn't come before the work it describes).")
    async def say(text: Annotated[str, Field(min_length=1, max_length=4000, description="cut to 400 characters in game")],
                  queued: bool = False) -> str:
        if queued:
            return await run_job({"type": "say", "text": text}, None)
        await game.call("say", {"text": text})
        return "Said."

    @tool("Queue a technology for research for your force.")
    async def start_research(technology: str) -> str:
        r = await game.call("start_research", {"technology": technology})
        return f"Research queued: {r['technology']}."

    @tool("Move a gun, ammo and/or armor from your main inventory into your equipment slots, and/or unequip slots "
          "(unequip=[\"ammo\"] moves the ammo slot's contents back to the main inventory; crafted or picked-up ammo "
          "goes into the gun's ammo slot by itself).")
    async def equip(gun: str | None = None, ammo: str | None = None, armor: str | None = None,
                    unequip: list[Literal["gun", "ammo", "armor"]] | None = None) -> str:
        if not (gun or ammo or armor or unequip):
            raise ValueError("give gun, ammo, armor and/or unequip")
        r = await game.call("equip", {"gun": gun, "ammo": ammo, "armor": armor, "unequip": unequip})
        moved = as_list(r.get("unequipped"))
        head = f"Moved {', '.join(moved)} to the main inventory. " if moved else ""
        return head + f"Equipped — gun {r.get('gun') or 'none'}, ammo {fmt.items_text(r.get('ammo')) or 'none'}, armor {r.get('armor') or 'none'}."

    @tool("Leave the vehicle you are in.")
    async def exit_vehicle() -> str:
        r = await game.call("exit_vehicle", {})
        return f"Out of the {r['exited']} at ({r['position']['x']:.1f}, {r['position']['y']:.1f})."

    @tool("Set a train's schedule (existing stop names with wait conditions) and switch it to automatic.")
    async def set_train_schedule(train_id: int, stops: Annotated[list[TrainStop], Field(min_length=1, max_length=10)]) -> str:
        r = await game.call("set_train_schedule", {"train_id": train_id, "stops": [s.model_dump() for s in stops]})
        return f"Train #{r['train_id']} set to automatic with {r['stops']} stop(s)." + ("" if r.get("fueled") else " Its locomotives have no fuel.")

    @tool("Create a new body for your character at the spawn point (after death), with the scenario's respawn kit.")
    async def respawn() -> str:
        r = await game.call("respawn", {})
        at = f"({r['position']['x']:.1f}, {r['position']['y']:.1f})"
        return f"Your character already has a body at {at}." if r.get("already_existed") else f"Respawned at {at}."

    # --------------------------------------------------------------- jobs

    @tool("Walk to a map position with the game pathfinder at normal walking speed. The goal must be on explored "
          "ground or within the exploration radius (default 64 tiles) of you.")
    async def walk_to(x: Coord, y: Coord, arrive_within: Annotated[float, Field(ge=0.5, le=10)] = 1.0,
                      wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "walk_to", "target": {"x": x, "y": y}, "arrive_within": arrive_within}, wait_s, replace)

    @tool("Board the nearest free car (fuelling it from your inventory if needed) and drive to a position.")
    async def drive_to(x: Coord, y: Coord, arrive_within: Annotated[float, Field(ge=2, le=15)] = 3,
                       wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "drive_to", "target": {"x": x, "y": y}, "arrive_within": arrive_within}, wait_s, replace)

    @tool("Persistent job: follow a player at a distance until cancelled. Replaces your current jobs.")
    async def follow_player(player: str | None = None, distance: Annotated[float, Field(ge=1, le=10)] = 3) -> str:
        return await run_job({"type": "follow_player", "player": player, "distance": distance}, 0, True)

    @tool("Mine by hand (vanilla mining time and reach): either the minable thing at x,y, or `count` mining operations "
          'of a resource name ("iron-ore", "coal", "stone", "tree", "rock", ...) found on explored ground within 200 tiles. '
          "One operation = 1 ore from a patch, or one whole tree/rock: count=2 with \"rock\" mines two rocks "
          "(a big rock gives about 20–25 stone).")
    async def mine(x: float | None = None, y: float | None = None, resource: str | None = None,
                   count: Annotated[int | None, Field(ge=1, le=200)] = None,
                   wait_s: WaitS = None, replace: Replace = False) -> str:
        pos = xy(x, y)
        if (resource is None) == (pos is None):
            raise ValueError("give either a position (x and y) or a resource name")
        task = ({"type": "mine", "resource": resource, "count": count} if resource
                else {"type": "mine", "target": pos, "count": count})
        return await run_job(task, wait_s, replace)

    @tool("Place a building from your inventory (walks within build range, steps out of the footprint; normal "
          "placement rules). Inserters: their direction is the side they pick up from (facing north = picks from the "
          "north tile, drops south); or pass drop_to / pickup_from and the direction is worked out.")
    async def place_entity(item: str, x: Coord, y: Coord, direction: Direction | None = None,
                           underground_type: Annotated[Literal["input", "output"] | None, Field(description="underground belts: input = entrance, output = exit")] = None,
                           drop_to: Annotated[Point | None, Field(description=DROP_TO)] = None,
                           pickup_from: Annotated[Point | None, Field(description=PICKUP_FROM)] = None,
                           fast_replace: Annotated[bool, Field(description="if one of your buildings is in the way, swap it like a "
                                                               "player does (it goes to your inventory, its contents into the new one); "
                                                               "otherwise the placement fails")] = False,
                           wait_s: WaitS = None, replace: Replace = False) -> str:
        direction = resolve_direction(x, y, direction, drop_to, pickup_from)
        return await run_job({"type": "place", "item": item, "position": {"x": x, "y": y}, "direction": direction,
                              "underground_type": underground_type, "fast_replace": fast_replace}, wait_s, replace)

    @tool("Hand-craft with your character's crafting queue (real crafting time; missing intermediates are queued too "
          "and reported). count is the number of recipe executions: one transport-belt craft makes 2 belts, one "
          "copper-cable craft makes 2 cables. Ingredients come from what you carry, not from chests; completion "
          "reports items made vs items in pocket, and the job fails with instructions if results can't fit.")
    async def craft_items(recipe: str, count: Annotated[int, Field(ge=1, le=1000)] = 1,
                          wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "craft", "recipe": recipe, "count": count}, wait_s, replace)

    @tool("Move items from your inventory into the entity at x,y (walks within reach). "
          "Belt tiles too: the items land on that tile's own lanes, up to 8 per tile.")
    async def insert_items(x: Coord, y: Coord, items: Items, optional: Annotated[bool, Field(description="true: if this fails, the jobs queued after it still run (e.g. a fuel top-up)")] = False,
                           wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "insert", "target": {"x": x, "y": y}, "items": items}, wait_s, replace, optional)

    @tool("Take items out of the entity at x,y into your inventory: specific counts, or all=true (walks within reach). "
          "Belt tiles too: takes what is on that tile's lanes right now (a full tile holds up to 8 items; belts have no "
          "other inventory, so all=true empties the tile).")
    async def extract_items(x: Coord, y: Coord, items: Items | None = None, all: bool = False, optional: Annotated[bool, Field(description="true: if this fails, the jobs queued after it still run (e.g. a fuel top-up)")] = False,
                            wait_s: WaitS = None, replace: Replace = False) -> str:
        if items is None and not all:
            raise ValueError("pass items with counts, or all=true")
        return await run_job({"type": "extract", "target": {"x": x, "y": y}, "items": items, "all": all}, wait_s, replace,
                             optional)

    @tool("Queue a job that waits until a condition holds, so the jobs queued after it don't race the game "
          "(smelting not finished yet, research not done yet). Give exactly one: seconds; or item (with count) in "
          "the entity at x,y, or in your own inventory without x,y; or research (a technology name). It fails "
          "after timeout_s (default 300), and like any failure that cancels the jobs queued after it.")
    async def wait_until(seconds: Annotated[float | None, Field(ge=0, le=3600)] = None,
                         item: str | None = None, count: Annotated[int, Field(ge=1, le=100000)] = 1,
                         x: float | None = None, y: float | None = None, research: str | None = None,
                         timeout_s: Annotated[float, Field(ge=1, le=3600)] = 300,
                         optional: Annotated[bool, Field(description="true: timing out doesn't cancel the jobs queued after it")] = False,
                         wait_s: WaitS = None, replace: Replace = False) -> str:
        if sum(v is not None for v in (seconds, item, research)) != 1:
            raise ValueError("give exactly one of seconds, item or research")
        task: dict[str, Any] = {"type": "wait_until", "timeout_s": timeout_s}
        if seconds is not None:
            task["seconds"] = seconds
        elif research is not None:
            task["research"] = research
        else:
            task["item"], task["count"] = item, count
            at = xy(x, y, "entity to watch")
            if at:
                task["at"] = at
        return await run_job(task, wait_s, replace, optional)

    @tool("Set the recipe of the crafting machine at x,y (walks within reach).")
    async def set_recipe(x: Coord, y: Coord, recipe: str, wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "set_recipe", "target": {"x": x, "y": y}, "recipe": recipe}, wait_s, replace)

    @tool("Rotate the entity at x,y one step, or to a 16-way direction (walks within reach).")
    async def rotate_entity(x: Coord, y: Coord, direction: Direction | None = None,
                            wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "rotate", "target": {"x": x, "y": y}, "direction": direction}, wait_s, replace)

    async def dry_run(steps: list[BuildStep], auto_craft: bool) -> str:
        """Checks a plan without building: item bill vs inventory, recipe
        validity, placement against the current map, overlaps between steps."""
        inv = (await game.call("check_inventory", {})).get("inventory") or {}
        need = Counter(s.item for s in steps)
        for s in steps:  # items to insert into placed entities come from the inventory too
            for k, n in (s.insert or {}).items():
                need[k] += n
        missing = {k: n - inv.get(k, 0) for k, n in need.items() if n > inv.get(k, 0)}
        names = sorted({s.item.split("@")[0] for s in steps} | {s.recipe for s in steps if s.recipe})
        # item keys like "coal@rare" in insert lists don't need prototypes here
        protos: dict[str, Any] = {}
        for i in range(0, len(names), 10):
            protos.update(await game.call("describe_prototype", {"names": names[i:i + 10]}))
        problems: list[str] = []
        for i, s in enumerate(steps, 1):
            if s.recipe:
                rp = (protos.get(s.recipe) or {}).get("recipe")
                if not rp:
                    problems.append(f"step {i}: no recipe called '{s.recipe}'")
                elif rp.get("enabled") is False:
                    problems.append(f"step {i}: recipe {s.recipe} is not unlocked")
        # overlaps between steps (footprints from prototypes; 90° turns swap axes)
        rects = []
        for i, s in enumerate(steps, 1):
            p = (protos.get(s.item.split("@")[0]) or {}).get("entity") or {}
            w, h = p.get("tile_width") or 1, p.get("tile_height") or 1
            if (s.direction or 0) in (4, 12):
                w, h = h, w
            sx, sy = checks.snap(s.x, int(w)), checks.snap(s.y, int(h))  # as the mod aligns it
            rects.append((i, sx - w / 2, sy - h / 2, sx + w / 2, sy + h / 2))
        for a in range(len(rects)):
            for b_ in range(a + 1, len(rects)):
                i, ax1, ay1, ax2, ay2 = rects[a]
                j, bx1, by1, bx2, by2 = rects[b_]
                if ax1 < bx2 - 1e-6 and bx1 < ax2 - 1e-6 and ay1 < by2 - 1e-6 and by1 < ay2 - 1e-6:
                    problems.append(f"steps {i} and {j} overlap")
        blocked = []
        for i in range(0, len(steps), 24):
            batch = steps[i:i + 24]
            r = await game.call("can_place", {"placements": [
                {"item": s.item.split("@")[0], "position": {"x": s.x, "y": s.y}, "direction": s.direction} for s in batch]})
            for k, (s, res) in enumerate(zip(batch, as_list(r.get("results"))), i + 1):
                if not res.get("can_place"):
                    blocked.append(f"step {k} {s.item} at ({s.x}, {s.y}): {res.get('reason', 'blocked')}")
        lines = [f"Dry run of {len(steps)} step(s) — nothing was built."]
        lines.append(f"Items needed (placements + inserts): {fmt.items_text(dict(need))}.")
        lines.append(("Missing from your inventory: " + fmt.items_text(missing)
                      + (" (auto_craft would try to hand-craft these first)." if auto_craft else ".")) if missing
                     else "You carry every item needed.")
        lines.append(f"{len(steps) - len(blocked)}/{len(steps)} placements are free on the current map"
                     + (":" if blocked else "."))
        lines.extend("  " + b for b in blocked)
        lines.extend(problems)
        warns, ins_lines = await layout_check(
            [{"item": st.item, "x": st.x, "y": st.y, "direction": st.direction or 0} for st in steps], protos)
        if ins_lines:
            lines.append("Inserters:")
            lines.extend("  " + ln for ln in ins_lines)
        if warns:
            lines.append("Layout warnings:")
            lines.extend("  " + w for w in warns)
        return "\n".join(lines)

    @tool("Build many entities as ONE job: steps are placed in order (walking within build range, items from your "
          "inventory, normal placement rules), each optionally setting a recipe and inserting items. Failed steps are "
          "reported and skipped unless stop_on_error. auto_craft hand-crafts missing placeable items first. "
          "Inserter steps can give drop_to / pickup_from instead of a direction. Belt flow (dead-end corners, belts "
          "facing each other) and what each inserter picks from / drops into are checked and reported as warnings. "
          "dry_run=true only checks the plan (items, recipes, placement, overlaps, layout) without building.")
    async def build_plan(
        steps: Annotated[list[BuildStep], Field(min_length=1, max_length=100)],
        stop_on_error: bool = False,
        auto_craft: bool = True,
        dry_run: bool = False,
        wait_s: WaitS = None,
        replace: Replace = False,
    ) -> str:
        for st in steps:
            st.direction = resolve_direction(st.x, st.y, st.direction, st.drop_to, st.pickup_from)
        if dry_run:
            return await dry_run_plan(steps, auto_craft)
        warns, _ = await layout_check([{"item": st.item, "x": st.x, "y": st.y, "direction": st.direction or 0}
                                       for st in steps])
        note = ("\nLayout warnings (the plan was queued anyway; fix with rotate_entity or cancel with job_cancel):\n"
                + "\n".join("  " + w for w in warns)) if warns else ""
        task = {"type": "build_plan", "stop_on_error": stop_on_error, "auto_craft": auto_craft, "steps": [
            {"item": s.item, "position": {"x": s.x, "y": s.y}, "direction": s.direction, "recipe": s.recipe, "insert": s.insert,
             "underground_type": s.underground_type, "fast_replace": s.fast_replace}
            for s in steps]}
        try:
            return await run_job(task, wait_s, replace) + note
        except ToolError as e:
            raise ToolError(str(e) + note) from e

    dry_run_plan = dry_run

    @tool("Build a whole blueprint as ONE job, anchored so its top-left entity lands at (anchor_x, anchor_y): from an "
          "export string, or a carried blueprint by label. Up to 1000 entities; per-step failures are reported.")
    async def build_blueprint(
        anchor_x: Coord,
        anchor_y: Coord,
        string: Annotated[str | None, Field(description="blueprint export string")] = None,
        label: str | None = None,
        book: str | None = None,
        stop_on_error: bool = False,
        wait_s: WaitS = None,
        replace: Replace = False,
    ) -> str:
        if not string and not label:
            raise ValueError("give a blueprint export string, or the label of a carried blueprint")
        task = {"type": "build_blueprint", "string": string, "label": label, "book": book,
                "anchor": {"x": anchor_x, "y": anchor_y}, "stop_on_error": stop_on_error}
        return await run_job(task, wait_s, replace)

    @tool("Queue a sequence of actions (craft, insert, extract, mine, place, set_recipe, rotate, walk_to) as chained "
          "jobs. If one fails, the rest is cancelled, except that a step marked optional only reports its failure. "
          "Place steps for inserters can give drop_to / pickup_from instead of a direction. Waits for the last one up "
          "to wait_s and then lists every step's outcome.")
    async def run_plan(steps: Annotated[list[PlanStep], Field(min_length=1, max_length=25)],
                       wait_s: WaitS = None, replace: Replace = False) -> str:
        b = await game.bridge()
        if replace:
            game.new_queue()
        chain = game.queue
        ids: list[int] = []
        for i, s in enumerate(steps):
            d = s.model_dump(exclude_none=True)
            optional = bool(d.pop("optional", False))
            d.pop("drop_to", None), d.pop("pickup_from", None)
            if s.type == "place" and (s.drop_to or s.pickup_from):
                if s.x is None or s.y is None:
                    raise ValueError(f"step {i + 1}: give x and y with drop_to / pickup_from")
                d["direction"] = resolve_direction(s.x, s.y, s.direction, s.drop_to, s.pickup_from)
            x, y = d.pop("x", None), d.pop("y", None)
            if x is not None and y is not None:
                d["position" if s.type == "place" else ("at" if s.type == "wait_until" else "target")] = {"x": x, "y": y}
            r = await b.enqueue(d, replace=replace and i == 0, quiet=i < len(steps) - 1, chain=chain, optional=optional)
            if r.get("cancelled"):
                if not ids:
                    raise skipped()
                game.new_queue()
                raise ToolError(f"queued {len(ids)} step(s), then an earlier step failed; the rest was skipped — see get_events")
            ids.append(int(r["task_id"]))
        waited = wait_default(wait_s)
        head = "Plan queued: " + ", ".join(f"#{jid} {st.type}" for jid, st in zip(ids, steps)) + "."
        if waited <= 0:
            return head
        res = await b.wait_job(ids[-1], waited)
        if not res.finished:
            states = [await b.job(jid) for jid in ids]
            running = next((j for j in states if j.status == "running"), None)
            left = sum(1 for j in states if j.status == "queued")
            now = f"job #{running.job_id} ({running.type}) is running" if running else "the plan is still running"
            return head + f"\nStill working after {waited:g}s: {now}, {left} step(s) queued behind it. " \
                          f"Use job_status / job_wait, or job_cancel."
        outcomes = [await b.job(jid) for jid in ids]
        lines = [head] + [f"  #{jr.job_id} {jr.type}: {jr.status}{' — ' + jr.detail if jr.detail else ''}"
                          for jr in outcomes]
        failed = next((jr for jr in outcomes if jr.status == "failed" and not steps[ids.index(jr.job_id)].optional), None)
        if failed:
            game.new_queue()
            raise ToolError("\n".join(lines) + f"\nJob #{failed.job_id} ({failed.type}) failed; the steps after it were cancelled.")
        return "\n".join(lines)

    @tool("Mine your force's own buildings back into your inventory (vanilla mining time): the nearest one at x,y, "
          "or all within area_radius (max 10 tiles, 50 buildings).")
    async def deconstruct(x: Coord, y: Coord, area_radius: Annotated[float | None, Field(ge=1, le=10)] = None,
                          wait_s: WaitS = None, replace: Replace = False) -> str:
        task = ({"type": "deconstruct", "area": {"center": {"x": x, "y": y}, "radius": area_radius}}
                if area_radius else {"type": "deconstruct", "target": {"x": x, "y": y}})
        return await run_job(task, wait_s, replace)

    @tool("Fight visible enemies around a point with your equipped gun (walks into range, shoots, next target); "
          "anchored to the radius; retreats below flee_below health.")
    async def fight(x: float | None = None, y: float | None = None, radius: Annotated[float, Field(ge=5, le=40)] = 20,
                    flee_below: Annotated[float, Field(ge=0.05, le=0.9)] = 0.3,
                    wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "fight", "target": xy(x, y), "radius": radius, "flee_below": flee_below}, wait_s, replace)

    @tool("Persistent job: guard an area — shoot enemies that come near, refill ammo turrets and repair structures "
          "from your inventory — until cancelled. Replaces your current jobs.")
    async def defend_area(x: float | None = None, y: float | None = None, radius: Annotated[float, Field(ge=8, le=32)] = 16) -> str:
        return await run_job({"type": "defend_area", "center": xy(x, y), "radius": radius}, 0, True)

    @tool("Persistent job: keep burner machines around a point fuelled from your inventory until cancelled. "
          "Replaces your current jobs.")
    async def keep_fueled(x: float | None = None, y: float | None = None, radius: Annotated[float, Field(ge=5, le=40)] = 24,
                          fuel: str | None = None) -> str:
        return await run_job({"type": "keep_fueled", "center": xy(x, y), "radius": radius, "fuel": fuel}, 0, True)

    def segments(steps: list[dict[str, Any]]) -> list[str]:
        """Run-length summary: consecutive same item+direction on one line."""
        names = {0: "north", 4: "east", 8: "south", 12: "west"}
        out, run = [], []
        def flush():
            if run:
                a, b = run[0], run[-1]
                kind = a.get("underground_type")
                label = f"{a['item']}{' ' + ('entrance' if kind == 'input' else 'exit') if kind else ''}"
                where = f"({a['x']}, {a['y']})" if len(run) == 1 else f"({a['x']}, {a['y']})–({b['x']}, {b['y']})"
                facing = "" if a["item"] == "pipe" else f" facing {names.get(a['direction'], a['direction'])}"
                out.append(f"  {len(run)} x {label}{facing} {where}")
        for st in steps:
            if run and st["item"] == run[-1]["item"] and (st["direction"] == run[-1]["direction"] or st["item"] == "pipe") \
                    and not st.get("underground_type") and not run[-1].get("underground_type"):
                run.append(st)
            else:
                flush()
                run = [st]
        flush()
        return out

    async def route(kind: str, params: dict[str, Any], build: bool, wait_s: float | None, replace: bool) -> str:
        r = await game.call(f"route_{kind}", params)
        steps = as_list(r.get("steps"))
        lines = [f"Route {r['from']} -> {r['to']}: {r['length']} placements, {r.get('turns', 0)} turns, "
                 f"{r.get('underground_pairs', 0)} underground pair(s); {r.get('expansions')} search expansions."]
        lines.extend(segments(steps))
        lines.append("Bill: " + fmt.items_text(r.get("bill")) + ".")
        if r.get("missing"):
            lines.append("Missing from your inventory: " + fmt.items_text(r["missing"]) + ".")
        unavailable = as_list(r.get("unavailable"))
        if unavailable:
            lines.append("Not craftable now (recipe not unlocked) and not carried: " + ", ".join(unavailable) + ".")
        if not r.get("underground_used"):
            lines.append("Undergrounds were not used (disabled, or not carried and not craftable).")
        mine_first = as_list(r.get("mine_first"))
        if mine_first:
            lines.append(f"{len(mine_first)} tree(s)/rock(s) on the path must be mined first: "
                         + ", ".join(f"{o['name']} ({o['x']:.1f}, {o['y']:.1f})" for o in mine_first[:10])
                         + ("…" if len(mine_first) > 10 else ""))
        for e in as_list(r.get("effects")):
            lines.append("Effect: " + e)
        if not build:
            lines.append("Nothing was built. Call again with build=true, or pass the placements to build_plan.")
            return "\n".join(lines)
        if unavailable:
            raise ToolError("\n".join(lines) + "\nNot building: the route needs items you neither carry nor can craft.")
        b = await game.bridge()
        if replace:
            game.new_queue()
        chain = game.queue
        ids: list[int] = []
        tasks: list[dict[str, Any]] = [{"type": "mine", "target": {"x": o["x"], "y": o["y"]}} for o in mine_first]
        for i in range(0, len(steps), 100):
            tasks.append({"type": "build_plan", "stop_on_error": True, "auto_craft": True, "steps": [
                {"item": s_["item"], "position": {"x": s_["x"], "y": s_["y"]}, "direction": s_["direction"],
                 "underground_type": s_.get("underground_type")} for s_ in steps[i:i + 100]]})
        for k, t in enumerate(tasks):
            res = await b.enqueue(t, replace=replace and k == 0, quiet=k < len(tasks) - 1, chain=chain)
            if res.get("cancelled"):
                if not ids:
                    raise skipped()
                game.new_queue()
                raise ToolError("an earlier step of the route build failed; the rest was cancelled — see get_events")
            ids.append(int(res["task_id"]))
        lines.append(f"Building as jobs #{ids[0]}–#{ids[-1]} ({len(tasks)} job(s)).")
        waited = wait_default(wait_s)
        if waited <= 0:
            return "\n".join(lines)
        res = await b.wait_job(ids[-1], waited)
        if res.status == "cancelled":
            for jid in ids:
                jr = await b.job(jid)
                if jr.status == "failed":
                    game.new_queue()
                    raise ToolError("\n".join(lines) + f"\nJob #{jid} ({jr.type}) failed: {jr.detail}; the rest was cancelled.")
        lines.append(describe(res, waited))
        return "\n".join(lines)

    @tool("Check a belt line: follows it both ways from the belt at x,y (through turns, undergrounds and splitters) and "
          "lists its legs (which way items move), how it starts and ends (dead end, side-load, a building it can't "
          "feed), what feeds it (inserters, drills, side-loads) and what takes from it, and the items on each lane "
          "with fill %. Use after building a belt; measure_belt checks real throughput.")
    async def trace_belt(x: Coord, y: Coord) -> str:
        return fmt.belt_trace(await game.call("trace_belt", {"position": {"x": x, "y": y}}))

    @tool("Queue a job that watches the belt at x,y for `seconds` and counts the items that actually pass, per lane, "
          "against the belt's capacity (a yellow belt: 450/min per lane, 900/min in total). It says whether the belt "
          "is flowing, backed up (items not moving) or empty. Waits for the result by default.")
    async def measure_belt(x: Coord, y: Coord, seconds: Annotated[float, Field(ge=2, le=120)] = 10,
                           wait_s: WaitS = None, replace: Replace = False) -> str:
        return await run_job({"type": "measure_belt", "target": {"x": x, "y": y}, "seconds": seconds},
                             seconds + 20 if wait_s is None else wait_s, replace)

    @tool("Plan a belt route between two points on explored ground and optionally build it (build=true queues normal "
          "build jobs: items from your inventory, auto-crafted if missing). A* over tiles and facings with underground "
          "belts to cross obstacles and other belts; never placed where a foreign belt, inserter or drill would "
          "interact with it; checked for self side-loading. Returns placements, bill of materials, trees to mine "
          "and the effect on a joined belt.")
    async def route_belt(
        start: Endpoint,
        end: Endpoint,
        belt: Literal["transport-belt", "fast-transport-belt", "express-transport-belt", "turbo-transport-belt"] = "transport-belt",
        allow_underground: Annotated[bool | None, Field(description="default: only if you carry underground belts or can craft them")] = None,
        clear_obstacles: Annotated[bool, Field(description="route through trees/rocks (they are mined first when building)")] = False,
        margin: Annotated[int, Field(ge=2, le=40, description="tiles of search space around the endpoints")] = 12,
        avoid: Annotated[list[list[float]] | None, Field(description="rectangles [x1,y1,x2,y2] to keep free")] = None,
        planned_belts: Annotated[list[list[float]] | None, Field(description="belts planned but not built yet: [x,y,direction16]")] = None,
        through_inserters: Annotated[bool, Field(description="let the belt pass inserter pickup/drop and drill drop tiles "
                                                 "(by default it detours around them; a belt through an inserter's "
                                                 "pickup tile feeds that inserter)")] = False,
        build: bool = False,
        wait_s: WaitS = None,
        replace: Replace = False,
    ) -> str:
        return await route("belt", {"from": start.model_dump(exclude_none=True), "to": end.model_dump(exclude_none=True), "belt": belt, "allow_underground": allow_underground,
                                    "clear_obstacles": clear_obstacles, "margin": margin, "avoid": avoid,
                                    "planned_belts": planned_belts, "through_inserters": through_inserters},
                     build, wait_s, replace)

    @tool("Plan a pipe route between two points on explored ground and optionally build it (build=true queues normal "
          "build jobs). Pipes never touch foreign fluid connections (no fluid mixing); pipe-to-ground pairs pass "
          "obstacles. Use port \"fluid\" to start or end at an entity's free fluid connection.")
    async def route_pipe(
        start: Endpoint,
        end: Endpoint,
        allow_underground: Annotated[bool | None, Field(description="default: only if you carry pipe-to-ground or can craft it")] = None,
        clear_obstacles: bool = False,
        margin: Annotated[int, Field(ge=2, le=40)] = 12,
        avoid: Annotated[list[list[float]] | None, Field(description="rectangles [x1,y1,x2,y2] to keep free")] = None,
        build: bool = False,
        wait_s: WaitS = None,
        replace: Replace = False,
    ) -> str:
        return await route("pipe", {"from": start.model_dump(exclude_none=True), "to": end.model_dump(exclude_none=True), "allow_underground": allow_underground,
                                    "clear_obstacles": clear_obstacles, "margin": margin, "avoid": avoid},
                           build, wait_s, replace)

    @tool("Status of one of your jobs, or (without job_id) your running job, queue and recently finished jobs.")
    async def job_status(job_id: int | None = None) -> str:
        b = await game.bridge()
        if job_id is not None:
            r = await b.job(job_id)
            return f"Job #{r.job_id} ({r.type}): {r.status}{' — ' + r.detail if r.detail else ''}"
        r = await game.call("list_tasks", {"limit": 10})
        lines = []
        a = r.get("active")
        lines.append(f"Running: job #{a['id']} ({a['type']}) for {a['running_s']}s." if a else "Running: nothing.")
        q = as_list(r.get("queued"))
        lines.append("Queued: " + ", ".join(f"#{j['id']} ({j['type']})" for j in q) + "." if q else "Queued: nothing.")
        for j in as_list(r.get("recent")):
            lines.append(f"#{j['id']} ({j['type']}) {j['status']} {j['ago_s']}s ago{' — ' + j['detail'] if j.get('detail') else ''}")
        return "\n".join(lines)

    @tool("Wait up to timeout_s for one of your jobs to finish.")
    async def job_wait(job_id: int, timeout_s: Annotated[float, Field(ge=0, le=3600)] = 60) -> str:
        b = await game.bridge()
        return describe(await b.wait_job(job_id, timeout_s), timeout_s)

    @tool("Cancel one of your jobs, or all of them (all=true), stopping your character.")
    async def job_cancel(job_id: int | None = None, all: bool = False) -> str:
        if job_id is None and not all:
            raise ValueError("give job_id, or all=true")
        r = await game.call("cancel", {"all": True} if all else {"task_id": job_id})
        if all:
            game.new_queue()
        return f"Cancelled {r['cancelled']} job(s)."
