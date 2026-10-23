#!/usr/bin/env python3
"""SPK structure and real lifecycle regression tests in temporary DSM-like directories.

Set KOMARI_TEST_AGENT to a static Linux amd64 agent to test it instead of the tiny
signal-handling fixture. These tests do not emulate DSM Package Center itself.
"""
import io
import gzip
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest

import build_synology_spk as spk


def elf_fixture(arch):
    machine, elf_class, _ = spk.ARCHES[arch]
    data = bytearray(128)
    data[:6] = b"\x7fELF" + bytes([elf_class, 1])
    struct.pack_into("<H", data, 18, machine)
    if elf_class == 2:
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
    else:
        struct.pack_into("<I", data, 28, 64)
        struct.pack_into("<HH", data, 42, 32, 1)
    struct.pack_into("<I", data, 64, 1)
    return data


class PackageTests(unittest.TestCase):
    def test_all_archives_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for arch in spk.ARCHES:
                with self.subTest(arch=arch):
                    binary = root / "agent"
                    binary.write_bytes(elf_fixture(arch))
                    (root / "komari-dsm-api.cgi").write_bytes(elf_fixture(arch))
                    package = spk.build(binary, arch, "v0.0.0-main.123", 456, root)
                    with tarfile.open(package) as tar:
                        names = tar.getnames()
                        info = tar.extractfile("INFO").read().decode()
                        self.assertIn(f'version="{spk.PACKAGE_VERSION}-456"', info)
                        self.assertIn('os_min_ver="7.0-41890"', info)
                        self.assertIn(f'arch="{spk.ARCHES[arch][2]}"', info)
                        self.assertNotIn('arch="noarch"', info)
                        self.assertIn("v0.0.0-main.123", info)
                        privilege = json.load(tar.extractfile("conf/privilege"))
                        self.assertEqual(privilege["defaults"], {"run-as": "package"})
                        self.assertEqual(privilege["tool"], [{"relpath": "ui/api.cgi", "user": "package", "group": "package", "permission": "4755"}])
                        self.assertIn('dsmuidir="ui"', info)
                        self.assertIn('dsmappname="com.komari.monitor"', info)
                        for name in ("preinst", "postinst", "preuninst", "postuninst", "preupgrade", "postupgrade", "start-stop-status", "common"):
                            member = tar.getmember(f"scripts/{name}")
                            self.assertEqual(member.mode, 0o755)
                            self.assertNotIn(b"\r", tar.extractfile(member).read())
                        for suffix in ("", "_chs"):
                            wizard = json.load(tar.extractfile(f"WIZARD_UIFILES/install_uifile{suffix}"))
                            fields = {item["subitems"][0]["key"]: item for item in wizard[0]["items"] if "subitems" in item}
                            self.assertEqual(set(fields), {"wizard_endpoint", "wizard_token", "wizard_interval"})
                            self.assertEqual(fields["wizard_token"]["type"], "password")
                        for name, size in (("PACKAGE_ICON.PNG", 64), ("PACKAGE_ICON_256.PNG", 256)):
                            png = tar.extractfile(name).read()
                            self.assertEqual(struct.unpack(">II", png[16:24]), (size, size))
                        self.assertTrue(all(not n.startswith("/") and ".." not in Path(n).parts for n in names))
                        with tarfile.open(fileobj=io.BytesIO(tar.extractfile("package.tgz").read()), mode="r:gz") as payload:
                            self.assertEqual(payload.extractfile("bin/komari-agent").read(), binary.read_bytes())
                            self.assertEqual(payload.getmember("bin/komari-agent").mode, 0o755)
                            self.assertEqual(payload.getmember("ui/api.cgi").mode, 0o755)
                            app = json.load(payload.extractfile("ui/config"))[".url"]["com.komari.monitor"]
                            self.assertFalse(app["allUsers"])
                            self.assertIn("ui/index.html", payload.getnames())

    def test_rejects_wrong_arch_and_dynamic_binary(self):
        with self.assertRaises(ValueError):
            spk.validate_binary(elf_fixture("arm64"), "amd64")
        dynamic = elf_fixture("amd64")
        struct.pack_into("<I", dynamic, 64, 3)
        with self.assertRaisesRegex(ValueError, "static"):
            spk.validate_binary(dynamic, "amd64")
        with self.assertRaises(ValueError):
            spk.validate_binary(b"not an ELF", "amd64")

    def test_rejects_unsafe_metadata(self):
        with self.assertRaises(ValueError):
            spk.build("unused", "amd64", 'v1.0.0"\npackage="other', 1, "unused")
        for revision in (0, -1, 2147483648):
            with self.assertRaises(ValueError):
                spk.build("unused", "amd64", "v1.0.0", revision, "unused")


@unittest.skipUnless(sys.platform.startswith("linux"), "lifecycle tests require Linux /proc and POSIX shell")
class LifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_temp = tempfile.TemporaryDirectory(prefix="komari-spk-executable-")
        cls.binary = Path(cls.fixture_temp.name) / "komari-agent"
        cls.real_agent = os.environ.get("KOMARI_TEST_AGENT")
        if cls.real_agent:
            shutil.copyfile(cls.real_agent, cls.binary)
            cgi = os.environ.get("KOMARI_TEST_CGI", str(Path(cls.real_agent).with_name("komari-dsm-api.cgi")))
            cls.package = spk.build(cls.binary, "amd64", "test", 1, cls.fixture_temp.name, cgi)
        else:
            source = cls.binary.with_suffix(".c")
            source.write_text('#include <signal.h>\n#include <unistd.h>\n'
                              'static volatile sig_atomic_t stop=0;\n'
                              'static void term(int sig) {(void)sig;stop=1;}\n'
                              'int main(void) {signal(SIGTERM,term);while(!stop) pause();return 0;}\n')
            subprocess.run(["cc", str(source), "-o", str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="komari spk lifecycle ")
        self.root = Path(self.temp.name)
        self.dest = self.root / "target"
        self.var = self.root / "var"
        self.tmp = self.root / "tmp"
        for path in (self.dest / "bin", self.var, self.tmp):
            path.mkdir(parents=True)
        self.scripts = self.root / "scripts"
        self.agent = self.dest / "bin/komari-agent"
        if self.real_agent:
            # Exercise the control scripts and payload from the actual built SPK.
            self.scripts.mkdir()
            with tarfile.open(self.package) as package:
                for member in package.getmembers():
                    if member.isfile() and member.name.startswith("scripts/"):
                        (self.root / member.name).write_bytes(package.extractfile(member).read())
                with tarfile.open(fileobj=io.BytesIO(package.extractfile("package.tgz").read()), mode="r:gz") as payload:
                    self.agent.write_bytes(payload.extractfile("bin/komari-agent").read())
        else:
            shutil.copytree(spk.TEMPLATE / "scripts", self.scripts)
            shutil.copyfile(self.binary, self.agent)
        self.agent.chmod(0o755)
        self.config = self.var / "config.json"
        self.env = dict(os.environ, SYNOPKG_PKGDEST=str(self.dest), SYNOPKG_PKGVAR=str(self.var),
                        SYNOPKG_PKGTMP=str(self.tmp), SYNOPKG_PKG_STATUS="INSTALL",
                        SYNOPKG_TEMP_LOGFILE=str(self.root / "error"), wizard_endpoint="http://127.0.0.1:1",
                        wizard_token="test-token", wizard_interval="3")
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.run_script("start-stop-status", "stop", check=False)
        self.temp.cleanup()

    def run_script(self, name, *args, check=True, env=None):
        result = subprocess.run(["sh", str(self.scripts / name), *args], env=env or self.env,
                                capture_output=True, text=True, timeout=40)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def install(self):
        self.run_script("preinst")
        self.run_script("postinst")

    def test_install_escapes_settings_and_limits_permissions(self):
        token = 'quotes" \\ \n\t\x01 中文 $(touch SHOULD_NOT_EXIST) `id`'
        self.env["wizard_token"] = token
        self.install()
        value = json.loads(self.config.read_text())
        self.assertEqual(value["token"], token)
        self.assertEqual(value["protocol_version"], 2)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.var / "state").stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())

    def test_bad_input_fails_before_writing_config(self):
        for key, value in (("wizard_endpoint", "file:///etc/passwd"), ("wizard_endpoint", "https://x y"),
                           ("wizard_token", ""), ("wizard_interval", "0"), ("wizard_interval", "99999"),
                           ("wizard_interval", "1;id"), ("wizard_interval", "9" * 30)):
            with self.subTest(key=key, value=value):
                env = dict(self.env, **{key: value})
                self.assertNotEqual(self.run_script("preinst", env=env, check=False).returncode, 0)
                self.assertNotEqual(self.run_script("postinst", env=env, check=False).returncode, 0)
                self.assertFalse(self.config.exists())

    def test_upgrade_preserves_exact_config_and_monthly_state(self):
        self.install()
        original = self.config.read_text().replace('"protocol_version": 2', '"protocol_version": 1, "custom_ipv4": "192.0.2.1"')
        self.config.write_text(original)
        state = self.var / "state/net_static.json"
        state.write_text('{"retained": true}')
        self.env.update(SYNOPKG_PKG_STATUS="UPGRADE", wizard_token="", wizard_endpoint="")
        for name in ("preupgrade", "preuninst", "postuninst", "preinst", "postinst", "postupgrade"):
            self.run_script(name)
        self.assertEqual(self.config.read_text(), original)
        self.assertEqual(state.read_text(), '{"retained": true}')

    def test_missing_upgrade_config_fails(self):
        self.env["SYNOPKG_PKG_STATUS"] = "UPGRADE"
        self.assertNotEqual(self.run_script("preupgrade", check=False).returncode, 0)
        self.assertNotEqual(self.run_script("postinst", check=False).returncode, 0)

    def test_start_status_restart_stop(self):
        self.install()
        self.assertEqual(self.run_script("start-stop-status", "status", check=False).returncode, 3)
        self.run_script("start-stop-status", "prestart")
        self.run_script("start-stop-status", "start")
        first_pid = (self.tmp / "agent.pid").read_text()
        self.run_script("start-stop-status", "status")
        self.run_script("start-stop-status", "start")
        self.assertEqual((self.tmp / "agent.pid").read_text(), first_pid)
        pid = first_pid.split()[0]
        self.assertNotIn(b"test-token", Path(f"/proc/{pid}/cmdline").read_bytes())
        self.assertEqual(os.readlink(f"/proc/{pid}/cwd"), str(self.var / "state"))
        self.run_script("start-stop-status", "restart")
        self.assertNotEqual((self.tmp / "agent.pid").read_text(), first_pid)
        self.run_script("start-stop-status", "stop")
        self.assertEqual(self.run_script("start-stop-status", "status", check=False).returncode, 3)
        self.assertFalse((self.tmp / "agent.pid").exists())

    def test_stale_pid_does_not_signal_unrelated_process(self):
        self.install()
        with subprocess.Popen(["sleep", "60"]) as other:
            try:
                stat = Path(f"/proc/{other.pid}/stat").read_text().rsplit(") ", 1)[1].split()
                (self.tmp / "agent.pid").write_text(f"{other.pid} {stat[19]}\n")
                self.run_script("start-stop-status", "stop")
                self.assertIsNone(other.poll())
            finally:
                other.terminate()

    def test_wrong_birth_time_does_not_signal_same_executable(self):
        self.install()
        self.run_script("start-stop-status", "start")
        pidfile = self.tmp / "agent.pid"
        original = pidfile.read_text()
        pid = int(original.split()[0])
        try:
            pidfile.write_text(f"{pid} 0\n")
            self.assertEqual(self.run_script("start-stop-status", "status", check=False).returncode, 3)
            self.run_script("start-stop-status", "stop")
            os.kill(pid, 0)
        finally:
            pidfile.write_text(original)

    def test_packaged_agent_reports_to_mock_panel(self):
        if not self.real_agent:
            self.skipTest("set KOMARI_TEST_AGENT for actual agent integration")
        from mock_komari_smoke import SmokeServer, SmokeState, make_handler
        state = SmokeState("test-token", 2)
        server = SmokeServer(("127.0.0.1", 0), make_handler(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.env["wizard_endpoint"] = f"http://127.0.0.1:{server.server_address[1]}"
            self.install()
            config = json.loads(self.config.read_text())
            config.update(custom_ipv4="203.0.113.1", custom_ipv6="2001:db8::1", reconnect_interval=1)
            self.config.write_text(json.dumps(config))
            self.run_script("start-stop-status", "start")
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if state.error or all(event.is_set() for event in (state.upload_seen, state.report_seen, state.pong_seen)):
                    break
                time.sleep(.05)
            self.assertIsNone(state.error)
            for event in (state.upload_seen, state.report_seen, state.pong_seen):
                self.assertTrue(event.is_set(), (self.tmp / "agent.log").read_text())
            telemetry = json.loads((self.tmp / "status.json").read_text())
            self.assertGreater(telemetry["reports_sent"], 0)
            self.assertEqual(telemetry["http_reports_confirmed"], 0)
            self.assertGreater(telemetry["basic_info_confirmed_at"], 0)
            self.assertNotIn("test-token", json.dumps(telemetry))
        finally:
            self.run_script("start-stop-status", "stop")
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_start_failure_is_reported(self):
        self.install()
        self.agent.write_text("#!/bin/sh\nexit 42\n")
        result = self.run_script("start-stop-status", "start", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited during startup", result.stderr)
        self.assertFalse((self.tmp / "agent.pid").exists())

    def test_http_confirmation_and_failed_report_status(self):
        if not self.real_agent:
            self.skipTest("set KOMARI_TEST_AGENT for actual agent integration")
        from mock_komari_smoke import SmokeServer, SmokeState, make_handler
        state = SmokeState("test-token", 2)
        reject_reports = threading.Event()

        class HttpOnly(make_handler(state)):
            def do_GET(self):
                self._send(503, b"websocket unavailable")

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
                request = json.loads(body)
                if request["method"] == "agent.report" and reject_reports.is_set():
                    self._send(200, b'{"jsonrpc":"2.0","error":{"code":-32000,"message":"private-server-error"}}')
                else:
                    self._send(200, b'{"jsonrpc":"2.0","result":{"status":"ok"}}')

        server = SmokeServer(("127.0.0.1", 0), HttpOnly)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def wait_status(predicate):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                status = json.loads((self.tmp / "status.json").read_text())
                if predicate(status):
                    return status
                time.sleep(.05)
            self.fail((self.tmp / "agent.log").read_text())

        try:
            self.env["wizard_endpoint"] = f"http://127.0.0.1:{server.server_address[1]}"
            self.install()
            cfg = json.loads(self.config.read_text())
            cfg.update(custom_ipv4="203.0.113.1", custom_ipv6="2001:db8::1", max_retries=0,
                       reconnect_interval=1, interval=.2)
            self.config.write_text(json.dumps(cfg))
            self.run_script("start-stop-status", "start")
            status = wait_status(lambda s: s["http_reports_confirmed"] > 0)
            self.assertEqual(status["reports_sent"], status["http_reports_confirmed"])
            self.assertEqual(status["transport"], "http")
            self.assertGreater(status["last_http_confirmed_at"], 0)
            reject_reports.set()
            failed = wait_status(lambda s: s["last_error"] == "InvalidV2Response")
            self.assertEqual(failed["connection"], "reconnecting")
            self.assertNotIn("private-server-error", json.dumps(failed))
            self.assertNotIn("test-token", json.dumps(failed))
            confirmed = failed["http_reports_confirmed"]
            time.sleep(.3)
            self.assertEqual(json.loads((self.tmp / "status.json").read_text())["http_reports_confirmed"], confirmed)
        finally:
            self.run_script("start-stop-status", "stop")
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_uninstall_only_removes_package_settings(self):
        self.install()
        state = self.var / "state/net_static.json"
        state.write_text("state")
        outside = self.root / "unrelated"
        outside.write_text("keep")
        self.env["SYNOPKG_PKG_STATUS"] = "UNINSTALL"
        self.run_script("postuninst")
        self.assertFalse(self.config.exists())
        self.assertFalse(state.exists())
        self.assertEqual(outside.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
