#!/usr/bin/env python3
"""Runtime regressions: monitoring-only frames, independent heartbeat, and state persistence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mock_komari_smoke import websocket_accept, read_ws_frame, write_ws_frame, terminate


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = b'{"jsonrpc":"2.0","result":{}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", websocket_accept(self.headers["Sec-WebSocket-Key"]))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        self.server.opens += 1
        # Any attempt to execute this command would create a marker in the test cwd.
        write_ws_frame(self.connection, 1, b'{"jsonrpc":"2.0","method":"agent.exec","params":{"command":"echo executed > remote-control-marker"}}')
        try:
            while True:
                opcode, payload = read_ws_frame(self.connection, timeout=90)
                if opcode == 9:
                    self.server.pings += 1
                    write_ws_frame(self.connection, 10, payload)
                elif opcode == 1:
                    self.server.reports += 1
                elif opcode == 8:
                    return
        except (OSError, EOFError, TimeoutError):
            return


def run(agent, seconds):
    server = Server(("127.0.0.1", 0), Handler)
    server.opens = server.pings = server.reports = 0
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="komari-runtime-") as temp:
            root = Path(temp)
            work, state = root / "work", root / "state"
            work.mkdir()
            state.mkdir()
            # The explicit state directory must work independently of cwd permissions.
            work.chmod(0o555)
            command = [str(Path(agent).resolve()), "--endpoint", f"http://127.0.0.1:{server.server_port}",
                       "--token", "runtime-test", "--protocol-version", "1", "--max-retries", "0",
                       "--interval", "60", "--month-rotate", "1", "--state-dir", str(state),
                       "--custom-ipv4", "203.0.113.1", "--custom-ipv6", "2001:db8::1"]
            try:
                proc = subprocess.Popen(command, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, encoding="utf-8", errors="replace")
                try:
                    deadline = time.monotonic() + seconds
                    while time.monotonic() < deadline:
                        if proc.poll() is not None:
                            raise AssertionError(f"agent exited early: {proc.communicate()[0]}")
                        time.sleep(0.1)
                finally:
                    terminate(proc)
                output = proc.communicate()[0]
                assert proc.returncode == 0, output
                assert "AccessDenied" not in output, output
                assert server.opens == 1, f"healthy websocket reconnected {server.opens} times"
                assert server.reports >= (2 if seconds >= 65 else 1), output
                if seconds >= 65:
                    assert server.pings >= 5, f"only {server.pings} pings with a 60-second report interval"
                assert not (work / "remote-control-marker").exists(), "remote command executed"
                assert not (work / "net_static.json").exists(), "state incorrectly written in cwd"
                persisted = state / "net_static.json"
                data = json.loads(persisted.read_text())
                assert "interfaces" in data and "config" in data
                # A second startup must load the saved state successfully.
                proc = subprocess.Popen(command, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, encoding="utf-8", errors="replace")
                time.sleep(2)
                terminate(proc)
                output = proc.communicate()[0]
                assert proc.returncode == 0, output
                assert "Failed to start netstatic" not in output, output
                json.loads(persisted.read_text())
                print(f"runtime ok: heartbeat={server.pings}, reports={server.reports}, persisted state reload ok")
            finally:
                work.chmod(0o755)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agent")
    parser.add_argument("--seconds", type=float, default=70)
    args = parser.parse_args()
    run(args.agent, args.seconds)
