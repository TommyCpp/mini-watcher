import asyncio
import os
import socket
import platform
import sqlite3
import time
from datetime import datetime, timezone

import psutil
import plistlib
import glob
import subprocess
import threading
import docker
import docker.errors
from contextlib import asynccontextmanager
from fastapi import FastAPI, Query, HTTPException
from fastapi.middleware.cors import CORSMiddleware

# Background CPU sampling state
_cpu_percent_per_core: list[float] = []
_cpu_percent_overall: float = 0.0

DB_PATH = os.path.join(os.path.dirname(__file__), "history.db")

# Net IO state for bytes/s calculation
_prev_net_io = None
_prev_net_ts: float = 0.0


def init_db():
    with sqlite3.connect(DB_PATH) as con:
        con.execute("""
            CREATE TABLE IF NOT EXISTS metrics_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                cpu_percent REAL NOT NULL,
                memory_percent REAL NOT NULL,
                net_bytes_recv_ps REAL NOT NULL,
                net_bytes_sent_ps REAL NOT NULL
            )
        """)
        con.execute("CREATE INDEX IF NOT EXISTS idx_ts ON metrics_history(ts)")


def insert_sample(ts: float, cpu: float, mem: float, recv_ps: float, sent_ps: float):
    with sqlite3.connect(DB_PATH) as con:
        con.execute(
            "INSERT INTO metrics_history (ts, cpu_percent, memory_percent, net_bytes_recv_ps, net_bytes_sent_ps) VALUES (?,?,?,?,?)",
            (ts, cpu, mem, recv_ps, sent_ps),
        )
        # Purge data older than 7 days
        cutoff = ts - 7 * 24 * 3600
        con.execute("DELETE FROM metrics_history WHERE ts < ?", (cutoff,))


RANGE_SECONDS = {
    "10m": 600,
    "1h": 3600,
    "2h": 7200,
    "6h": 21600,
    "12h": 43200,
    "1d": 86400,
    "3d": 259200,
    "7d": 604800,
}

PROTECTED_LABELS = {"com.miniwatcher.server"}
_INVALID_SESSION_CHARS = frozenset("/\x00\n")
_proc_cpu_cache: dict = {}

# Docker/Podman state
_docker_client = None
_podman_client = None
_docker_cache: dict = {"available": False, "containers": []}
_docker_refresh_lock = threading.Lock()


def _try_connect(url: str):
    """Return a connected DockerClient for url, or None."""
    try:
        client = docker.DockerClient(base_url=url, timeout=3)
        client.ping()
        return client
    except Exception:
        return None


def _connect_docker():
    """Connect to Docker daemon. Respects DOCKER_HOST env var."""
    if os.environ.get("DOCKER_HOST"):
        return _try_connect(os.environ["DOCKER_HOST"])
    return _try_connect("unix:///var/run/docker.sock")


def _connect_podman():
    """Connect to Podman daemon. Respects PODMAN_HOST env var."""
    if os.environ.get("PODMAN_HOST"):
        return _try_connect(os.environ["PODMAN_HOST"])
    uid = os.getuid() if hasattr(os, "getuid") else 0
    for url in [
        f"unix:///run/user/{uid}/podman/podman.sock",  # rootless Linux
        os.path.expanduser(
            "~/.local/share/containers/podman/machine/podman-machine-default/podman.sock"
        ),  # Podman machine macOS
    ]:
        client = _try_connect(url)
        if client:
            return client
    return None


def _calc_cpu(stats: dict) -> float:
    cpu_delta = (
        stats["cpu_stats"]["cpu_usage"]["total_usage"]
        - stats["precpu_stats"]["cpu_usage"]["total_usage"]
    )
    system_delta = (
        stats["cpu_stats"].get("system_cpu_usage", 0)
        - stats["precpu_stats"].get("system_cpu_usage", 0)
    )
    num_cpus = (
        stats["cpu_stats"].get("online_cpus")
        or len(stats["cpu_stats"]["cpu_usage"].get("percpu_usage", []))
        or os.cpu_count()
        or 1
    )
    return round((cpu_delta / system_delta * num_cpus * 100), 1) if system_delta > 0 else 0.0


def _container_info(c, runtime: str) -> dict:
    name = c.name.lstrip("/")
    image = c.image.tags[0] if c.image.tags else c.image.short_id

    if c.status == "running":
        stats = c.stats(stream=False)
        cpu_percent = _calc_cpu(stats)
        mem_usage = stats["memory_stats"].get("usage", 0)
        mem_limit = stats["memory_stats"].get("limit", 0)
    else:
        cpu_percent = 0.0
        mem_usage = 0
        mem_limit = c.attrs["HostConfig"].get("Memory", 0)

    if mem_limit == 0:
        mem_limit = psutil.virtual_memory().total

    memory_mb = round(mem_usage / (1024 ** 2), 1)
    memory_limit_mb = round(mem_limit / (1024 ** 2), 1)
    memory_percent = round(mem_usage / mem_limit * 100, 1) if mem_limit > 0 else 0.0

    return {
        "id": c.id,
        "name": name,
        "image": image,
        "status": c.status,
        "cpu_percent": cpu_percent,
        "memory_mb": memory_mb,
        "memory_limit_mb": memory_limit_mb,
        "memory_percent": memory_percent,
        "runtime": runtime,
    }


def _collect_containers(client, runtime: str) -> list:
    """Fetch and serialize all containers from one runtime client."""
    if client is None:
        return []
    try:
        containers = client.containers.list(all=True)
    except Exception:
        return []
    result = []
    for c in containers:
        try:
            result.append(_container_info(c, runtime))
        except Exception:
            continue
    return result


def _do_refresh():
    global _docker_cache
    docker_containers = _collect_containers(_docker_client, "docker")
    podman_containers = _collect_containers(_podman_client, "podman")
    all_containers = docker_containers + podman_containers
    available = _docker_client is not None or _podman_client is not None
    _docker_cache = {"available": available, "containers": all_containers}


def _refresh_docker():
    """Thread-safe wrapper. Skips if a previous refresh is still running."""
    if not _docker_refresh_lock.acquire(blocking=False):
        return
    try:
        _do_refresh()
    finally:
        _docker_refresh_lock.release()


def _get_launchctl_list() -> dict:
    result = subprocess.run(["launchctl", "list"], capture_output=True, text=True)
    services = {}
    for line in result.stdout.strip().split("\n")[1:]:
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        pid_str, status_str, label = parts
        pid = int(pid_str) if pid_str != "-" else None
        try:
            exit_code = int(status_str)
        except ValueError:
            exit_code = 0
        services[label] = (pid, exit_code)
    return services


def _get_tmux_sessions() -> dict:
    """Return tmux session list. Handles not-installed, no-server, and zero-sessions cases."""
    try:
        result = subprocess.run(
            ["tmux", "ls", "-F",
             "#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}"],
            capture_output=True, text=True,
        )
    except FileNotFoundError:
        return {"available": False, "sessions": []}

    if result.returncode != 0:
        # tmux installed but no server/sessions running
        return {"available": True, "sessions": []}

    if not result.stdout.strip():
        return {"available": True, "sessions": []}

    sessions = []
    for line in result.stdout.strip().split("\n"):
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        name, windows_str, created_str, attached_str = parts
        try:
            sessions.append({
                "name": name,
                "windows": int(windows_str),
                "created": int(created_str),
                "attached": attached_str == "1",
            })
        except ValueError:
            continue

    return {"available": True, "sessions": sessions}


def _read_user_plists() -> list:
    dirs = [
        os.path.expanduser("~/Library/LaunchAgents"),
        "/Library/LaunchDaemons",
    ]
    results = []
    for d in dirs:
        for path in glob.glob(os.path.join(d, "*.plist")):
            try:
                with open(path, "rb") as f:
                    data = plistlib.load(f)
                source = "LaunchDaemons" if "LaunchDaemons" in path else "LaunchAgents"
                results.append((source, data))
            except Exception:
                continue
    return results


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Sample CPU usage every 2s in the background so /metrics doesn't block.
    Also sample history every 10s for storage."""
    init_db()

    psutil.cpu_percent(percpu=True)  # prime the first reading

    # Initialize Docker and Podman clients independently
    global _docker_client, _podman_client
    _docker_client = _connect_docker()
    _podman_client = _connect_podman()

    # Eager first refresh so /docker is populated before serving requests
    await asyncio.to_thread(_refresh_docker)  # non-blocking; called before yield

    global _prev_net_io, _prev_net_ts
    _prev_net_io = psutil.net_io_counters()
    _prev_net_ts = time.time()

    async def _sampler():
        global _cpu_percent_per_core, _cpu_percent_overall, _prev_net_io, _prev_net_ts
        iteration = 0
        while True:
            await asyncio.sleep(2)
            _cpu_percent_per_core = psutil.cpu_percent(percpu=True)
            _cpu_percent_overall = (
                sum(_cpu_percent_per_core) / len(_cpu_percent_per_core)
                if _cpu_percent_per_core
                else 0.0
            )

            # Refresh Docker stats on every sampler tick
            await asyncio.to_thread(_refresh_docker)

            # Every 5 iterations (~10s), record a history sample
            iteration += 1
            if iteration % 5 == 0:
                now = time.time()
                net_io = psutil.net_io_counters()
                elapsed = now - _prev_net_ts
                if elapsed > 0 and _prev_net_io is not None:
                    recv_ps = (net_io.bytes_recv - _prev_net_io.bytes_recv) / elapsed
                    sent_ps = (net_io.bytes_sent - _prev_net_io.bytes_sent) / elapsed
                else:
                    recv_ps = sent_ps = 0.0
                _prev_net_io = net_io
                _prev_net_ts = now

                mem_percent = psutil.virtual_memory().percent
                insert_sample(now, _cpu_percent_overall, mem_percent, max(0, recv_ps), max(0, sent_ps))

    task = asyncio.create_task(_sampler())
    _print_network_info()
    yield
    task.cancel()


app = FastAPI(title="Mini-Watcher Server", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def _print_network_info():
    """Print local/VPN IPs on startup for easy discovery."""
    print(f"\n{'='*50}")
    print(f"  Mini-Watcher Server")
    print(f"  Hostname: {socket.gethostname()}")
    print(f"  Listening on 0.0.0.0:8085")
    print(f"\n  Available interfaces:")
    for name, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family == socket.AF_INET and not addr.address.startswith("127."):
                print(f"    {name}: {addr.address}")
    print(f"{'='*50}\n")


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/tmux")
async def get_tmux():
    return _get_tmux_sessions()


@app.post("/tmux/{session}/kill")
async def kill_tmux_session(session: str):
    if any(c in _INVALID_SESSION_CHARS for c in session):
        raise HTTPException(status_code=400, detail="Invalid session name")
    result = subprocess.run(
        ["tmux", "kill-session", "-t", session],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=result.stderr.strip() or "Failed to kill session",
        )
    return {"success": True}


@app.get("/metrics")
async def metrics():
    # CPU
    load1, load5, load15 = psutil.getloadavg()
    cpu = {
        "usage_percent": round(_cpu_percent_overall, 1),
        "core_count": psutil.cpu_count(logical=True),
        "per_core_percent": _cpu_percent_per_core,
        "load_avg_1m": round(load1, 2),
        "load_avg_5m": round(load5, 2),
        "load_avg_15m": round(load15, 2),
    }

    # Memory
    mem = psutil.virtual_memory()
    memory = {
        "total_gb": round(mem.total / (1024 ** 3), 2),
        "used_gb": round(mem.used / (1024 ** 3), 2),
        "available_gb": round(mem.available / (1024 ** 3), 2),
        "usage_percent": mem.percent,
    }

    # Disk — on macOS, "/" is the read-only system volume; user data is on the Data volume
    disk_path = "/System/Volumes/Data" if platform.system() == "Darwin" else "/"
    disk = psutil.disk_usage(disk_path)
    disk_info = {
        "total_gb": round(disk.total / (1024 ** 3), 2),
        "used_gb": round(disk.used / (1024 ** 3), 2),
        "free_gb": round(disk.free / (1024 ** 3), 2),
        "usage_percent": round(disk.percent, 1),
    }

    # Processes — top 30 by CPU
    procs = []
    running = sleeping = 0
    for p in psutil.process_iter(["pid", "name", "cpu_percent", "memory_percent", "memory_info", "status"]):
        try:
            info = p.info
            status = info.get("status", "")
            if status == psutil.STATUS_RUNNING:
                running += 1
            elif status == psutil.STATUS_SLEEPING:
                sleeping += 1
            mem_mb = (info["memory_info"].rss / (1024 ** 2)) if info.get("memory_info") else 0
            procs.append({
                "pid": info["pid"],
                "name": info["name"] or "unknown",
                "cpu_percent": round(info.get("cpu_percent") or 0, 1),
                "memory_percent": round(info.get("memory_percent") or 0, 1),
                "memory_mb": round(mem_mb, 1),
            })
        except (psutil.AccessDenied, psutil.NoSuchProcess):
            continue

    procs.sort(key=lambda p: p["cpu_percent"], reverse=True)
    total_procs = len(procs)
    procs = procs[:30]

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "hostname": platform.node(),
        "cpu": cpu,
        "memory": memory,
        "disk": disk_info,
        "processes": procs,
        "process_summary": {
            "total": total_procs,
            "running": running,
            "sleeping": sleeping,
        },
    }


@app.get("/history")
async def history(time_range: str = Query(default="1h", alias="range")):
    seconds = RANGE_SECONDS.get(time_range, 3600)
    since = time.time() - seconds

    with sqlite3.connect(DB_PATH) as con:
        rows = con.execute(
            "SELECT ts, cpu_percent, memory_percent, net_bytes_recv_ps, net_bytes_sent_ps "
            "FROM metrics_history WHERE ts >= ? ORDER BY ts ASC",
            (since,),
        ).fetchall()

    # Downsample to at most 200 points
    max_points = 200
    if len(rows) > max_points:
        step = len(rows) / max_points
        rows = [rows[int(i * step)] for i in range(max_points)]

    return [
        {
            "ts": row[0],
            "cpu": round(row[1], 1),
            "memory": round(row[2], 1),
            "net_in": round(row[3], 1),
            "net_out": round(row[4], 1),
        }
        for row in rows
    ]


@app.get("/docker")
async def get_docker():
    return _docker_cache


def _runtime_client(runtime: str):
    """Return the client for the given runtime name, or raise 503."""
    if runtime == "podman":
        client = _podman_client
        label = "Podman"
    else:
        client = _docker_client
        label = "Docker"
    if client is None:
        raise HTTPException(status_code=503, detail=f"{label} is not available")
    return client


@app.post("/docker/{container_id}/start")
async def docker_start(container_id: str, runtime: str = Query("docker")):
    client = _runtime_client(runtime)
    try:
        client.containers.get(container_id).start()
        return {"ok": True}
    except docker.errors.NotFound as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/docker/{container_id}/stop")
async def docker_stop(container_id: str, runtime: str = Query("docker")):
    client = _runtime_client(runtime)
    try:
        client.containers.get(container_id).stop()
        return {"ok": True}
    except docker.errors.NotFound as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/docker/{container_id}/restart")
async def docker_restart(container_id: str, runtime: str = Query("docker")):
    client = _runtime_client(runtime)
    try:
        client.containers.get(container_id).restart()
        return {"ok": True}
    except docker.errors.NotFound as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/services")
async def get_services():
    launchctl = _get_launchctl_list()
    plists = _read_user_plists()

    result = []
    for source, plist in plists:
        label = plist.get("Label", "")
        if not label or label.startswith("com.apple.") or label.startswith("application.com.apple."):
            continue

        pid, exit_code = launchctl.get(label, (None, 0))

        program_args = plist.get("ProgramArguments", [])
        program = plist.get("Program") or (program_args[0] if program_args else "")
        program = os.path.basename(program)

        keep_alive_val = plist.get("KeepAlive", False)
        keep_alive = bool(keep_alive_val)
        run_at_load = bool(plist.get("RunAtLoad", False))

        cpu_percent = None
        memory_mb = None
        uptime_seconds = None

        if pid is not None:
            try:
                if pid not in _proc_cpu_cache:
                    _proc_cpu_cache[pid] = psutil.Process(pid)
                    _proc_cpu_cache[pid].cpu_percent(interval=None)
                proc = _proc_cpu_cache[pid]
                cpu_percent = round(proc.cpu_percent(interval=None), 1)
                memory_mb = round(proc.memory_info().rss / (1024 ** 2), 1)
                uptime_seconds = round(time.time() - proc.create_time())
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                _proc_cpu_cache.pop(pid, None)
                pid = None

        status = "running" if pid is not None else "stopped"

        result.append({
            "label": label,
            "pid": pid,
            "status": status,
            "exit_code": exit_code,
            "cpu_percent": cpu_percent,
            "memory_mb": memory_mb,
            "uptime_seconds": uptime_seconds,
            "keep_alive": keep_alive,
            "run_at_load": run_at_load,
            "program": program,
            "source": source,
        })

    result.sort(key=lambda x: (x["status"] == "stopped", x["label"]))
    return result


@app.post("/services/{label}/start")
async def start_service(label: str):
    if label in PROTECTED_LABELS or label.startswith("com.apple."):
        raise HTTPException(status_code=403, detail="Cannot control this service")
    r = subprocess.run(["launchctl", "start", label], capture_output=True, text=True)
    if r.returncode != 0:
        raise HTTPException(status_code=500, detail=r.stderr.strip() or "Failed to start")
    return {"ok": True}


@app.post("/services/{label}/stop")
async def stop_service(label: str):
    if label in PROTECTED_LABELS or label.startswith("com.apple."):
        raise HTTPException(status_code=403, detail="Cannot control this service")
    r = subprocess.run(["launchctl", "stop", label], capture_output=True, text=True)
    if r.returncode != 0:
        raise HTTPException(status_code=500, detail=r.stderr.strip() or "Failed to stop")
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8085)
