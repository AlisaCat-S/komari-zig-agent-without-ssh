#!/usr/bin/env python3
"""Run with a Debug agent: silent peers must time out, not crash the process."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

from mock_komari_smoke import read_ws_frame, write_ws_frame, websocket_accept, terminate
from test_monitoring_runtime import Handler, Server
from test_reconnect_runtime import wait_for


class IdleHandler(Handler):
    def do_GET(self):
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", websocket_accept(self.headers["Sec-WebSocket-Key"]))
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        record = {"opened": time.monotonic(), "closed": None, "pings": 0, "reports": 0}
        self.server.connections.append(record)
        # The first silent connection ignores Ping; the recovered connection replies.
        reply_pong = self.server.reply_pong or len(self.server.connections) > 1
        try:
            while True:
                opcode, payload = read_ws_frame(self.connection, timeout=90)
                if opcode == 9:
                    record["pings"] += 1
                    if reply_pong:
                        write_ws_frame(self.connection, 10, payload)
                elif opcode == 1:
                    record["reports"] += 1
                elif opcode == 8:
                    return
        except (OSError, EOFError, TimeoutError):
            return
        finally:
            record["closed"] = time.monotonic()


def check(agent, reply_pong):
    server = Server(("127.0.0.1", 0), IdleHandler)
    server.reply_pong, server.connections = reply_pong, []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="komari-ws-timeout-") as temp, tempfile.TemporaryFile(mode="w+") as log:
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("AGENT_") and key != "KOMARI_STATUS_FILE"}
            env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
            command = [str(Path(agent).resolve()), "--endpoint", f"http://127.0.0.1:{server.server_port}",
                       "--token", "timeout-test", "--protocol-version", "2", "--max-retries", "0",
                       "--interval", "60" if reply_pong else "3", "--debug-log",
                       "--custom-ipv4", "203.0.113.1", "--custom-ipv6", "2001:db8::1"]
            proc = subprocess.Popen(command, env=env, cwd=temp, stdout=log, stderr=subprocess.STDOUT)
            try:
                wait_for(proc, lambda: bool(server.connections), "initial WebSocket")
                first = server.connections[0]
                if reply_pong:
                    deadline = first["opened"] + 65
                    wait_for(proc, lambda: time.monotonic() >= deadline, "65 seconds of Pong-only traffic", timeout=70)
                    assert len(server.connections) == 1 and first["closed"] is None, "healthy connection dropped"
                    assert first["pings"] >= 5 and first["reports"] >= 2, first
                    print(f"Pong-only peer ok: 65s, one connection, {first['pings']} pings, {first['reports']} reports", flush=True)
                else:
                    wait_for(proc, lambda: len(server.connections) >= 2 and
                             server.connections[1]["pings"] > 0 and server.connections[1]["reports"] > 0,
                             "reconnection with working heartbeat and reports", timeout=50)
                    assert first["closed"] is not None, "silent connection never closed"
                    elapsed = first["closed"] - first["opened"]
                    assert 29 <= elapsed <= 40, f"unexpected receive timeout: {elapsed:.3f}s"
                    assert first["pings"] >= 2 and first["reports"] >= 9, first
                    assert len(server.connections) == 2, "recovered connection dropped again"
                    print(f"silent peer ok: timed out after {elapsed:.3f}s, reconnected and resumed reporting", flush=True)
            except Exception as exc:
                log.seek(0)
                raise AssertionError(f"{exc}\n{log.read()}") from exc
            finally:
                terminate(proc)
            log.seek(0)
            output = log.read()
            assert proc.returncode == 0 and "panic:" not in output, output
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agent")
    args = parser.parse_args()
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(check, args.agent, reply_pong) for reply_pong in (True, False)]
        for future in futures:
            future.result()
