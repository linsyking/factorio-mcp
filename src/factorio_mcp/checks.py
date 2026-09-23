"""Build checks: catch the two most common layout mistakes before the character builds.

Agents in the acceptance tests (research/factorio-agent/12, 13) repeatedly
- turned a belt corner the wrong way ("north" is smaller y), so the line
  stopped at a dead end next to the belt that should have continued it;
- placed inserters facing the wrong way (an inserter's direction is the side it
  picks up from), so they picked from the chest instead of the furnace.

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
    """The area and points check_plan needs from the game (layout_context)."""
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
            warnings.append(f"{p.item} at ({p.x}, {p.y}) picks up from the {src} placed in this same plan, which "
                            f"starts empty, and drops into {dst}: probably facing the wrong way "
                            f"(direction = the side it picks up from)")
        elif dst in ("nothing", "unexplored"):
            warnings.append(f"{p.item} at ({p.x}, {p.y}) drops onto an empty tile (picks from {src})")
    return warnings, lines
