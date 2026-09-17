#!/usr/bin/env python3
"""VNM Panel Node Agent.

Small dependency-free HTTP agent for Linux QEMU/KVM hosts.
It manages a local VM inventory in SQLite and exposes authenticated
node/VM lifecycle APIs for the VNM Panel controller.
"""

from __future__ import annotations

import json
import os
import secrets
import signal
import sqlite3
import subprocess
import threading
import time
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

VERSION = "1.0.0"
HOST = os.getenv("VNM_NODE_HOST", "0.0.0.0")
PORT = int(os.getenv("VNM_NODE_PORT", "9090"))
API_KEY = os.getenv("VNM_NODE_API_KEY", "")
DB_PATH = Path(os.getenv("VNM_NODE_DB", "/var/lib/vnm-panel-node/vms.db"))
VM_ROOT = Path(os.getenv("VNM_VM_ROOT", "/var/lib/vnm-panel/vms")).resolve()
LOG_ROOT = Path(os.getenv("VNM_NODE_LOG_DIR", "/var/log/vnm-panel-node")).resolve()

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
LOG_ROOT.mkdir(parents=True, exist_ok=True)
VM_ROOT.mkdir(parents=True, exist_ok=True)

_DB_LOCK = threading.Lock()


def now() -> int:
    return int(time.time())


def run_checked(argv: list[str], timeout: int = 15) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            argv,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, "", str(exc)


def qemu_bin() -> str:
    return os.getenv("VNM_QEMU_BIN", "qemu-system-x86_64")


def init_db() -> None:
    with _DB_LOCK, sqlite3.connect(DB_PATH) as db:
        db.execute(
            """CREATE TABLE IF NOT EXISTS vms (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                memory_mib INTEGER NOT NULL DEFAULT 2048,
                vcpus INTEGER NOT NULL DEFAULT 2,
                disk_path TEXT NOT NULL,
                iso_path TEXT,
                pid INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )"""
        )
        db.commit()


def db_one(query: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
    with _DB_LOCK, sqlite3.connect(DB_PATH) as db:
        db.row_factory = sqlite3.Row
        row = db.execute(query, params).fetchone()
        return dict(row) if row else None


def db_all(query: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    with _DB_LOCK, sqlite3.connect(DB_PATH) as db:
        db.row_factory = sqlite3.Row
        return [dict(r) for r in db.execute(query, params).fetchall()]


def db_write(query: str, params: tuple[Any, ...] = ()) -> None:
    with _DB_LOCK, sqlite3.connect(DB_PATH) as db:
        db.execute(query, params)
        db.commit()


def pid_alive(pid: int | None) -> bool:
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_meminfo() -> tuple[int, int]:
    total = available = 0
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                if parts[0] == "MemTotal:":
                    total = int(parts[1]) * 1024
                elif parts[0] == "MemAvailable:":
                    available = int(parts[1]) * 1024
    except (OSError, ValueError):
        pass
    return total, available


def load_1m() -> float | None:
    try:
        return float(os.getloadavg()[0])
    except (OSError, ValueError):
        return None


def command_exists(name: str) -> bool:
    return run_checked(["/usr/bin/env", "bash", "-lc", f"command -v -- {name}"])[0] == 0


def node_status() -> dict[str, Any]:
    mem_total, mem_available = read_meminfo()
    disk = subprocess.run(
        ["df", "-B1", str(VM_ROOT)], text=True, capture_output=True, check=False
    )
    disk_total = disk_used = disk_free = 0
    try:
        lines = disk.stdout.strip().splitlines()
        if len(lines) >= 2:
            fields = lines[-1].split()
            disk_total, disk_used, disk_free = map(int, fields[1:4])
    except (ValueError, IndexError):
        pass

    qemu_rc, qemu_version, _ = run_checked([qemu_bin(), "--version"], timeout=5)
    vms = db_all("SELECT * FROM vms ORDER BY name COLLATE NOCASE")
    running = 0
    for vm in vms:
        if pid_alive(vm.get("pid")):
            vm["status"] = "running"
            running += 1
        else:
            vm["status"] = "stopped"

    return {
        "agent": "vnm-panel-node-agent",
        "version": VERSION,
        "time": now(),
        "hostname": os.uname().nodename,
        "os": os.uname().sysname,
        "kernel": os.uname().release,
        "arch": os.uname().machine,
        "cpu_count": os.cpu_count() or 1,
        "load_1m": load_1m(),
        "memory": {
            "total_bytes": mem_total,
            "available_bytes": mem_available,
            "used_bytes": max(0, mem_total - mem_available),
        },
        "disk": {
            "path": str(VM_ROOT),
            "total_bytes": disk_total,
            "used_bytes": disk_used,
            "free_bytes": disk_free,
        },
        "kvm": {
            "device": "/dev/kvm",
            "exists": Path("/dev/kvm").exists(),
            "readable": os.access("/dev/kvm", os.R_OK),
            "writable": os.access("/dev/kvm", os.W_OK),
        },
        "qemu": {
            "binary": qemu_bin(),
            "available": qemu_rc == 0,
            "version": qemu_version.splitlines()[0] if qemu_version else None,
        },
        "cloud_localds": command_exists("cloud-localds"),
        "vm_count": len(vms),
        "running_vm_count": running,
        "vms": vms,
    }


def resolve_vm_path(raw: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        path = VM_ROOT / path
    resolved = path.resolve()
    if VM_ROOT not in resolved.parents and resolved != VM_ROOT:
        raise ValueError("Path must stay inside VNM_VM_ROOT")
    return resolved


def vm_from_row(row: dict[str, Any]) -> dict[str, Any]:
    out = dict(row)
    out["status"] = "running" if pid_alive(row.get("pid")) else "stopped"
    out["disk_path"] = str(row["disk_path"])
    if row.get("iso_path"):
        out["iso_path"] = str(row["iso_path"])
    return out


def create_vm(data: dict[str, Any]) -> dict[str, Any]:
    vm_id = str(data.get("id") or secrets.token_hex(8))
    name = str(data.get("name") or vm_id).strip()
    if not name:
        raise ValueError("name is required")
    memory = int(data.get("memory_mib", 2048))
    vcpus = int(data.get("vcpus", 2))
    if memory < 256 or memory > 1048576:
        raise ValueError("memory_mib out of range")
    if vcpus < 1 or vcpus > 256:
        raise ValueError("vcpus out of range")

    disk_path = resolve_vm_path(str(data.get("disk_path") or f"{vm_id}.qcow2"))
    iso = data.get("iso_path")
    iso_path = resolve_vm_path(str(iso)) if iso else None
    disk_path.parent.mkdir(parents=True, exist_ok=True)

    if not disk_path.exists():
        rc, _, err = run_checked(["qemu-img", "create", "-f", "qcow2", str(disk_path), str(data.get("disk_size", "20G"))], 30)
        if rc != 0:
            raise RuntimeError(f"qemu-img create failed: {err}")

    ts = now()
    db_write(
        "INSERT OR REPLACE INTO vms (id,name,memory_mib,vcpus,disk_path,iso_path,pid,created_at,updated_at) VALUES (?,?,?,?,?,?,NULL,COALESCE((SELECT created_at FROM vms WHERE id=?),?),?)",
        (vm_id, name, memory, vcpus, str(disk_path), str(iso_path) if iso_path else None, vm_id, ts, ts),
    )
    return vm_from_row(db_one("SELECT * FROM vms WHERE id=?", (vm_id,)) or {})


def start_vm(vm_id: str) -> dict[str, Any]:
    vm = db_one("SELECT * FROM vms WHERE id=?", (vm_id,))
    if not vm:
        raise KeyError("VM not found")
    if pid_alive(vm.get("pid")):
        return vm_from_row(vm)

    disk = resolve_vm_path(vm["disk_path"])
    if not disk.exists():
        raise FileNotFoundError(f"Disk not found: {disk}")

    logfile = LOG_ROOT / f"{vm_id}.log"
    display = f"none"
    cmd = [
        qemu_bin(),
        "-name", vm["name"],
        "-machine", "q35",
        "-enable-kvm" if Path("/dev/kvm").exists() else "-machine", 
    ]
    # Correct the conditional flag layout without shell parsing.
    if Path("/dev/kvm").exists():
        cmd = [qemu_bin(), "-name", vm["name"], "-machine", "q35", "-enable-kvm"]
    else:
        cmd = [qemu_bin(), "-name", vm["name"], "-machine", "q35"]
    cmd += [
        "-m", str(vm["memory_mib"]),
        "-smp", str(vm["vcpus"]),
        "-drive", f"file={disk},if=virtio,format=qcow2",
        "-display", display,
        "-serial", "none",
        "-monitor", "none",
        "-daemonize",
        "-pidfile", str(LOG_ROOT / f"{vm_id}.pid"),
        "-D", str(logfile),
    ]
    if vm.get("iso_path"):
        iso = resolve_vm_path(vm["iso_path"])
        if not iso.exists():
            raise FileNotFoundError(f"ISO not found: {iso}")
        cmd += ["-cdrom", str(iso), "-boot", "order=d"]

    rc, out, err = run_checked(cmd, 30)
    if rc != 0:
        raise RuntimeError(err or out or "QEMU failed to start")

    pid_file = LOG_ROOT / f"{vm_id}.pid"
    pid = int(pid_file.read_text().strip()) if pid_file.exists() else None
    if not pid or not pid_alive(pid):
        raise RuntimeError("QEMU exited before becoming available")
    db_write("UPDATE vms SET pid=?,updated_at=? WHERE id=?", (pid, now(), vm_id))
    return vm_from_row(db_one("SELECT * FROM vms WHERE id=?", (vm_id,)) or {})


def stop_vm(vm_id: str, force: bool = False) -> dict[str, Any]:
    vm = db_one("SELECT * FROM vms WHERE id=?", (vm_id,))
    if not vm:
        raise KeyError("VM not found")
    pid = vm.get("pid")
    if not pid_alive(pid):
        db_write("UPDATE vms SET pid=NULL,updated_at=? WHERE id=?", (now(), vm_id))
        return vm_from_row(db_one("SELECT * FROM vms WHERE id=?", (vm_id,)) or {})

    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.time() + 10
    while time.time() < deadline and pid_alive(pid):
        time.sleep(0.2)
    if pid_alive(pid) and force:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    if pid_alive(pid):
        raise RuntimeError("VM did not stop")
    db_write("UPDATE vms SET pid=NULL,updated_at=? WHERE id=?", (now(), vm_id))
    return vm_from_row(db_one("SELECT * FROM vms WHERE id=?", (vm_id,)) or {})


class Handler(BaseHTTPRequestHandler):
    server_version = "VNMPanelNodeAgent/" + VERSION

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {fmt % args}")

    def authenticated(self) -> bool:
        supplied = self.headers.get("X-VNM-Node-Key", "")
        return bool(API_KEY) and secrets.compare_digest(supplied, API_KEY)

    def json(self, status: int, payload: Any) -> None:
        raw = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length > 2 * 1024 * 1024:
            raise ValueError("request body too large")
        raw = self.rfile.read(length)
        return json.loads(raw or b"{}")

    def do_GET(self) -> None:
        if self.path == "/health":
            self.json(200, {"ok": True, "agent": "vnm-panel-node-agent", "version": VERSION})
            return
        if not self.authenticated():
            self.json(401, {"error": "unauthorized"})
            return
        path = urllib.parse.urlsplit(self.path).path
        try:
            if path == "/api/v1/status":
                self.json(200, node_status())
            elif path == "/api/v1/vms":
                self.json(200, {"vms": [vm_from_row(r) for r in db_all("SELECT * FROM vms ORDER BY name COLLATE NOCASE")]})
            elif path.startswith("/api/v1/vms/"):
                vm_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
                vm = db_one("SELECT * FROM vms WHERE id=?", (vm_id,))
                if not vm:
                    self.json(404, {"error": "vm_not_found"})
                else:
                    self.json(200, vm_from_row(vm))
            else:
                self.json(404, {"error": "not_found"})
        except Exception as exc:
            self.json(500, {"error": str(exc)})

    def do_POST(self) -> None:
        if not self.authenticated():
            self.json(401, {"error": "unauthorized"})
            return
        path = urllib.parse.urlsplit(self.path).path
        try:
            data = self.body()
            if path == "/api/v1/vms":
                self.json(201, create_vm(data))
                return
            parts = [urllib.parse.unquote(p) for p in path.split("/")]
            if len(parts) >= 6 and parts[1:4] == ["api", "v1", "vms"]:
                vm_id, action = parts[4], parts[5]
                if action == "start":
                    self.json(200, start_vm(vm_id))
                    return
                if action == "stop":
                    self.json(200, stop_vm(vm_id, bool(data.get("force"))))
                    return
                if action == "reboot":
                    stop_vm(vm_id)
                    self.json(200, start_vm(vm_id))
                    return
            self.json(404, {"error": "not_found"})
        except KeyError as exc:
            self.json(404, {"error": str(exc)})
        except (ValueError, FileNotFoundError) as exc:
            self.json(400, {"error": str(exc)})
        except Exception as exc:
            self.json(500, {"error": str(exc)})

    def do_DELETE(self) -> None:
        if not self.authenticated():
            self.json(401, {"error": "unauthorized"})
            return
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/api/v1/vms/"):
            vm_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
            try:
                stop_vm(vm_id, force=True)
            except KeyError:
                self.json(404, {"error": "vm_not_found"})
                return
            db_write("DELETE FROM vms WHERE id=?", (vm_id,))
            self.json(200, {"ok": True, "deleted": vm_id})
            return
        self.json(404, {"error": "not_found"})


def main() -> None:
    if not API_KEY:
        raise SystemExit("VNM_NODE_API_KEY must be set")
    init_db()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"VNM Panel Node Agent {VERSION} listening on {HOST}:{PORT}")
    print(f"VM root: {VM_ROOT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
