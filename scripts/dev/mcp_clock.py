#!/usr/bin/env python3
"""Tiny MCP server over stdio for testing Tarn's connector support.
Tools: get_time(timezone), add(a, b)."""
import json, sys
from datetime import datetime
from zoneinfo import ZoneInfo

TOOLS = [
    {"name": "get_time", "description": "Current local time in an IANA time zone such as Asia/Tokyo.",
     "inputSchema": {"type": "object", "properties": {"timezone": {"type": "string"}}, "required": ["timezone"]}},
    {"name": "add", "description": "Add two numbers.",
     "inputSchema": {"type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}, "required": ["a", "b"]}},
]

def call(name, args):
    if name == "get_time":
        tz = ZoneInfo(args["timezone"])
        return datetime.now(tz).strftime("%A %d %B %Y, %H:%M (%Z)")
    if name == "add":
        return str(args["a"] + args["b"])
    raise ValueError(f"unknown tool {name}")

for line in sys.stdin:
    msg = json.loads(line)
    if "id" not in msg:
        continue  # notification
    mid, method, params = msg["id"], msg.get("method"), msg.get("params", {})
    try:
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"), "capabilities": {"tools": {}},
                      "serverInfo": {"name": "tarn-test-clock", "version": "1.0"}}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            result = {"content": [{"type": "text", "text": call(params["name"], params.get("arguments", {}))}]}
        else:
            raise ValueError(f"unsupported method {method}")
        reply = {"jsonrpc": "2.0", "id": mid, "result": result}
    except Exception as e:
        reply = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": str(e)}}
    sys.stdout.write(json.dumps(reply) + "\n")
    sys.stdout.flush()
