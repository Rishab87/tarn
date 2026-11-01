#!/usr/bin/env python3
"""Tiny Streamable-HTTP MCP server for testing Tarn's remote connectors.
Tool: get_order(order_id). Run: python3 scripts/dev/mcp_http.py <port>"""
import json, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

ORDERS = {"1042": "Shipped on 30 October 2026 via BlueDart, arriving 3 November.", "1043": "Processing; ships within 2 days."}
TOOLS = [{"name": "get_order", "description": "Look up the delivery status of a shop order by its number.",
          "inputSchema": {"type": "object", "properties": {"order_id": {"type": "string"}}, "required": ["order_id"]}}]
SESSION = str(uuid.uuid4())

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if "id" not in body:  # notification
            self.send_response(202); self.end_headers(); return
        method, params = body.get("method"), body.get("params", {})
        if method == "initialize":
            result = {"protocolVersion": params.get("protocolVersion"), "capabilities": {"tools": {}}, "serverInfo": {"name": "tarn-test-orders", "version": "1.0"}}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            oid = str(params.get("arguments", {}).get("order_id", "")).lstrip("#")
            result = {"content": [{"type": "text", "text": ORDERS.get(oid, f"No order {oid} found.")}]}
        else:
            result = {}
        data = json.dumps({"jsonrpc": "2.0", "id": body["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Mcp-Session-Id", SESSION)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
