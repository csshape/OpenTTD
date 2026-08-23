#!/usr/bin/env python3
"""
MCP server for playing OpenTTD through the in-game MCPAgent script.

The game and this server talk through three files in OpenTTD's personal
directory, under "mcp/":

    commands.jsonl   orders written here, one per line, consumed by the agent
    state.json       the agent's view of the world, refreshed every round
    results.jsonl    one line per finished order

Speaks MCP over stdio with no third-party dependencies, so it runs with a
plain Python 3 interpreter.
"""

import json
import os
import sys
import time
from pathlib import Path

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "openttd", "version": "1.0.0"}


def channel_dir() -> Path:
    """Where the game keeps the channel files."""
    override = os.environ.get("OPENTTD_MCP_DIR")
    if override:
        return Path(override).expanduser()
    # Matches PERSONAL_DIR on macOS in this fork; Documents/OpenTTD upstream.
    for candidate in (Path.home() / "OpenTTD" / "mcp",
                      Path.home() / "Documents" / "OpenTTD" / "mcp"):
        if candidate.exists():
            return candidate
    return Path.home() / "OpenTTD" / "mcp"


def next_order_id() -> str:
    """Monotonic-ish id so results can be matched to orders."""
    return f"o{int(time.time() * 1000) % 100000000}"


def queue_order(*fields) -> str:
    """Append one pipe-separated order and return its id."""
    order_id = next_order_id()
    d = channel_dir()
    d.mkdir(parents=True, exist_ok=True)
    line = "|".join([order_id] + [str(f) for f in fields])
    with (d / "commands.jsonl").open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    return order_id


def read_state() -> dict:
    path = channel_dir() / "state.json"
    if not path.exists():
        return {"error": "No state published yet. Is the game running with the "
                         "MCPAgent script added as a competitor?"}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        # The agent may have been mid-write; that is normal, not an error.
        return {"error": "State file was being written; try again."}


def read_results(limit: int = 20) -> list:
    path = channel_dir() / "results.jsonl"
    if not path.exists():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            out.append({"raw": line})
    return out[-limit:]


TOOLS = [
    {
        "name": "get_state",
        "description": (
            "Current view of the game: money, loan, year, the largest towns "
            "with ids and coordinates, industries, and our own routes with "
            "vehicle counts, profit and waiting cargo. Read this before "
            "deciding anything."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_results",
        "description": "Outcomes of recently issued orders, oldest first.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer", "description": "How many to return (default 20)"}},
        },
    },
    {
        "name": "build_bus_route",
        "description": (
            "Open a passenger route between two towns: a drive-through bus stop "
            "in each, road between them, a depot, and three buses. Use town ids "
            "from get_state. Works best when the towns are 15-80 tiles apart."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "town_a": {"type": "integer", "description": "Town id from get_state"},
                "town_b": {"type": "integer", "description": "Town id from get_state"},
            },
            "required": ["town_a", "town_b"],
        },
    },
    {
        "name": "build_truck_route",
        "description": (
            "Open a freight route between two industries. The cargo is chosen "
            "automatically: something the source produced last month and the "
            "destination accepts. Use industry ids from get_state."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "industry_a": {"type": "integer", "description": "Producing industry id"},
                "industry_b": {"type": "integer", "description": "Accepting industry id"},
            },
            "required": ["industry_a", "industry_b"],
        },
    },
    {
        "name": "add_vehicles",
        "description": (
            "Put more vehicles on an existing route. Do this when get_state "
            "shows cargo piling up at a station."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "route": {"type": "integer", "description": "Route index from get_state"},
                "count": {"type": "integer", "description": "How many to add"},
            },
            "required": ["route", "count"],
        },
    },
    {
        "name": "set_loan",
        "description": "Set the loan. Pass -1 to borrow the maximum the bank allows.",
        "inputSchema": {
            "type": "object",
            "properties": {"amount": {"type": "integer", "description": "Amount, or -1 for maximum"}},
            "required": ["amount"],
        },
    },
    {
        "name": "set_company_name",
        "description": "Rename the company.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
]


def call_tool(name: str, args: dict):
    if name == "get_state":
        return read_state()

    if name == "get_results":
        return {"results": read_results(int(args.get("limit", 20)))}

    if name == "build_bus_route":
        oid = queue_order("bus_route", int(args["town_a"]), int(args["town_b"]))
        return {"queued": oid, "note": "Check get_results in a few seconds for the outcome."}

    if name == "build_truck_route":
        oid = queue_order("truck_route", int(args["industry_a"]), int(args["industry_b"]))
        return {"queued": oid, "note": "Check get_results in a few seconds for the outcome."}

    if name == "add_vehicles":
        oid = queue_order("add_vehicles", int(args["route"]), int(args["count"]))
        return {"queued": oid}

    if name == "set_loan":
        oid = queue_order("loan", int(args["amount"]))
        return {"queued": oid}

    if name == "set_company_name":
        oid = queue_order("set_name", str(args["name"]).replace("|", "/"))
        return {"queued": oid}

    raise ValueError(f"unknown tool: {name}")


def respond(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            continue

        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            respond(msg_id, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": SERVER_INFO,
            })
        elif method == "notifications/initialized":
            pass  # No reply expected for notifications.
        elif method == "tools/list":
            respond(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = msg.get("params", {})
            try:
                value = call_tool(params.get("name", ""), params.get("arguments") or {})
                respond(msg_id, {"content": [{"type": "text", "text": json.dumps(value, indent=2)}]})
            except Exception as exc:  # Report back rather than dying.
                respond(msg_id, {"content": [{"type": "text", "text": f"Error: {exc}"}], "isError": True})
        elif msg_id is not None:
            respond(msg_id, error={"code": -32601, "message": f"unknown method: {method}"})


if __name__ == "__main__":
    main()
