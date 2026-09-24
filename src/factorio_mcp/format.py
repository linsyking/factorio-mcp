"""Plain-text formatting of game data for the model (ported from Agentic-Factorio's
TypeScript formatters). Compact, token-friendly, no advice."""

from __future__ import annotations

from typing import Any

from .bridge import as_list

DIR_NAMES = {0: "north", 2: "northeast", 4: "east", 6: "southeast", 8: "south", 10: "southwest", 12: "west", 14: "northwest"}


def num(n: float | int) -> str:
    if isinstance(n, float) and not n.is_integer():
        return f"{n:,.2f}"
    return f"{int(n):,}"


def items_text(d: dict[str, Any] | None) -> str:
    entries = list((d or {}).items())
    return ", ".join(f"{n} x{q}" for n, q in entries)


def dir_name(d: int) -> str:
    return DIR_NAMES.get(d, f"direction {d}")


def state(s: dict[str, Any]) -> str:
    lines: list[str] = []
    c = s.get("companion")
    if c:
        pos = c["position"]
        veh = f", driving a {c['vehicle']}" if c.get("vehicle") else ""
        lines.append(f"You are {c.get('name')} at ({pos['x']}, {pos['y']}), health {c.get('health')}{veh}.")
        inv = c.get("inventory") or {}
        lines.append(f"Inventory: {items_text(inv)}." if inv else "Inventory: empty.")
        eq = c.get("equipment")
        if eq:
            ammo = items_text(eq.get("ammo")) or "none"
            lines.append(f"Equipment: gun {eq.get('gun') or 'none'}; ammo {ammo}; armor {eq.get('armor') or 'none'}.")
        at = c.get("active_task")
        ql = c.get("queue_length") or 0
        if at:
            lines.append(f"Running job #{at['id']} ({at['type']}){f', {ql} queued' if ql else ''}.")
        elif ql:
            lines.append(f"{ql} job(s) queued.")
        else:
            lines.append("No jobs running.")
    others = as_list(s.get("other_characters"))
    if others:
        lines.append("Other agent characters: " + "; ".join(
            f"{o['name']} at ({o['position']['x']}, {o['position']['y']}), {o['distance']} tiles away" for o in others) + ".")
    players = as_list(s.get("players"))
    if players:
        lines.append("Players: " + "; ".join(
            f"{p['name']} at ({p['position']['x']}, {p['position']['y']}), {p['distance']} tiles away" for p in players) + ".")
    patches = as_list(s.get("resource_patches"))
    lines.append(
        "Resource patches (explored ground): " + "; ".join(
            f"{p['name']} {num(p['total_amount'])} in {p['entity_count']} tiles, center ({p['center']['x']}, {p['center']['y']}), "
            f"{round(p['distance'])} tiles away" for p in patches) + "."
        if patches else "No resource patches on explored ground in range.")
    lines.append(f"Trees in range: {s.get('trees_nearby', 0)}.")
    structures = as_list(s.get("structures"))
    if structures:
        parts = []
        for g in structures:
            st = g.get("status")
            status = (" — " + ", ".join(f"{n} {k.replace('_', ' ')}" for k, n in st.items())) if st else ""
            parts.append(f"{g['name']} x{g['count']} (nearest ({g['nearest']['x']}, {g['nearest']['y']}){status})")
        lines.append("Your force's buildings: " + "; ".join(parts) + ".")
    e = s.get("enemies")
    if e:
        if e.get("nearest_distance") is None and not e.get("spawners"):
            lines.append("No enemies in view.")
        else:
            bits = []
            if e.get("nearest_distance") is not None:
                bits.append(f"nearest {round(e['nearest_distance'])} tiles away")
            bits.append(f"{e.get('spawners', 0)} spawner(s) in view")
            lines.append("Enemies: " + ", ".join(bits) + ".")
    r = s.get("research")
    if r:
        lines.append(f"Researching {r['current']} ({round(r['progress'] * 100)}%).")
    p = s.get("power")
    if p:
        bits = []
        if p.get("production_kw") is not None:
            bits.append(f"producing {num(p['production_kw'])} kW, using {num(p.get('consumption_kw', 0))} kW")
        if p.get("capacity_kw"):
            cap = p["capacity_kw"]
            used = round(100 * (p.get("production_kw") or 0) / cap) if cap else 0
            bits.append(f"capacity {num(cap)} kW from {p.get('generators')} generator(s) — {used}% in use "
                        f"(production follows demand; headroom is capacity minus production)")
        top = p.get("top_consumers_kw") or {}
        if top:
            bits.append("top consumers: " + ", ".join(f"{n} {num(kw)} kW" for n, kw in top.items()))
        if p.get("starving_machines"):
            bits.append(f"{p['starving_machines']} machine(s) short of power")
        lines.append(f"Power ({p['networks']} network(s)): " + ("; ".join(bits) or "no flow data") + ".")
    prod = s.get("production_top") or {}
    if prod:
        lines.append("Top production (last minute): " + "; ".join(
            f"{n} {num(v['produced_per_min'])}/min made, {num(v['consumed_per_min'])}/min used" for n, v in prod.items()) + ".")
    if s.get("explored_chunks") is not None:
        lines.append(f"Explored chunks: {s['explored_chunks']}.")
    return "\n".join(lines)


def inspect(e: dict[str, Any]) -> str:
    parts = []
    facing = f", facing {dir_name(e['direction'])}" if e.get("direction") is not None else ""
    parts.append(f"{e['name']} ({e.get('type')}) at ({e['position']['x']}, {e['position']['y']}){facing}.")
    if e.get("note"):
        parts.append(f"NOTE: {e['note']}.")
    if e.get("health") is not None:
        parts.append(f"Health {e['health']}.")
    if e.get("status"):
        parts.append(f"Status: {e['status'].replace('_', ' ')}.")
    if e.get("recipe"):
        prog = f" ({round(e['crafting_progress'] * 100)}% done)" if e.get("crafting_progress") is not None else ""
        parts.append(f"Recipe: {e['recipe']}{prog}.")
    if e.get("burning"):
        parts.append(f"Burning {e['burning']} ({num(e.get('remaining_burning_kj', 0))} kJ left in it).")
    if e.get("energy_kj"):
        parts.append(f"Energy buffer: {num(e['energy_kj'])} kJ.")
    if e.get("amount") is not None:
        parts.append(f"Resource amount left: {num(e['amount'])}.")
    if e.get("ore_remaining") is not None:
        target = f" (mining {e['mining_target']})" if e.get("mining_target") else ""
        parts.append(f"Ore left in its mining area: {num(e['ore_remaining'])} in {e.get('ore_tiles', 0)} tiles{target}.")
    if "belt_contents" in e or "belt_lanes" in e:
        bc = e.get("belt_contents") or {}
        lanes = e.get("belt_lanes")
        d = e.get("belt_direction")
        # left/right of the direction of travel, and which compass side that is
        sides = {0: ("west", "east"), 4: ("north", "south"), 8: ("east", "west"), 12: ("south", "north")}
        if "belt_feeds" in e or "belt_fed_by" in e:
            f = e.get("belt_feeds")
            ins = as_list(e.get("belt_fed_by"))
            parts.append(("Feeds " + (f"the belt at ({f['x']}, {f['y']})" if f else "nothing (a dead end: items stop here)"))
                         + "; fed by " + (", ".join(f"({i['x']}, {i['y']})" for i in ins) if ins else "no belt") + ".")
        if e.get("underground"):
            parts.append(f"Underground {e['underground']}.")
        if isinstance(lanes, dict):
            ls, rs = sides.get(d, ("", ""))
            moving = {0: "north", 4: "east", 8: "south", 12: "west"}.get(d)
            left = items_text(lanes.get("left") or {}) or "empty"
            right = items_text(lanes.get("right") or {}) or "empty"
            parts.append(f"On the belt{f' (moving {moving})' if moving else ''}: left lane"
                         f"{f' ({ls} side)' if ls else ''}: {left}; right lane{f' ({rs} side)' if rs else ''}: {right}.")
        else:
            parts.append(f"On the belt: {items_text(bc)}." if bc else "Nothing on the belt.")
    if e.get("fluid_connections"):
        fc = []
        for c in as_list(e["fluid_connections"]):
            where = f"({c['pipe_at']['x']}, {c['pipe_at']['y']})"
            state = f"connected to {c['connected_to']}" if c.get("connected_to") else "NOT connected"
            fc.append(f"box {c['fluidbox']} {c.get('flow')}{' underground' if c.get('type') == 'underground' else ''} "
                      f"at {where}: {state}")
        parts.append("Fluid connections: " + "; ".join(fc) + ".")
    if e.get("fluids"):
        parts.append("Fluids: " + ", ".join(f"{n} {num(q)}" for n, q in e["fluids"].items()) + ".")
    if e.get("no_fluids"):
        parts.append("Fluid system: empty.")
    for inv_name, contents in (e.get("inventories") or {}).items():
        parts.append(f"{inv_name} inventory: {items_text(contents) or 'empty'}.")
    return " ".join(parts)


def scan(r: dict[str, Any]) -> str:
    o = r["origin"]
    k = int(r.get("scale") or 1)
    rows = as_list(r.get("grid"))
    # Every row is labelled with its map y and a ruler marks x every 10 tiles:
    # repetitive layouts (mall rows, belt rows) are easy to misread by whole
    # rows in an unlabelled grid.
    ys = [o["y"] + i * k for i in range(len(rows))]
    width = max(len(str(y)) for y in ys) if ys else 1
    cols = len(rows[0]) if rows else 0
    xs = [o["x"] + c * k for c in range(cols)]
    def mark(x: int) -> int | None:  # the multiple of 10 inside this cell, if any
        m = -(-x // 10) * 10
        return m if m < x + k else None
    ticks = "".join("|" if mark(x) is not None else " " for x in xs)
    marked = [mark(x) for x in xs if mark(x) is not None]
    where = ("one character per tile" if k == 1 else
             f"each character covers {k}x{k} tiles (its top-left tile is the x/y shown) and shows the most important "
             f"thing in them")
    lines = [
        f"Scanned {r['width']}x{r['height']} tiles from map ({o['x']}, {o['y']}) (top-left), {where}. "
        f"Each row starts with its map y; columns run east from x = {o['x']}. "
        f"The ruler marks every 10th x" + (f" (first mark: x = {marked[0]})" if marked else "") + ". Rows run north to south.",
        "```",
        " " * (width + 1) + ticks,
        *[f"{str(y).rjust(width)} {row}" for y, row in zip(ys, rows)],
        "```",
        "Legend:",
        *[f"{k_} = {v}" for k_, v in (r.get("legend") or {}).items()],
    ]
    ins = as_list(r.get("inserters"))
    if ins:
        lines.append("Your inserters (they pick up on one side and drop on the other):")
        for i in ins:
            pk, dp = i["pickup"], i["drop"]
            lines.append(f"  {i['name']} at ({i['position']['x']:g}, {i['position']['y']:g}): picks from "
                         f"{i['pickup_from']} at ({pk['x']:.1f}, {pk['y']:.1f}) -> drops into {i['drop_into']} "
                         f"at ({dp['x']:.1f}, {dp['y']:.1f})")
    if r.get("note"):
        lines.append(r["note"])
    return "\n".join(lines)


def _offset(o: dict[str, Any]) -> str:
    return f"({o['x']}, {o['y']})"


def _recipe_text(r: dict[str, Any]) -> str:
    def f(d: Any) -> str:
        return " + ".join(f"{q}x {n}" for n, q in (d or {}).items()) or "nothing"
    bits = [f"recipe {f(r.get('ingredients'))} -> {f(r.get('products'))}"]
    if isinstance(r.get("energy"), (int, float)):
        bits.append(f"{r['energy']}s craft time")
    if r.get("category"):
        bits.append(f"category {r['category']}")
    bits.append("unlocked" if r.get("enabled") else "not unlocked yet")
    return ", ".join(bits)


def _entity_text(name: str, p: dict[str, Any]) -> str:
    bits = [f"{p.get('type', 'entity')} {p.get('entity', name)} {p.get('tile_width', '?')}x{p.get('tile_height', '?')}"]
    if p.get("energy") == "burner":
        bits.append(f"burner ({'/'.join(as_list(p.get('fuel_categories'))) or 'chemical'} fuel)")
    elif p.get("energy") and p.get("energy") != "none":
        bits.append(f"{p['energy']} powered")
    if p.get("power_kw"):
        bits.append(f"uses {num(p['power_kw'])} kW")
    if p.get("power_output_kw"):
        bits.append(f"produces up to {num(p['power_output_kw'])} kW")
    if p.get("crafting_speed"):
        bits.append(f"crafting speed {num(p['crafting_speed'])}")
    crafts = as_list(p.get("crafting_categories"))
    if crafts:
        bits.append("crafts categories: " + ", ".join(crafts))
    if p.get("mining_speed") is not None:
        bits.append(f"mining speed {p['mining_speed']}")
    if p.get("mining_area"):
        bits.append(f"mining area {num(p['mining_area'])}x{num(p['mining_area'])} tiles")
    if p.get("resource_categories"):
        bits.append("mines: " + ", ".join(as_list(p["resource_categories"])))
    if p.get("drop_offset"):
        bits.append(f"drops output at offset {_offset(p['drop_offset'])} when facing north (rotates with direction)")
    fc = p.get("fluid_connections")
    if fc:
        parts_fc = []
        for c in as_list(fc):
            what = c.get("filter") or ("fluid" if c.get("role") in (None, "none") else c.get("role"))
            parts_fc.append(f"{c.get('side')} side pipe at {_offset(c['pipe_at'])} ({c.get('flow')}"
                            f"{', underground' if c.get('type') == 'underground' else ''}; box {c['fluidbox']} {what})")
        bits.append("fluid connections when facing north (rotate with direction): " + "; ".join(parts_fc))
    if p.get("inserter_pickup_offset") and p.get("inserter_drop_offset"):
        bits.append(f"picks up at {_offset(p['inserter_pickup_offset'])}, drops at {_offset(p['inserter_drop_offset'])} "
                    "when facing north (rotate with direction)")
    if p.get("inserter_rotation_speed"):
        bits.append(f"rotation speed {num(p['inserter_rotation_speed'])} turns/tick")
    if p.get("module_slots"):
        bits.append(f"{p['module_slots']} module slot(s)")
    if p.get("inventory_slots"):
        bits.append(f"{p['inventory_slots']} inventory slots")
    if p.get("belt_speed") is not None:
        bits.append(f"belt speed {p['belt_speed']} tiles/tick ({num(round(p['belt_speed'] * 480, 2))} items/s)")
    if p.get("range") is not None:
        bits.append(f"range {p['range']}")
    return ", ".join(bits)


def prototype(name: str, p: dict[str, Any]) -> str:
    """All views of a name: item, entity it places, recipe that makes it, fluid."""
    if p.get("unknown") or not p:
        return f"{name}: unknown — no item, entity, recipe or fluid by this name"
    parts = []
    it = p.get("item")
    if it:
        bits = [f"stack size {it.get('stack_size')}"]
        if it.get("fuel_value_mj"):
            bits.append(f"fuel value {num(it['fuel_value_mj'])} MJ ({it.get('fuel_category', 'chemical')})")
        parts.append("item: " + ", ".join(bits))
    if p.get("entity"):
        parts.append(_entity_text(name, p["entity"]))
    if p.get("recipe"):
        parts.append(_recipe_text(p["recipe"]))
    if p.get("fluid"):
        parts.append("fluid")
    return f"{name}: " + "; ".join(parts)


def blueprint(bp: dict[str, Any]) -> str:
    ents = as_list(bp.get("entities"))
    total = bp.get("total_entities", len(ents))
    offset = bp.get("offset", 0)
    window = f" Showing entities {offset + 1}–{offset + len(ents)} of {total}." if total > len(ents) else ""
    label = f' "{bp["label"]}"' if bp.get("label") else ""
    lines = [
        f"Blueprint{label}: {total} entities, {bp['size']['w']}x{bp['size']['h']} tiles. "
        f"Positions are relative to the top-left entity.{window}",
    ]
    for e in ents:
        extra = (f" dir {e['direction']}" if e.get("direction") else "") + (f" recipe {e['recipe']}" if e.get("recipe") else "")
        q = f"@{e['quality']}" if e.get("quality") and e.get("quality") != "normal" else ""
        lines.append(f"  {e['name']}{q} at +({e['position']['x']}, {e['position']['y']}){extra}")
    if bp.get("next_offset") is not None:
        lines.append(f"… more entities follow: read again with offset={bp['next_offset']}.")
    lines.append(f"Items needed (whole print): {items_text(bp.get('items_needed')) or 'none'}.")
    skipped = as_list(bp.get("skipped"))
    if skipped:
        lines.append("Skipped (unknown here): " + ", ".join(skipped) + ".")
    tiles = bp.get("tiles")
    if tiles:
        lines.append(f"Also {tiles['count']} floor tiles ({', '.join(as_list(tiles.get('kinds')))}); no tool places tiles.")
    return "\n".join(lines)


def overview(r: dict[str, Any]) -> str:
    groups = as_list(r.get("groups"))
    you = r.get("you") or {}
    lines = [f"Map overview within {r.get('radius')} tiles of ({r['center']['x']:.0f}, {r['center']['y']:.0f}): "
             f"{r.get('known_chunks')} of {r.get('total_chunks')} chunks known (32x32 tiles each; the rest is unexplored). "
             f"You are at ({you.get('x', 0):.0f}, {you.get('y', 0):.0f}). Nearest first:"]
    unit = {"rocks": "rocks", "trees": "trees", "water": "water tiles", "enemy base": "spawners/worms"}
    # rocks and trees come in many small groups: list the nearest few, sum the rest
    shown: dict[str, int] = {}
    skipped: dict[str, list[int]] = {}
    keep = []
    for g in groups:
        k = g["kind"]
        if k in ("rocks", "trees") and shown.get(k, 0) >= 4:
            skipped.setdefault(k, []).append(g["count"])
            continue
        shown[k] = shown.get(k, 0) + 1
        keep.append(g)
    groups_all, groups = groups, keep
    for g in groups:
        a, at = g["area"], g["at"]
        what = unit.get(g["kind"], "tiles")
        lines.append(f"  {g['kind']}: {g['count']} {what} over {g['chunks']} chunk(s), centre ({g['center']['x']}, "
                     f"{g['center']['y']}), area x {a['x1']}..{a['x2']}, y {a['y1']}..{a['y2']}, {g['distance']} tiles away"
                     + ("" if g["kind"] in unit else f"; a tile of it at ({at['x']}, {at['y']})"))
    for k, counts in skipped.items():
        lines.append(f"  (+{len(counts)} farther {k} groups, {sum(counts)} {k} in all)")
    if r.get("more"):
        lines.append(f"  … and {r['more']} more farther away (lower the radius or move the centre).")
    if not groups_all:
        lines.append("  nothing known here yet.")
    return "\n".join(lines)


def belt_trace(r: dict[str, Any]) -> str:
    def items(d: dict[str, Any]) -> str:
        return ", ".join(f"{n} x{k}" for n, k in sorted(d.items())) if d else "empty"
    lines = [f"Belt line through ({r['start']['x']}, {r['start']['y']}): {r['tiles']} tiles, in the direction items move.",
             f"Begins: {r['begins']}."]
    for leg in as_list(r.get("legs")):
        kind = f" [{leg['kind']}{': ' + leg['note'] if leg.get('note') else ''}]" if leg.get("kind") else ""
        span = (f"({leg['from']['x']}, {leg['from']['y']})" if leg["tiles"] == 1 else
                f"({leg['from']['x']}, {leg['from']['y']}) → ({leg['to']['x']}, {leg['to']['y']})")
        lines.append(f"  {span}{kind}: moving {leg['moving']}, {leg['tiles']} tile(s); "
                     f"left lane ({leg['left_side']} side) {items(leg.get('left') or {})} [{leg['fill_left']}% full], "
                     f"right lane ({leg['right_side']} side) {items(leg.get('right') or {})} [{leg['fill_right']}% full]")
    lines.append(f"Ends: {r['ends']}.")
    fed, taken = as_list(r.get("fed_by")), as_list(r.get("taken_by"))
    lines.append("Fed by: " + ("; ".join(fed) if fed else "nothing (no inserter, drill or side-load drops onto it)") + ".")
    lines.append("Taken by: " + ("; ".join(taken) if taken else "no inserter picks from it") + ".")
    lines.append(f"Capacity: {r.get('lane_capacity_per_min')}/min per lane. A full lane holds 4 items per tile; "
                 "a full but unmoving line is backed up (measure_belt tells flowing from stuck).")
    return "\n".join(lines)
