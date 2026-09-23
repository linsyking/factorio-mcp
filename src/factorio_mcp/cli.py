"""factorio-mcp command line.

  factorio-mcp [serve]                 run the MCP server on stdio (default)
  factorio-mcp doctor                  check RCON + mod without binding a character
  factorio-mcp call TOOL [JSON] ...    run tool calls through a real MCP client session
  factorio-mcp tools                   list the tools the server exposes
  factorio-mcp retire --character C    remove character C from the game (test cleanup)
  factorio-mcp package-mod [--out D]   zip the mod as factorio-mcp_<version>.zip

Connection settings come from flags or environment variables:
  FACTORIO_RCON_HOST, FACTORIO_RCON_PORT, FACTORIO_RCON_PASSWORD,
  FACTORIO_CHARACTER (default "agent"), FACTORIO_TAKEOVER=1, FACTORIO_MCP_WAIT_S (default 0 = queue and return),
  FACTORIO_MCP_INBOX=0 (don't append unread chat to tool results).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import zipfile
from pathlib import Path

from .game import Config

ROOT = Path(__file__).resolve().parents[2]
MOD_DIR = ROOT / "mod" / "factorio-mcp"


def _env_bool(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


def config_from(args: argparse.Namespace) -> Config:
    return Config(
        host=args.host or os.environ.get("FACTORIO_RCON_HOST", "127.0.0.1"),
        port=int(args.port or os.environ.get("FACTORIO_RCON_PORT", 27015)),
        password=args.password or os.environ.get("FACTORIO_RCON_PASSWORD", ""),
        character=args.character or os.environ.get("FACTORIO_CHARACTER", "agent"),
        takeover=args.takeover or _env_bool("FACTORIO_TAKEOVER"),
        default_wait_s=float(os.environ.get("FACTORIO_MCP_WAIT_S", 0)),
        inbox=os.environ.get("FACTORIO_MCP_INBOX", "1").strip().lower() not in ("0", "false", "no", "off"),
        eager_bind=not _env_bool("FACTORIO_MCP_NO_BIND"),
    )


def _server_env(cfg: Config) -> dict[str, str]:
    env = dict(os.environ)
    env.update({
        "FACTORIO_RCON_HOST": cfg.host,
        "FACTORIO_RCON_PORT": str(cfg.port),
        "FACTORIO_RCON_PASSWORD": cfg.password,
        "FACTORIO_CHARACTER": cfg.character,
        "FACTORIO_TAKEOVER": "1" if cfg.takeover else "0",
        "FACTORIO_MCP_WAIT_S": str(cfg.default_wait_s),
        "FACTORIO_MCP_INBOX": "1" if cfg.inbox else "0",
        "FACTORIO_MCP_NO_BIND": "0" if cfg.eager_bind else "1",
    })
    return env


async def _client_session(cfg: Config):
    from mcp.client.session import ClientSession
    from mcp.client.stdio import StdioServerParameters, stdio_client

    params = StdioServerParameters(command=sys.executable, args=["-m", "factorio_mcp", "serve"], env=_server_env(cfg))
    return stdio_client(params), ClientSession


def _content_text(result) -> str:
    parts = []
    for c in result.content:
        parts.append(getattr(c, "text", None) or f"<{c.type}>")
    return "\n".join(parts)


async def _call(cfg: Config, calls: list[tuple[str, dict]]) -> int:
    transport, ClientSession = await _client_session(cfg)
    rc = 0
    async with transport as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            for i, (name, arguments) in enumerate(calls):
                result = await session.call_tool(name, arguments)
                flag = " [ERROR]" if result.is_error else ""
                text = _content_text(result)
                print(f"=== {name}{flag}\n{text}")
                if result.is_error:
                    rc = 1
                # Stop the batch at the first failure (a tool error, or a job
                # failure reported in the news footer): the rest was planned on
                # the assumption that everything before it worked.
                if (result.is_error or "job_failed]" in text) and i + 1 < len(calls):
                    rest = ", ".join(n for n, _ in calls[i + 1:])
                    print(f"=== stopped: {name} reported a failure, so the remaining call(s) were not run: {rest}")
                    rc = 1
                    break
    return rc


def _param_text(name: str, spec: dict, required: bool, defs: dict) -> str:
    """One parameter as 'name: type (constraints) = default — description'."""
    def type_of(sp: dict) -> str:
        if "$ref" in sp:
            ref = sp["$ref"].split("/")[-1]
            fields = ", ".join(defs.get(ref, {}).get("properties", {}).keys())
            return f"{{{fields}}}"
        if "anyOf" in sp:
            return " | ".join(type_of(x) for x in sp["anyOf"] if x.get("type") != "null") + ("?" if any(x.get("type") == "null" for x in sp["anyOf"]) else "")
        if "enum" in sp:
            return "|".join(map(str, sp["enum"]))
        if sp.get("type") == "array":
            return f"list[{type_of(sp.get('items', {}))}]"
        if sp.get("type") == "object" and "additionalProperties" in sp:
            return "dict[str, int]"
        return sp.get("type", "any")

    def limits(sp: dict) -> list[str]:
        out = []
        for key, sym in (("minimum", ">="), ("maximum", "<="), ("exclusiveMinimum", ">"), ("minItems", "min items "),
                         ("maxItems", "max items "), ("minLength", "min len "), ("maxLength", "max len ")):
            if key in sp:
                out.append(f"{sym}{sp[key]}")
        for x in sp.get("anyOf", []):
            out.extend(limits(x))
        return out

    text = f"{name}: {type_of(spec)}"
    lim = limits(spec)
    if lim:
        text += f" ({', '.join(lim)})"
    if required:
        text += " [required]"
    elif "default" in spec and spec["default"] is not None:
        text += f" = {spec['default']!r}"
    if spec.get("description"):
        text += f" — {spec['description']}"
    return text


async def _list_tools(cfg: Config) -> int:
    transport, ClientSession = await _client_session(cfg)
    async with transport as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            res = await session.list_tools()
            print(f"{len(res.tools)} tools\n")
            for t in res.tools:
                schema = t.input_schema or {}
                required = set(schema.get("required", []))
                params = [_param_text(n, spec, n in required, schema.get("$defs", {}))
                          for n, spec in schema.get("properties", {}).items()]
                print(f"- {t.name}: {t.description}")
                for line in params:
                    print(f"    {line}")
            if getattr(init, "instructions", None):
                print("\nInstructions:\n" + init.instructions)
    return 0


async def _doctor(cfg: Config) -> int:
    from .bridge import Bridge, ModError
    from .rcon import RconClient, RconError

    rcon = RconClient(cfg.host, cfg.port, cfg.password)
    try:
        await rcon.connect()
        print(f"RCON: connected to {cfg.host}:{cfg.port}")
        print("Game:", (await rcon.exec("/version")).strip())
        ping = await Bridge(rcon, cfg.character).unlock()
        print(f"Mod: factorio-mcp {ping.get('mod_version')} (protocol v{ping.get('protocol_version')}), "
              f"base {ping.get('factorio_version')}, space age: {ping.get('space_age')}, tick {ping.get('tick')}")
        chars = ping.get("characters") or []
        print("Bound characters: " + (", ".join(f"{c['name']} (idle {c['idle_s']}s)" for c in chars) or "none"))
        return 0
    except (RconError, ModError) as e:
        print(f"FAILED: {e}")
        return 1
    finally:
        rcon.close()


async def _retire(cfg: Config) -> int:
    from .bridge import Bridge, ModError
    from .rcon import RconClient

    rcon = RconClient(cfg.host, cfg.port, cfg.password)
    try:
        b = Bridge(rcon, cfg.character)
        await b.connect_and_bind(takeover=True)
        r = await b.call("retire")
        print(f"retired {r['retired']}")
        return 0
    except ModError as e:
        print(f"FAILED: {e}")
        return 1
    finally:
        rcon.close()


def package_mod(out: Path) -> Path:
    info = json.loads((MOD_DIR / "info.json").read_text())
    folder = f"{info['name']}_{info['version']}"
    out.mkdir(parents=True, exist_ok=True)
    target = out / f"{folder}.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(MOD_DIR.rglob("*")):
            if f.is_file():
                z.write(f, f"{folder}/{f.relative_to(MOD_DIR)}")
    return target


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="factorio-mcp", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", nargs="?", default="serve", choices=["serve", "doctor", "call", "tools", "retire", "package-mod"])
    p.add_argument("rest", nargs="*", help="for call: TOOL [JSON-ARGS] pairs")
    p.add_argument("--host")
    p.add_argument("--port", type=int)
    p.add_argument("--password")
    p.add_argument("--character")
    p.add_argument("--takeover", action="store_true")
    p.add_argument("--out", default=str(ROOT / "dist"))
    args = p.parse_args(argv)
    cfg = config_from(args)
    if args.command == "tools":
        cfg.eager_bind = False  # listing tools must never spawn a character

    if args.command == "serve":
        from .server import run
        run(cfg)
    elif args.command == "doctor":
        sys.exit(asyncio.run(_doctor(cfg)))
    elif args.command == "tools":
        sys.exit(asyncio.run(_list_tools(cfg)))
    elif args.command == "retire":
        sys.exit(asyncio.run(_retire(cfg)))
    elif args.command == "package-mod":
        print(package_mod(Path(args.out)))
    elif args.command == "call":
        calls, rest = [], list(args.rest)
        while rest:
            name = rest.pop(0)
            arguments = {}
            if rest and rest[0].lstrip().startswith("{"):
                arguments = json.loads(rest.pop(0))
            calls.append((name, arguments))
        if not calls:
            p.error("call needs at least one TOOL")
        sys.exit(asyncio.run(_call(cfg, calls)))
