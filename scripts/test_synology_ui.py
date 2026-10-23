#!/usr/bin/env python3
"""Compile and exercise the real CGI with isolated DSM authentication/service fixtures."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = ROOT / "deploy/synology/ui"
PACKAGE_ROOT = None
CGI = None


def setup_fixture():
    for directory in ("var", "tmp", "target/bin", "scripts"):
        (PACKAGE_ROOT / directory).mkdir(parents=True, exist_ok=True)
    (PACKAGE_ROOT / "var/config.json").write_text(json.dumps({
        "endpoint": "https://panel.example", "token": "private-original-token", "interval": 3,
        "protocol_version": 2, "custom_dns": "192.0.2.53", "cf_access_client_secret": "private-cf-secret",
        "future_field": {"keep": [1, 2, 3]}}))
    for filename, source in {
        "authenticate": '#!/bin/sh\n[ "$HTTP_X_SYNO_TOKEN" = test-syno-token ] || exit 1\n'
                        'case "$HTTP_COOKIE" in admin) echo admin ;; viewer) echo viewer ;; esac\n',
        "id": '#!/bin/sh\ncase "$2" in admin) echo "users administrators" ;; viewer) echo users ;; *) exit 1 ;; esac\n',
        "scripts/start-stop-status": '''#!/bin/sh
set -eu
case "$1" in
  status) [ -f "$SYNOPKG_PKGTMP/running" ] || exit 3 ;;
  stop) [ ! -f "$SYNOPKG_PKGTMP/stop-fails" ] || exit 1; rm -f "$SYNOPKG_PKGTMP/running" ;;
  start) grep -q 'fail-start' "$SYNOPKG_PKGVAR/config.json" && exit 1
         touch "$SYNOPKG_PKGTMP/running" ;;
esac
''',
    }.items():
        path = PACKAGE_ROOT / filename
        path.write_text(source)
        path.chmod(0o755)
    for marker in ("running", "stop-fails", "status.json"):
        (PACKAGE_ROOT / "tmp" / marker).unlink(missing_ok=True)


def invoke(body=None, overrides=None):
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else b""
    env = dict(os.environ, REQUEST_METHOD="POST" if body is not None else "GET", HTTP_COOKIE="admin",
               HTTP_X_SYNO_TOKEN="test-syno-token", HTTP_HOST="nas.local:5001", HTTP_ORIGIN="https://nas.local:5001",
               HTTP_X_KOMARI_REQUEST="1", CONTENT_TYPE="application/json", CONTENT_LENGTH=str(len(data)),
               REMOTE_ADDR="127.0.0.1", SERVER_ADDR="127.0.0.1", SERVER_PORT="5001", HTTPS="on")
    env.update(overrides or {})
    result = subprocess.run([str(CGI)], input=data, capture_output=True, env=env, timeout=40)
    if result.returncode:
        raise AssertionError(result.stderr.decode())
    headers, payload = result.stdout.decode().split("\r\n\r\n", 1)
    code = int(headers.splitlines()[0].split()[1])
    return code, json.loads(payload), headers


class ApiTests(unittest.TestCase):
    def setUp(self):
        setup_fixture()

    def current(self):
        code, data, headers = invoke()
        self.assertEqual(code, 200, data)
        self.assertIn("no-store", headers)
        return data

    def test_config_and_status_do_not_expose_secrets(self):
        status = self.current()
        self.assertNotIn("private-original-token", json.dumps(status))
        self.assertNotIn("private-cf-secret", json.dumps(status))
        self.assertTrue(status["token_configured"])
        self.assertFalse(status["running"])

    def test_unauthenticated_and_non_admin_cannot_read_or_write(self):
        original = (PACKAGE_ROOT / "var/config.json").read_bytes()
        for env, expected in (({"HTTP_COOKIE": ""}, 401), ({"HTTP_X_SYNO_TOKEN": ""}, 401),
                              ({"HTTP_X_SYNO_TOKEN": "wrong"}, 401), ({"HTTP_COOKIE": "viewer"}, 403)):
            for body in (None, {"endpoint": "https://changed.example"}):
                code, _, _ = invoke(body, env)
                self.assertEqual(code, expected)
        self.assertEqual((PACKAGE_ROOT / "var/config.json").read_bytes(), original)

    def test_cross_origin_and_simple_posts_rejected(self):
        for overrides in ({"HTTP_ORIGIN": "https://evil.example"}, {"HTTP_ORIGIN": ""},
                          {"HTTP_X_KOMARI_REQUEST": ""}, {"CONTENT_TYPE": "text/plain"}):
            code, _, _ = invoke({"revision": self.current()["revision"]}, overrides)
            self.assertIn(code, (400, 403))

    def test_save_retains_token_unknown_fields_and_stopped_state(self):
        code, result, _ = invoke({"revision": self.current()["revision"], "endpoint": "https://new.example",
                                 "token": "", "interval": 0.5, "protocol_version": 1,
                                 "include_nics": "eth*,bond0", "exclude_nics": "wlan*,eth1",
                                 "include_mountpoints": "/volume1;/volume2"})
        self.assertEqual(code, 200, result)
        self.assertFalse(result["restarted"])
        cfg = json.loads((PACKAGE_ROOT / "var/config.json").read_text())
        self.assertEqual(cfg["token"], "private-original-token")
        self.assertEqual(cfg["future_field"], {"keep": [1, 2, 3]})
        self.assertEqual(cfg["cf_access_client_secret"], "private-cf-secret")
        self.assertEqual(cfg["interval"], 0.5)
        self.assertEqual(cfg["include_nics"], "eth*,bond0")
        self.assertEqual(cfg["exclude_nics"], "wlan*,eth1")
        self.assertEqual(cfg["include_mountpoints"], "/volume1;/volume2")
        self.assertEqual((PACKAGE_ROOT / "var/config.json").stat().st_mode & 0o777, 0o600)

    def test_token_escaping_and_running_restart(self):
        (PACKAGE_ROOT / "tmp/running").touch()
        token = '"\\\n中文 $(touch must-not-execute)'
        code, result, _ = invoke({"revision": self.current()["revision"], "token": token})
        self.assertEqual(code, 200, result)
        self.assertTrue(result["restarted"])
        self.assertEqual(json.loads((PACKAGE_ROOT / "var/config.json").read_text())["token"], token)
        self.assertTrue(self.current()["running"])

    def test_stale_revision_cannot_overwrite_config(self):
        rev = self.current()["revision"]
        self.assertEqual(invoke({"revision": rev, "interval": 7})[0], 200)
        self.assertEqual(invoke({"revision": rev, "interval": 8})[0], 409)
        self.assertEqual(self.current()["config"]["interval"], 7)

    def test_invalid_inputs_and_unknown_fields_leave_config_untouched(self):
        original = (PACKAGE_ROOT / "var/config.json").read_bytes()
        for field, value in (("endpoint", "file:///etc/passwd"), ("endpoint", "https://"),
                             ("endpoint", "https://x y"), ("endpoint", "https://u:p@example.com"),
                             ("interval", 0), ("interval", "3"), ("protocol_version", 3),
                             ("token", None), ("command", "id"), ("state_dir", "/tmp/elsewhere")):
            with self.subTest(field=field, value=value):
                code, _, _ = invoke({"revision": self.current()["revision"], field: value})
                self.assertEqual(code, 400)
                self.assertEqual((PACKAGE_ROOT / "var/config.json").read_bytes(), original)

    def test_failed_restart_restores_config_and_service(self):
        (PACKAGE_ROOT / "tmp/running").touch()
        original = (PACKAGE_ROOT / "var/config.json").read_bytes()
        code, result, _ = invoke({"revision": self.current()["revision"], "endpoint": "https://fail-start.example"})
        self.assertEqual(code, 500)
        self.assertIn("已恢复", result["message"])
        self.assertEqual((PACKAGE_ROOT / "var/config.json").read_bytes(), original)
        self.assertTrue(self.current()["running"])

    def test_stop_failure_keeps_original_config(self):
        (PACKAGE_ROOT / "tmp/running").touch()
        (PACKAGE_ROOT / "tmp/stop-fails").touch()
        original = (PACKAGE_ROOT / "var/config.json").read_bytes()
        self.assertEqual(invoke({"revision": self.current()["revision"], "interval": 4})[0], 500)
        self.assertEqual((PACKAGE_ROOT / "var/config.json").read_bytes(), original)

    def test_state_does_not_promote_ws_send_to_http_confirmation(self):
        (PACKAGE_ROOT / "tmp/running").touch()
        telemetry = {"connection": "connected", "reports_sent": 8, "http_reports_confirmed": 0}
        (PACKAGE_ROOT / "tmp/status.json").write_text(json.dumps(telemetry))
        self.assertEqual(self.current()["telemetry"], telemetry)


def serve(port):
    """Local-only visual fixture; production assets have no test-session logic."""
    setup_fixture()
    (PACKAGE_ROOT / "tmp/running").touch()
    (PACKAGE_ROOT / "tmp/status.json").write_text(json.dumps({
        "connection": "connected", "transport": "websocket", "protocol_version": 2, "reports_sent": 1248,
        "updated_at": time.time(), "last_report_sent_at": time.time(), "started_at": time.time() - 3744,
        "basic_info_confirmed_at": time.time() - 13, "last_http_confirmed_at": 0, "last_error": ""}))

    class Preview(BaseHTTPRequestHandler):
        def request_environment(self):
            return {"HTTP_X_SYNO_TOKEN": self.headers.get("X-SYNO-TOKEN", ""),
                    "HTTP_X_KOMARI_REQUEST": self.headers.get("X-Komari-Request", ""),
                    "HTTP_HOST": self.headers.get("Host", ""),
                    "HTTP_ORIGIN": self.headers.get("Origin", ""),
                    "CONTENT_TYPE": self.headers.get("Content-Type", "")}

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/api.cgi":
                code, data, _ = invoke(overrides=self.request_environment())
                return self.send(code, json.dumps(data).encode(), "application/json")
            if path == "/fixture-session.js":
                return self.send(200, b'window.SYNO={SDS:{Session:{SynoToken:"test-syno-token"}}};', "text/javascript")
            if path.startswith("/images/"):
                from build_synology_spk import icon
                return self.send(200, icon(64), "image/png")
            filename = "index.html" if path == "/" else path.lstrip("/")
            if filename not in ("index.html", "app.css", "app.js"):
                return self.send(404, b"Not found", "text/plain")
            data = (UI / filename).read_bytes()
            if filename == "index.html":
                data = data.replace(b'<script src="app.js"', b'<script src="fixture-session.js"></script><script src="app.js"')
            mime = {"index.html": "text/html; charset=utf-8", "app.css": "text/css", "app.js": "text/javascript"}[filename]
            self.send(200, data, mime)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            code, data, _ = invoke(body, self.request_environment())
            self.send(code, json.dumps(data).encode(), "application/json")

        def send(self, code, data, content_type):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

    print(f"Local DSM fixture at http://127.0.0.1:{port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", port), Preview).serve_forever()


def main():
    global PACKAGE_ROOT, CGI
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--serve", type=int, help="After tests, serve local visual fixture on this port")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="komari-dsm-ui-") as directory:
        PACKAGE_ROOT = Path(directory)
        # Relative prefix also works when using the Windows Zig executable from WSL.
        prefix = Path("build") / PACKAGE_ROOT.name
        subprocess.run([args.zig, "build", "-Dtarget=x86_64-linux-musl", "-Doptimize=ReleaseSmall", "-Ddsm-ui=true",
                        f"-Ddsm-test-root={directory}", "--prefix", str(prefix)], cwd=ROOT, check=True)
        CGI = ROOT / prefix / "bin/komari-dsm-api.cgi"
        CGI.chmod(0o755)
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ApiTests))
        if not result.wasSuccessful():
            raise SystemExit(1)
        if args.serve:
            serve(args.serve)


if __name__ == "__main__":
    main()
