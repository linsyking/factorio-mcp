"""Build checks: catch the three most common layout mistakes before the character builds.

Agents in the acceptance tests (research/factorio-agent/12, 13) repeatedly
- turned a belt corner the wrong way ("north" is smaller y), so the line
  stopped at a dead end next to the belt that should have continued it;
- placed inserters facing the wrong way (an inserter's direction is the side it
  picks up from), so they picked from the chest instead of the furnace;
- belted a mining drill on a tile its output never touches: a drill drops its
  ore on exactly ONE tile (the middle tile of its facing side, next to the
  footprint), and the game places a belt beside it without complaint.

check_plan() looks at a build_plan's steps together with what already stands
on the ground (layout_context RPC) and returns human-readable warnings, plus
one line per inserter saying what it picks from and drops into. It only
reports; it never changes the plan.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

UNIT = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}
NAME = {0: "north", 4: "east", 8: "south", 12: "west"}
BELT_TYPES = {"transport-belt", "underground-belt", "splitter"}
# what can stand on a drill's output tile and receive its ore
DRILL_RECEIVERS = BELT_TYPES | {"container", "logistic-container", "furnace", "assembling-machine",
                                "mining-drill", "loader", "loader-1x1"}
# at-points report entity names, not types: known non-receivers by name;
# anything unrecognized counts as a receiver so unknown machines never
# trigger false warnings
_NOT_RECEIVERS = ("inserter", "pipe", "pump", "pole", "wall", "turret", "radar", "lab", "roboport")


def drill_receives(name: str | None, kind: str | None = None) -> bool:
    """Whether the thing standing at a drill's output tile can receive its ore."""
    if kind:
        return kind in DRILL_RECEIVERS
    if not name or name in ("nothing", "unexplored"):
        return False
    n = name.lower()
    return not any(part in n for part in _NOT_RECEIVERS)


def snap(v: float, size: int) -> float:
    """Same alignment as the mod: odd sizes on tile centres, even on corners."""
    return math.floor(v) + 0.5 if size % 2 == 1 else math.floor(v + 0.5)


def rotate(off: tuple[float, float], direction: int) -> tuple[float, float]:
    """Rotate a north-facing offset to a 16-way direction (quarter turns only)."""
    x, y = off
    for _ in range((direction // 4) % 4):
        x, y = -y, x
    return x, y


def inserter_direction(ix: float, iy: float, drop_to: tuple[float, float] | None = None,
                       pickup_from: tuple[float, float] | None = None) -> int:
    """Direction for an inserter at (ix, iy) so that it drops toward drop_to
    (or picks up from pickup_from). An inserter's direction is the side it
    picks up from: facing north (0) it picks from the north and drops south."""
    if drop_to is not None:
        vx, vy = ix - drop_to[0], iy - drop_to[1]  # toward the pickup side
    elif pickup_from is not None:
        vx, vy = pickup_from[0] - ix, pickup_from[1] - iy
    else:
        raise ValueError("give drop_to or pickup_from")
    if abs(vx) < 0.3 and abs(vy) < 0.3:
        raise ValueError("drop_to / pickup_from must be a neighbouring tile, not the inserter's own tile")
    if abs(vx) >= abs(vy):
        return 4 if vx > 0 else 12
    return 8 if vy > 0 else 0


def tile(x: float, y: float) -> tuple[int, int]:
    return math.floor(x), math.floor(y)


@dataclass
class Placed:
    item: str
    kind: str  # entity type, e.g. "transport-belt", "inserter", "furnace"
    x: float
    y: float
    direction: int
    w: int
    h: int
    entity: dict[str, Any]

    def covers(self, px: float, py: float) -> bool:
        return (self.x - self.w / 2 <= px < self.x + self.w / 2) and (self.y - self.h / 2 <= py < self.y + self.h / 2)


def planned(steps: list[dict[str, Any]], protos: dict[str, Any]) -> list[Placed]:
    out: list[Placed] = []
    for s in steps:
        ent = (protos.get(s["item"].split("@")[0]) or {}).get("entity") or {}
        w, h = int(ent.get("tile_width") or 1), int(ent.get("tile_height") or 1)
        d = int(s.get("direction") or 0) % 16
        if d in (4, 12):
            w, h = h, w
        out.append(Placed(s["item"], str(ent.get("type") or ""), snap(s["x"], w), snap(s["y"], h), d, w, h, ent))
    return out


def context_request(plan: list[Placed]) -> tuple[list[float], list[dict[str, float]]]:
    """The area and points check_plan needs from the game (layout_context).
    Inserter points come first, drill output points after — check_plan reads
    the at-answers in exactly this order."""
    xs = [p.x for p in plan] or [0.0]
    ys = [p.y for p in plan] or [0.0]
    area = [min(xs) - 3, min(ys) - 3, max(xs) + 3, max(ys) + 3]
    points: list[dict[str, float]] = []
    for p in plan:
        if p.kind == "inserter":
            for key in ("inserter_pickup_offset", "inserter_drop_offset"):
                off = p.entity.get(key)
                if off:
                    ox, oy = rotate((off["x"], off["y"]), p.direction)
                    points.append({"x": p.x + ox, "y": p.y + oy})
    for p in plan:
        if p.kind == "mining-drill":
            off = p.entity.get("drop_offset")
            if off:
                ox, oy = rotate((off["x"], off["y"]), p.direction)
                points.append({"x": p.x + ox, "y": p.y + oy})
    return area, points


def check_plan(plan: list[Placed], ctx: dict[str, Any]) -> tuple[list[str], list[str]]:
    """Returns (warnings, inserter_lines)."""
    warnings: list[str] = []
    belts: dict[tuple[int, int], int] = {}
    new_belts: dict[tuple[int, int], int] = {}
    for b in ctx.get("belts") or []:
        if b.get("type") == "transport-belt":
            belts[tile(b["x"], b["y"])] = int(b.get("direction") or 0)
    for p in plan:
        if p.kind == "transport-belt":
            belts[tile(p.x, p.y)] = p.direction
            new_belts[tile(p.x, p.y)] = p.direction

    def feeders(t: tuple[int, int]) -> list[tuple[int, int]]:
        """Belt tiles that output into t."""
        return [n for n, d in belts.items() if (n[0] + UNIT[d][0], n[1] + UNIT[d][1]) == t]

    for t, d in sorted(new_belts.items()):
        if d not in UNIT:
            continue
        nx, ny = t[0] + UNIT[d][0], t[1] + UNIT[d][1]
        here = f"belt at ({t[0] + 0.5}, {t[1] + 0.5}) facing {NAME[d]}"
        nd = belts.get((nx, ny))
        if nd is not None and nd == (d + 8) % 16:
            warnings.append(f"{here} and the belt in front of it face each other: items stop there")
            continue
        if nd is not None:
            continue
        # Dead end. Suspicious when a belt line with no input starts right
        # beside it: the corner was probably meant to turn into that line.
        for side in (0, 4, 8, 12):
            if side == d:
                continue
            s_t = (t[0] + UNIT[side][0], t[1] + UNIT[side][1])
            sd = belts.get(s_t)
            if sd is None or s_t in feeders(t):
                continue  # nothing there, or it's what feeds this belt
            if sd == (side + 8) % 16 or feeders(s_t):
                continue  # it points back at us, or already has an input
            warnings.append(f"{here} ends in an empty tile, but the belt line at ({s_t[0] + 0.5}, {s_t[1] + 0.5}) "
                            f"starts right beside it with no input: this corner should probably face {NAME[side]} "
                            f"(direction {side}). A corner belt faces the direction items leave, and y grows "
                            f"south (north = smaller y)")
            break

    lines: list[str] = []
    names = iter(ctx.get("at") or [])
    for p in plan:
        if p.kind != "inserter":
            continue
        ends = {}
        for key in ("inserter_pickup_offset", "inserter_drop_offset"):
            off = p.entity.get(key)
            if not off:
                continue
            ox, oy = rotate((off["x"], off["y"]), p.direction)
            px, py = p.x + ox, p.y + oy
            q = next((q for q in plan if q is not p and q.covers(px, py)), None)
            existing = next(names, "nothing")
            ends[key] = (q.item if q else existing, px, py, q)
        if len(ends) < 2:
            continue
        (src, sx, sy, src_new), (dst, dx, dy, _) = ends["inserter_pickup_offset"], ends["inserter_drop_offset"]
        lines.append(f"{p.item} at ({p.x}, {p.y}) facing {NAME.get(p.direction, p.direction)}: picks from {src} "
                     f"at ({sx:.1f}, {sy:.1f}) -> drops into {dst} at ({dx:.1f}, {dy:.1f})")
        if src in ("nothing", "unexplored") and dst not in ("nothing", "unexplored"):
            warnings.append(f"{p.item} at ({p.x}, {p.y}) picks up from an empty tile and drops into {dst}: "
                            f"probably facing the wrong way (direction = the side it picks up from)")
        elif src_new is not None and src_new.kind == "container":
            warnings.append(f"{p.item} at ({p.x}, {p.y}) picks up from the {src} placed in this same plan (empty "
                            f"for now) and drops into {dst} — fine if you'll fill that {src}; otherwise it faces the "
                            f"wrong way (direction = the side it picks up from)")
        elif dst in ("nothing", "unexplored"):
            warnings.append(f"{p.item} at ({p.x}, {p.y}) drops onto an empty tile (picks from {src})")

    # Mining drills: each drops its ore on ONE tile — the middle tile of its
    # facing side, next to the footprint. The game places a belt beside a
    # drill without complaint, and it collects nothing.
    for p in plan:
        if p.kind != "mining-drill":
            continue
        off = p.entity.get("drop_offset")
        if not off:
            continue
        ox, oy = rotate((off["x"], off["y"]), p.direction)
        px, py = p.x + ox, p.y + oy
        tx, ty = math.floor(px) + 0.5, math.floor(py) + 0.5  # the tile a receiver must stand on
        q = next((q for q in plan if q is not p and q.covers(px, py)), None)
        if q is not None:
            if q.kind not in DRILL_RECEIVERS:
                warnings.append(f"{p.item} at ({p.x:g}, {p.y:g}) outputs onto ({tx:g}, {ty:g}), but this plan "
                                f"places a {q.item} there: a drill can only load a belt, chest or machine on that "
                                f"tile.")
            continue
        existing = next(names, "nothing")  # the drill points, after the inserter points
        if existing == "nothing":
            warnings.append(f"{p.item} at ({p.x:g}, {p.y:g}) facing {NAME.get(p.direction, p.direction)} outputs "
                            f"onto ({tx:g}, {ty:g}), and neither this plan nor the ground puts anything there: its "
                            f"ore has nowhere to go. A drill loads exactly that ONE tile — a belt beside the drill "
                            f"collects nothing; put a belt, chest or furnace on it, or turn the drill so its facing "
                            f"side points at a receiver.")
        elif existing == "unexplored":
            warnings.append(f"{p.item} at ({p.x:g}, {p.y:g}) outputs onto unexplored ground at ({tx:g}, {ty:g}) — "
                            f"scan that tile to see whether anything receives the ore.")
        elif not drill_receives(existing):
            warnings.append(f"{p.item} at ({p.x:g}, {p.y:g}) outputs onto ({tx:g}, {ty:g}) where the {existing} "
                            f"stands: a drill can only load a belt, chest or machine on that tile.")

    # Existing drills near the plan, from layout_context.
    for d in ctx.get("drills") or []:
        if d.get("status") == "no_minable_resources":
            continue  # dead drill: nothing comes out (map_warnings flags it)
        drop = d.get("drop") or {}
        px, py = float(drop.get("x") or 0), float(drop.get("y") or 0)
        tx, ty = math.floor(px) + 0.5, math.floor(py) + 0.5
        here = f"the {d['name']} at ({d['x']:g}, {d['y']:g}) facing {NAME.get(d.get('direction') or 0, '?')}"
        covered = next((q for q in plan if q.covers(px, py)), None)
        if covered is not None:
            if covered.kind not in DRILL_RECEIVERS:
                warnings.append(f"{here} outputs onto ({tx:g}, {ty:g}), but this plan places a {covered.item} "
                                f"there: a drill can only load a belt, chest or machine on that tile.")
            continue  # the plan already puts something on the output tile
        into, itype = d.get("drop_into"), d.get("drop_into_type")
        if into == "unexplored":
            continue
        if not drill_receives(into, itype):
            why = ("nothing stands there — its ore has nowhere to go" if into in (None, "nothing")
                   else f"the {into} there cannot receive it")
            warnings.append(f"{here} outputs onto ({tx:g}, {ty:g}), but {why}. A drill loads exactly one tile "
                            f"(the middle tile of its facing side); put a belt, chest or furnace there.")
    return warnings, lines
