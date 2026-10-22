#!/usr/bin/env python3
"""Exercise the real POSIX installer with isolated paths and fake release/service I/O."""
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install.sh").read_text()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="komari-installer-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mock = self.root / "mock"
        self.mock.mkdir()
        self.events = self.root / "events"
        self.events.touch()
        self.release = self.root / "release"
        self.release.mkdir()
        self.asset = "komari-agent-linux-amd64"
        (self.release / self.asset).write_text("new Zig agent")
        (self.release / "config.json.example").write_bytes((ROOT / "deploy/config.json.example").read_bytes())
        (self.release / "komari-agent.service").write_bytes((ROOT / "deploy/komari-agent.service").read_bytes())
        self.refresh_sums()
        # Only the test copy changes paths and external commands; installer logic is unchanged.
        source = SOURCE
        for prefix in ("/usr/local/", "/usr/bin/", "/etc/", "/var/", "/opt/", "/run/"):
            source = source.replace(prefix, str(self.root) + prefix)
        start = source.index("PATH=")
        end = source.index("\n", start)
        source = source[:start] + f"PATH={shlex.quote(str(self.mock))}:/usr/bin:/bin" + source[end:]
        self.script = self.root / "install.sh"
        self.script.write_text(source)
        self.unit = self.root / "etc/systemd/system/komari-agent.service"
        self.unit.parent.mkdir(parents=True)
        (self.root / "run/systemd/system").mkdir(parents=True)
        (self.root / "etc/group").write_text("komari:x:123:\n")
        self.config = self.root / "etc/komari-agent/config.json"
        self.binary = self.root / "usr/local/bin/komari-agent"
        self.legacy = self.root / "opt/komari/agent"
        self.command("uname", 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac')
        self.command("id", 'echo 0')
        self.command("chown", ':')
        self.command("systemctl", f'echo "systemctl $*" >> {shlex.quote(str(self.events))}\n'
                     'if [ "$1" = stop ] && [ "${FAIL_STOP:-}" = 1 ]; then exit 1; fi')
        self.command("curl", f'''
echo "download" >> {shlex.quote(str(self.events))}
while [ "$#" -gt 0 ]; do
  case "$1" in --output) out=$2; shift 2 ;; *) url=$1; shift ;; esac
done
cp {shlex.quote(str(self.release))}/"${{url##*/}}" "$out"
''')

    def command(self, name, body):
        path = self.mock / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def refresh_sums(self):
        # Required release-integrity fixtures, including deliberate corruption tests.
        (self.release / "SHA256SUMS").write_text("".join(
            hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n"
            for p in sorted(self.release.iterdir()) if p.name != "SHA256SUMS"))

    def run_installer(self, *args, answer=None, extra_env=None, pipe=False):
        command = ["sh", str(self.script), *args]
        if pipe:
            command = ["sh", "-c", f"cat {shlex.quote(str(self.script))} | " + shlex.join(["sh", "-s", "--", *args])]
        env = dict(os.environ, **(extra_env or {}))
        if answer is None:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                    text=True, env=env, start_new_session=True, timeout=15)
            return result.returncode, result.stdout + result.stderr
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(command[0], command, env)
        output = b""
        sent = False
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        data = os.read(fd, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output += data
                    if b"[y/N]" in output and not sent:
                        os.write(fd, answer.encode() + b"\n")
                        sent = True
            else:
                os.kill(pid, 9)
                self.fail("installer timed out")
        finally:
            os.close(fd)
            _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode()

    def old_agent(self):
        self.legacy.parent.mkdir(parents=True)
        self.legacy.write_text("official agent")
        self.unit.write_text(f"ExecStart={self.legacy} -e https://old -t old\n")

    def test_fresh_one_click_and_escaping(self):
        token = 'quotes" backslash\\ newline\n tab\t $(touch NOT_EXECUTED) \x01'
        code, output = self.run_installer("--endpoint=https://panel.example", "-t", token,
                                          "-i", "0.5", "--gpu", "--debug-log=false")
        self.assertEqual(code, 0, output)
        config = json.loads(self.config.read_text())
        self.assertEqual(config["token"], token)
        self.assertEqual(config["interval"], 0.5)
        self.assertTrue(config["enable_gpu"])
        self.assertFalse(config["debug_log"])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertIn("enable --now komari-agent.service", self.events.read_text())
        self.assertNotIn(token, self.unit.read_text() + output)

    def test_manual_install_does_not_start(self):
        code, output = self.run_installer()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.config.read_bytes(), (self.release / "config.json.example").read_bytes())
        self.assertNotIn("enable --now", self.events.read_text())

    def test_upgrade_preserves_other_fields_and_last_option_wins(self):
        self.config.parent.mkdir()
        self.config.write_text(json.dumps({"endpoint": "old", "token": "old-token", "interval": 3, "auto_discovery_key": "old-key",
                                           "future": {"nested": ["comma,brace}quote\"", 1]}}))
        self.unit.write_text(f"ExecStart={self.binary} --config {self.config}\n")
        code, output = self.run_installer("-e", "new", "-t", "first", "--token=last")
        self.assertEqual(code, 0, output)
        data = json.loads(self.config.read_text())
        self.assertEqual(data["token"], "last")
        self.assertEqual(data["auto_discovery_key"], "")
        self.assertEqual(data["interval"], 3)
        self.assertEqual(data["future"]["nested"][0], 'comma,brace}quote"')

    def test_bad_options_do_not_mutate_system(self):
        for args in [("-e",), ("-e", "url"), ("-e=",), ("--interval", "0"),
                     ("--interval=NaN",), ("--max-retries=01",), ("--protocol-version=3",),
                     ("--prefer-ip-version=5",), ("--gpu=maybe",), ("--disable-web-ssh",),
                     ("--install-ghproxy=x",), ("--install-version=bad",)]:
            with self.subTest(args=args):
                code, _ = self.run_installer(*args)
                self.assertNotEqual(code, 0)
                self.assertFalse(self.config.exists())
                self.assertEqual(self.events.read_text(), "")

    def test_refusal_and_no_tty_leave_official_untouched(self):
        self.old_agent()
        original = self.unit.read_text()
        for answer in (None, "", "n"):
            code, output = self.run_installer("-e", "url", "-t", "token", answer=answer)
            self.assertEqual(code, 1 if answer is None else 0, output)
            self.assertEqual(self.legacy.read_text(), "official agent")
            self.assertEqual(self.unit.read_text(), original)
            self.assertEqual(self.events.read_text(), "")

    def test_confirmed_replacement_backs_up_then_starts(self):
        self.old_agent()
        code, output = self.run_installer("-e", "url", "-t", "token", answer="yes", pipe=True)
        self.assertEqual(code, 0, output)
        backups = list(self.config.parent.glob("previous-agent.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "agent").read_text(), "official agent")
        self.assertIn(str(self.legacy), (backups[0] / "service").read_text())
        self.assertIn(f"agent={self.legacy}", (backups[0] / "restore-paths.txt").read_text())
        self.assertFalse(self.legacy.exists())
        self.assertEqual(self.binary.read_text(), "new Zig agent")
        events = self.events.read_text()
        self.assertLess(events.rindex("download"), events.index("systemctl stop"))
        self.assertIn("systemctl disable", events)
        self.assertIn("enable --now", events)

    def test_corrupt_download_does_not_stop_official(self):
        self.old_agent()
        (self.release / self.asset).write_text("corrupted")
        code, output = self.run_installer("-e", "url", "-t", "token", answer="y")
        self.assertNotEqual(code, 0, output)
        self.assertIn("verification failed", output)
        self.assertNotIn("systemctl", self.events.read_text())
        self.assertEqual(self.legacy.read_text(), "official agent")

    def test_stop_failure_keeps_legacy_files(self):
        self.old_agent()
        code, output = self.run_installer("-e", "url", "-t", "token", answer="y", extra_env={"FAIL_STOP": "1"})
        self.assertNotEqual(code, 0, output)
        self.assertTrue(self.legacy.exists())
        self.assertIn(str(self.legacy), self.unit.read_text())
        self.assertNotIn("systemctl disable", self.events.read_text())

    def test_existing_config_without_options_is_byte_preserved(self):
        self.config.parent.mkdir()
        data = b'{ "endpoint":"url", "token":"token", "interval":2 }\n'
        self.config.write_bytes(data)
        self.unit.write_text(f"ExecStart={self.binary} --config {self.config}\n")
        code, output = self.run_installer()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.config.read_bytes(), data)
        self.assertIn("enable --now", self.events.read_text())

    def test_other_linux_init_systems_start_on_fresh_config(self):
        for init in ("openrc", "procd", "upstart"):
            with self.subTest(init=init):
                # Each subcase has its own sandbox to avoid treating the prior unit as legacy.
                sandbox = InstallerTests()
                sandbox.setUp()
                try:
                    text = sandbox.script.read_text().replace('INIT_SYSTEM="$(detect_linux_init)"', f'INIT_SYSTEM={init}')
                    sandbox.script.write_text(text)
                    (sandbox.root / "etc/init.d").mkdir()
                    (sandbox.root / "etc/init").mkdir()
                    for cmd in ("rc-service", "rc-update", "initctl"):
                        sandbox.command(cmd, f'echo "{cmd} $*" >> {shlex.quote(str(sandbox.events))}')
                    if init == "procd":
                        # Execute the generated init script with a stub rc.common interpreter.
                        rc_common = sandbox.root / "etc/rc.common"
                        rc_common.write_text(f'#!/bin/sh\necho "procd $*" >> {shlex.quote(str(sandbox.events))}\n')
                        rc_common.chmod(0o755)
                    code, output = sandbox.run_installer("-e", "url", "-t", "token")
                    self.assertEqual(code, 0, output)
                    unit = sandbox.root / ("etc/init/komari-agent.conf" if init == "upstart" else "etc/init.d/komari-agent")
                    self.assertIn(str(sandbox.config), unit.read_text())
                    self.assertNotIn("token", unit.read_text())
                    if init == "procd":
                        self.assertIn('--state-dir "' + str(sandbox.root / "var/lib/komari-agent") + '"', unit.read_text())
                    self.assertEqual(json.loads(sandbox.config.read_text())["token"], "token")
                finally:
                    sandbox.doCleanups()


if __name__ == "__main__":
    unittest.main(verbosity=2)
