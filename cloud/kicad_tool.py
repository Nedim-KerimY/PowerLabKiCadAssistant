"""Call the KiCad MCP server's tools from a shell, without an MCP client.

For sessions where the `kicad` server from .mcp.json isn't connected (e.g. it was
added after the session started). Each run starts the server, makes the calls in
order within that one server process (so state like an opened project carries over
from one call to the next), prints each result, and stops the server.

    python3 cloud/kicad_tool.py list [filter]
    python3 cloud/kicad_tool.py describe <tool>
    python3 cloud/kicad_tool.py call <tool> '<json args>' [<tool> '<json args>' ...]

Images in results are saved as files and their paths printed.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time

WRAPPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kicad-mcp.sh")
TIMEOUT = float(os.environ.get("KICAD_TOOL_TIMEOUT", "1800"))


class Server:
    def __init__(self):
        self.proc = subprocess.Popen(["bash", WRAPPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.devnull, "w") if not os.environ.get("KICAD_TOOL_DEBUG")
                                     else None, text=True, encoding="utf-8")
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "kicad_tool", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        result = {}

        def read():
            for line in self.proc.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue  # stray log output
                if message.get("id") == self.next_id:
                    result.update(message)
                    return

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        reader.join(TIMEOUT)
        if not result:
            sys.exit(f"No answer to {method} within {TIMEOUT:.0f} s (set KICAD_TOOL_DEBUG=1 for server logs).")
        if "error" in result:
            sys.exit(f"{method} failed: {result['error']}")
        return result["result"]

    def call(self, name, arguments):
        # The server answers before its Python process is up (about 2 s); wait for it.
        for _ in range(120):
            result = self.request("tools/call", {"name": name, "arguments": arguments})
            text = " ".join(i.get("text", "") for i in result.get("content", []))
            if not (result.get("isError") and "process for KiCAD scripting is not running" in text):
                return result
            time.sleep(0.5)
        return result

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def show(result, image_dir):
    for item in result.get("content", []):
        if item.get("type") == "text":
            print(item["text"])
        elif item.get("type") == "image":
            import base64
            ext = item.get("mimeType", "image/png").split("/")[-1].replace("svg+xml", "svg")
            fd, path = tempfile.mkstemp(suffix="." + ext, dir=image_dir)
            with os.fdopen(fd, "wb") as f:
                f.write(base64.b64decode(item["data"]))
            print(f"[image saved: {path}]")
        else:
            print(json.dumps(item, indent=2))
    if result.get("isError"):
        print("[tool reported an error]")


def main(argv):
    if not argv or argv[0] not in ("list", "describe", "call"):
        sys.exit(__doc__)
    server = Server()
    try:
        if argv[0] in ("list", "describe"):
            tools = server.request("tools/list", {})["tools"]
            if argv[0] == "describe":
                tool = next((t for t in tools if t["name"] == argv[1]), None)
                print(json.dumps(tool, indent=2) if tool else f"No tool named {argv[1]}")
                return
            word = argv[1].lower() if len(argv) > 1 else ""
            for t in tools:
                if word in t["name"].lower() or word in t.get("description", "").lower():
                    print(f"{t['name']}: {t.get('description', '').splitlines()[0] if t.get('description') else ''}")
            return
        pairs = argv[1:]
        if not pairs or len(pairs) % 2:
            sys.exit("call needs <tool> '<json args>' pairs")
        image_dir = os.environ.get("KICAD_TOOL_IMAGES", tempfile.gettempdir())
        for name, args in zip(pairs[::2], pairs[1::2]):
            print(f"=== {name}")
            show(server.call(name, json.loads(args)), image_dir)
    finally:
        server.close()


if __name__ == "__main__":
    main(sys.argv[1:])
