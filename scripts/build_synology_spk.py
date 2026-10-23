#!/usr/bin/env python3
"""Package an existing static Linux agent for DSM 7; Python stdlib only."""
import argparse
import gzip
import io
import json
from pathlib import Path
import re
import struct
import tarfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "deploy/synology"
# Synology's platform names, not uname or Zig target names.
ARCHES = {
    "amd64": (62, 2, "x86_64"),
    "arm64": (183, 2, "armv8"),
    "arm": (40, 1, "armv7 armada370 armada375 armada38x armadaxp comcerto2k monaco"),
}
PACKAGE = "komari-agent"
PACKAGE_VERSION = "0.2.0"


def validate_binary(data, arch):
    """Reject cross-wired assets and dynamic executables before publishing a package."""
    machine, elf_class, _ = ARCHES[arch]
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4:6] != bytes([elf_class, 1]):
        raise ValueError(f"{arch} requires a little-endian ELF{elf_class * 32} binary")
    if struct.unpack_from("<H", data, 18)[0] != machine:
        raise ValueError(f"ELF machine does not match {arch}")
    if elf_class == 2:
        phoff = struct.unpack_from("<Q", data, 32)[0]
        entsize, count = struct.unpack_from("<HH", data, 54)
        minimum = 56
    else:
        phoff = struct.unpack_from("<I", data, 28)[0]
        entsize, count = struct.unpack_from("<HH", data, 42)
        minimum = 32
    if not count or entsize < minimum or phoff + entsize * count > len(data):
        raise ValueError("Invalid ELF program header table")
    for index in range(count):
        if struct.unpack_from("<I", data, phoff + index * entsize)[0] == 3:
            raise ValueError("DSM packages require a static binary (ELF PT_INTERP found)")


def archive(files):
    """Portable USTAR with explicit UNIX modes, including when built on Windows."""
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        directories = set()
        for name in files:
            directories.update(str(p) for p in Path(name).parents if str(p) != ".")
        for name in sorted(directories):
            member = tarfile.TarInfo(name.replace("\\", "/") + "/")
            member.type = tarfile.DIRTYPE
            member.mode = 0o755
            tar.addfile(member)
        for name, (data, mode) in sorted(files.items()):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            member.mode = mode
            tar.addfile(member, io.BytesIO(data))
    return output.getvalue()


def icon(size):
    """A small code-native monitor/pulse mark, rendered without image dependencies."""
    def segment_distance(x, y, a, b):
        dx, dy = b[0] - a[0], b[1] - a[1]
        t = max(0, min(1, ((x-a[0])*dx + (y-a[1])*dy) / (dx*dx + dy*dy)))
        return ((x-a[0]-t*dx)**2 + (y-a[1]-t*dy)**2)**0.5

    pulse = [(15, 33), (23, 33), (28, 23), (35, 42), (40, 30), (49, 30)]
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            px, py = (x + .5) * 64 / size, (y + .5) * 64 / size
            color = (17, 31, 49, 255)
            if min(px, py, 64-px, 64-py) < 2:
                color = (0, 0, 0, 0)
            if 10 <= px <= 54 and 14 <= py <= 48 and (px < 12 or px > 52 or py < 16 or py > 46):
                color = (220, 233, 241, 255)
            if 29 <= px <= 35 and 48 <= py <= 52 or 23 <= px <= 41 and 52 <= py <= 54:
                color = (220, 233, 241, 255)
            if any(segment_distance(px, py, a, b) <= 1.5 for a, b in zip(pulse, pulse[1:])):
                color = (77, 223, 176, 255)
            rows.extend(color)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def wizard(chinese=False, uninstall=False):
    if uninstall:
        return [{"step_title": "卸载 Komari Agent" if chinese else "Uninstall Komari Agent",
                 "items": [{"desc": "将删除此套件的面板地址、Token 和月流量状态；不会修改面板上的记录。" if chinese else
                            "This removes the package configuration, token and monthly traffic state. Panel records are not changed."}]}]
    fields = [
        ("textfield", "wizard_endpoint", "面板地址" if chinese else "Panel URL", "", "https://panel.example"),
        ("password", "wizard_token", "Agent Token", "", ""),
        ("textfield", "wizard_interval", "上报间隔（秒）" if chinese else "Interval (seconds)", "3", "3"),
    ]
    items = []
    for kind, key, label, default, placeholder in fields:
        validation = {"allowBlank": False}
        if key == "wizard_endpoint":
            validation["regex"] = {"expr": r"/^https?:\/\/[^\s]+$/", "errorText": "Use http:// or https://."}
        if key == "wizard_interval":
            validation["regex"] = {"expr": r"/^[1-9][0-9]{0,4}$/", "errorText": "Use 1-86400 seconds."}
        items.append({"type": kind, "subitems": [{"key": key, "desc": label, "defaultValue": default,
                      "emptyText": placeholder, "validator": validation}]})
    items.append({"desc": "仅上报监控数据，不提供远程执行或 SSH。升级保留配置；重新安装将使用这里的新配置。" if chinese else
                  "Monitoring only; no remote execution or SSH. Upgrades preserve settings; reinstalls use these new settings."})
    return [{"step_title": "连接 Komari 面板" if chinese else "Connect to Komari", "items": items}]


def build(binary, arch, version, build_number, output_dir, cgi=None):
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", version):
        raise ValueError("Invalid agent version")
    if not 1 <= build_number <= 2147483647:
        raise ValueError("Build number must be 1..2147483647")
    data = Path(binary).read_bytes()
    validate_binary(data, arch)
    cgi_data = Path(cgi or Path(binary).with_name("komari-dsm-api.cgi")).read_bytes()
    validate_binary(cgi_data, arch)
    payload_files = {"bin/komari-agent": (data, 0o755), "ui/api.cgi": (cgi_data, 0o755)}
    for path in sorted((TEMPLATE / "ui").rglob("*")):
        if path.is_file():
            payload_files[path.relative_to(TEMPLATE).as_posix()] = (path.read_bytes().replace(b"\r\n", b"\n"), 0o644)
    for size in (16, 24, 32, 48, 64, 72, 256):
        payload_files[f"ui/images/icon_{size}.png"] = (icon(size), 0o644)
    payload = gzip.compress(archive(payload_files), mtime=0)
    info = {
        "package": PACKAGE,
        "displayname": "Komari Minimal Monitor",
        "dsmuidir": "ui",
        "dsmappname": "com.komari.monitor",
        "version": f"{PACKAGE_VERSION}-{build_number}",
        "description": f"Monitoring-only Komari Agent {version}. No remote execution, SSH or self-update.",
        "description_chs": f"仅上报监控数据的 Komari Agent {version}，不提供远程执行、SSH 或自更新。",
        "arch": ARCHES[arch][2],
        "os_min_ver": "7.0-41890",
        "maintainer": "AlisaCat-S",
        "maintainer_url": "https://github.com/AlisaCat-S/komari-zig-agent-without-ssh",
        "support_url": "https://github.com/AlisaCat-S/komari-zig-agent-without-ssh/issues",
        "thirdparty": "yes",
        "beta": "yes",
        "ctl_stop": "yes",
        "startable": "yes",
        "silent_install": "no",
        "silent_upgrade": "yes",
        "silent_uninstall": "no",
    }
    files = {
        "INFO": ("".join(f'{k}="{v}"\n' for k, v in info.items()).encode(), 0o644),
        "package.tgz": (payload, 0o644),
        "LICENSE": ((ROOT / "LICENSE").read_bytes(), 0o644),
        "PACKAGE_ICON.PNG": (icon(64), 0o644),
        "PACKAGE_ICON_256.PNG": (icon(256), 0o644),
    }
    for path in sorted(TEMPLATE.rglob("*")):
        if path.is_file():
            name = path.relative_to(TEMPLATE).as_posix()
            if name.startswith("ui/"):
                continue
            files[name] = (path.read_bytes().replace(b"\r\n", b"\n"), 0o755 if name.startswith("scripts/") else 0o644)
    for chinese, suffix in ((False, ""), (True, "_chs")):
        for uninstall, stage in ((False, "install"), (True, "uninstall")):
            files[f"WIZARD_UIFILES/{stage}_uifile{suffix}"] = (
                (json.dumps(wizard(chinese, uninstall), ensure_ascii=False, indent=2) + "\n").encode(), 0o644)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"komari-agent-dsm7-{arch}.spk"
    output.write_bytes(archive(files))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--cgi", type=Path, help="Matching static CGI; defaults to komari-dsm-api.cgi beside the agent")
    parser.add_argument("--arch", choices=ARCHES, required=True)
    parser.add_argument("--version", required=True, help="Agent version shown in the package description")
    parser.add_argument("--build-number", type=int, required=True, help="Monotonically increasing DSM package revision")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/synology")
    args = parser.parse_args()
    try:
        print(build(args.binary, args.arch, args.version, args.build_number, args.output_dir, args.cgi))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
