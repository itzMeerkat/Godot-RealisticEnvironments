"""Lists GDScript errors and warnings for the project's scripts.

Starts a headless Godot editor with its language server, opens every script and
prints the diagnostics the server publishes (the same warnings the script
editor shows, with the project's warning settings).

    GODOT=path/to/godot python tools/gd_lint.py [script.gd ...]

Without arguments it checks every *.gd file git does not ignore. Exits with 1 when any
diagnostic is reported.
"""
import json
import os
import pathlib
import socket
import subprocess
import sys
import time

PROJECT = pathlib.Path(__file__).resolve().parent.parent
PORT = 6111
STARTUP_SECONDS = 120
PER_FILE_SECONDS = 1.5


def main() -> int:
    godot = os.environ.get("GODOT")
    if not godot:
        sys.exit("Set GODOT to the Godot editor executable.")
    files = [PROJECT / f for f in sys.argv[1:]] or [
        PROJECT / f for f in subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.gd"], cwd=PROJECT, text=True).split()
        if (PROJECT / f).exists()
    ]
    editor = subprocess.Popen([godot, "--headless", "--editor", "--path", str(PROJECT), "--lsp-port", str(PORT)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        client = LspClient(_connect())
        client.request("initialize", {"processId": os.getpid(), "rootUri": PROJECT.as_uri(), "capabilities": {}})
        client.read(5.0)
        client.notify("initialized", {})
        client.read(10.0)
        for path in files:
            client.notify("textDocument/didOpen", {"textDocument": {
                "uri": path.resolve().as_uri(), "languageId": "gdscript", "version": 1,
                "text": path.read_text(encoding="utf-8")}})
            client.read(PER_FILE_SECONDS)
        client.read(5.0)
    finally:
        editor.kill()

    count = 0
    for uri, diagnostics in sorted(client.diagnostics.items()):
        relative = pathlib.Path(uri_to_path(uri)).relative_to(PROJECT).as_posix()
        for diagnostic in diagnostics:
            severity = {1: "error", 2: "warning"}.get(diagnostic.get("severity"), "info")
            print(f"{relative}:{diagnostic['range']['start']['line'] + 1}: {severity}: {diagnostic['message']}")
            count += 1
    print(f"{count} diagnostics in {len(files)} scripts ({len(client.diagnostics)} checked by the server)")
    return 1 if count or len(client.diagnostics) < len(files) else 0


def _connect() -> socket.socket:
    deadline = time.time() + STARTUP_SECONDS
    while time.time() < deadline:
        try:
            return socket.create_connection(("127.0.0.1", PORT), timeout=2)
        except OSError:
            time.sleep(1)
    sys.exit("The Godot language server did not start.")


def uri_to_path(uri: str) -> str:
    from urllib.parse import unquote, urlparse
    path = unquote(urlparse(uri).path)
    return path[1:] if os.name == "nt" and path.startswith("/") else path


class LspClient:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.sock.settimeout(1.0)
        self.buffer = b""
        self.next_id = 0
        self.diagnostics = {}

    def request(self, method: str, params: dict) -> None:
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})

    def notify(self, method: str, params: dict) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def _send(self, message: dict) -> None:
        body = json.dumps(message).encode()
        self.sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)

    def read(self, seconds: float) -> None:
        """Reads messages for this long, keeping the diagnostics."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    return
                self.buffer += chunk
            except socket.timeout:
                pass
            while b"\r\n\r\n" in self.buffer:
                header, rest = self.buffer.split(b"\r\n\r\n", 1)
                length = next(int(line.split(b":")[1]) for line in header.split(b"\r\n")
                              if line.lower().startswith(b"content-length"))
                if len(rest) < length:
                    break
                message = json.loads(rest[:length])
                self.buffer = rest[length:]
                if message.get("method") == "textDocument/publishDiagnostics":
                    self.diagnostics[message["params"]["uri"]] = message["params"]["diagnostics"]


if __name__ == "__main__":
    sys.exit(main())
