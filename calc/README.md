# factorio-calc-mcp

A separate MCP server for **Factorio 2.0 production math**. It wraps the [FactorioCalc](https://github.com/FactorioCalc/FactorioCalc) LP solver and runs alongside `factorio-mcp`: agents plan with this one and act with that one.
- **No game connection and no character.** It is pure computation.
- **AGPL-3.0-or-later**, because it links FactorioCalc (AGPL). `factorio-mcp` itself stays MIT; the two only talk through the agent, never import each other.

| Tool | What it answers |
|---|---|
| `solve_production` | Machines per recipe, exact and rounded up, for target items per minute. Also gives raw inputs, electricity and byproduct handling (oil cracking cycles are solved exactly). Options: preferred machines, a preset (`early`, `early-mid`, `late`, `legendary`), forced recipes, raw inputs, and `game` = `base` or `space-age` |
| `mining_drills` | Drills needed for a resource rate, from vanilla drill speeds, with an optional mining-productivity bonus |
| `machines_per_belt` | One machine's flows, and how many machines fill or drain one belt of each tier |
| `belts_needed` | Belts of each tier needed for a rate |
| `recipe_info` | Ingredients, products, time and category |

**Space Age:** recycling, asteroid-crushing, synthesis, quality-variant and barrel recipes are never picked automatically. Ores, water, crude oil and the Space Age raw resources count as raw inputs unless you pass `raw_inputs`. Automatic recipe choices are listed as notes.

**Not modelled:** mining drills inside the solver (use `mining_drills`), resource depletion, and belt or inserter layout.

```bash
cd calc && uv sync
uv run factorio-calc-mcp                  # stdio MCP server
uv run pytest                             # pinned to verified numbers (48 furnaces/belt, 0.5/0.75 circuits, oil LP)
```

Claude Code `.mcp.json`:

```json
{ "mcpServers": { "factorio-calc": { "command": "uv", "args": ["run", "--directory", "/path/to/factorio-mcp/calc", "factorio-calc-mcp"] } } }
```
