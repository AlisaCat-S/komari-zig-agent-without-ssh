#!/usr/bin/env python3
"""Check failed WebSocket retry pacing, recovery, and interruptible backoff."""
import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

from mock_komari_smoke import terminate
from test_monitoring_runtime import Handler, Server


class UnavailableHandler(Handler):
    def do_POST(self):
        self.server.uploads.append(time.monotonic())
        super().do_POST()

    def do_GET(self):
        self.server.attempts.append(time.monotonic())
        if self.server.available.is_set():
            return super().do_GET()
        self.send_response(503)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True


@contextmanager
def running_agent(agent, retries, interval):
    server = Server(("127.0.0.1", 0), UnavailableHandler)
    server.attempts, server.uploads = [], []
    server.available = threading.Event()
    server.opens = server.pings = server.reports = 0
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="komari-reconnect-") as temp, tempfile.TemporaryFile(mode="w+") as log:
            command = [str(Path(agent).resolve()), "--endpoint", f"http://127.0.0.1:{server.server_port}",
                       "--token", "reconnect-test", "--protocol-version", "1", "--max-retries", str(retries),
                       "--reconnect-interval", str(interval), "--interval", "1", "--month-rotate", "1",
                       "--state-dir", temp, "--custom-ipv4", "203.0.113.1", "--custom-ipv6", "2001:db8::1"]
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("AGENT_") and key != "KOMARI_STATUS_FILE"}
            # A file, not an undrained pipe: full output buffers must not hide a hot loop.
            proc = subprocess.Popen(command, cwd=temp, env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                yield proc, server, log
            finally:
                terminate(proc)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def wait_for(proc, predicate, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert proc.poll() is None, f"agent exited while waiting for {label}: {proc.returncode}"
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(f"timed out waiting for {label}")


def check_retry_pacing(agent, retries):
    with running_agent(agent, retries, 1) as (proc, server, log):
        # Include the boundary between two retry batches, not just the inner retries.
        target = max(3, retries + 2)
        wait_for(proc, lambda: len(server.attempts) >= target, "retry batch boundary")
        attempts = list(server.attempts)
        gaps = [later - earlier for earlier, later in zip(attempts, attempts[1:])]
        assert min(gaps) >= 0.9, f"max_retries={retries}: reconnect gaps {gaps}"
        upload_gaps = [later - earlier for earlier, later in zip(server.uploads, server.uploads[1:])]
        assert upload_gaps and min(upload_gaps) >= 0.9, f"basic info uploads bypassed backoff: {upload_gaps}"

        server.available.set()
        wait_for(proc, lambda: server.reports > 0, "reporting after panel recovery")
        assert server.opens == 1, f"recovery opened {server.opens} WebSockets"
        terminate(proc)
        log.seek(0)
        output = log.read()
        assert proc.returncode == 0, output
        assert "Report websocket exited: WebSocketHandshakeFailed" in output, output
        assert "ShutdownRequested" not in output, output
        print(f"reconnect ok: max_retries={retries}, gaps={[round(gap, 3) for gap in gaps]}, recovery report received")


def check_shutdown_during_backoff(agent):
    with running_agent(agent, 0, 30) as (proc, server, log):
        wait_for(proc, lambda: len(server.attempts) > 0, "first failed connection")
        time.sleep(0.2)
        started = time.monotonic()
        terminate(proc)
        elapsed = time.monotonic() - started
        log.seek(0)
        output = log.read()
        assert proc.returncode == 0, output
        assert elapsed < 2.5, f"shutdown waited {elapsed:.3f}s for a 30-second backoff"
        assert len(server.attempts) == 1, f"retried before backoff elapsed: {len(server.attempts)}"
        assert len(server.uploads) == 1, "basic info was uploaded again before backoff elapsed"
        # Monthly state keeps the signal handler on the graceful path, exercising sleepOrStop.
        assert "shutting down gracefully..." in output, output
        assert "ShutdownRequested" not in output, output
        print(f"shutdown ok: interrupted 30-second backoff in {elapsed:.3f}s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agent")
    args = parser.parse_args()
    check_retry_pacing(args.agent, 0)
    check_retry_pacing(args.agent, 3)
    check_shutdown_during_backoff(args.agent)
