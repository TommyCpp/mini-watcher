# Docker Container Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Docker tab to mini-watcher that shows all containers with CPU % and memory usage, and lets users start, stop, and restart them.

**Architecture:** The Python FastAPI server gains a background refresh loop that caches Docker container stats every 2 seconds (via `run_in_executor` to avoid blocking the async event loop). A new `GET /docker` endpoint serves from that cache instantly. Three `POST /docker/{id}/{action}` endpoints control containers. On the Swift side, `MetricsService` gains two new `@Published` properties fed by a `fetchDocker()` call added to the existing 3-second poll loop; a new `DockerView` reads those properties and renders container rows with action buttons.

**Tech Stack:** Python `docker>=6.0` SDK, `threading.Lock`, FastAPI, Swift/SwiftUI, `async let` concurrency, `@MainActor`-isolated `MetricsService`

**Spec:** `docs/superpowers/specs/2026-03-21-docker-monitoring-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `server/requirements.txt` | Modify | Add `docker>=6.0`, `pytest`, `httpx` |
| `server/main.py` | Modify | Docker globals, helpers, cache, endpoints, sampler hook, lifespan hook |
| `server/tests/__init__.py` | Create | Makes `tests/` a package |
| `server/tests/test_docker.py` | Create | Pytest tests for Docker helpers and endpoints |
| `MiniWatcher/Models/DockerContainer.swift` | Create | `DockerResponse`, `DockerContainer`, `DockerAction` |
| `MiniWatcher/Services/MetricsService.swift` | Modify | `dockerContainers`, `dockerAvailable`, `fetchDocker()`, `controlContainer()`, poll loop update |
| `MiniWatcher/Views/DockerView.swift` | Create | Full Docker tab UI with all states and container rows |
| `MiniWatcher/MiniWatcherApp.swift` | Modify | Insert Docker tab at position 4 |

---

## Task 1: Python test infrastructure and dependency

**Files:**
- Modify: `server/requirements.txt`
- Create: `server/tests/__init__.py`
- Create: `server/tests/test_docker.py`

- [ ] **Step 1: Add dependencies to requirements.txt**

Open `server/requirements.txt` and replace the contents with:

```
fastapi
uvicorn
psutil
docker>=6.0
pytest
httpx
```

- [ ] **Step 2: Install the new dependencies**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server
source venv/bin/activate
pip install -r requirements.txt
```

Expected: all packages install without error. Verify `docker` SDK is available: `python -c "import docker; print(docker.__version__)"` should print a version ≥ 6.0.

- [ ] **Step 3: Create the tests package**

```bash
mkdir -p /Users/zhongyang/Dev/mini-watcher/server/tests
touch /Users/zhongyang/Dev/mini-watcher/server/tests/__init__.py
```

- [ ] **Step 4: Write the failing tests**

Create `server/tests/test_docker.py`:

```python
"""Tests for Docker monitoring endpoints and helpers."""
import os
import sys
from unittest.mock import MagicMock, patch, PropertyMock

import pytest
from fastapi.testclient import TestClient

# Make server/ importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


# ---------------------------------------------------------------------------
# Helper: _calc_cpu
# ---------------------------------------------------------------------------

def test_calc_cpu_normal():
    """CPU percent is computed correctly from Docker stats."""
    from main import _calc_cpu
    stats = {
        "cpu_stats": {
            "cpu_usage": {"total_usage": 2_000_000, "percpu_usage": [1, 1]},
            "system_cpu_usage": 10_000_000,
            "online_cpus": 2,
        },
        "precpu_stats": {
            "cpu_usage": {"total_usage": 1_000_000},
            "system_cpu_usage": 9_000_000,
        },
    }
    result = _calc_cpu(stats)
    # cpu_delta=1_000_000, system_delta=1_000_000, num_cpus=2 → 200.0 → clamped? no clamping in spec
    assert result == 200.0


def test_calc_cpu_zero_system_delta():
    """Returns 0.0 when system_delta is zero (avoids division by zero)."""
    from main import _calc_cpu
    stats = {
        "cpu_stats": {
            "cpu_usage": {"total_usage": 100, "percpu_usage": [1]},
            "system_cpu_usage": 1000,
            "online_cpus": 1,
        },
        "precpu_stats": {
            "cpu_usage": {"total_usage": 100},
            "system_cpu_usage": 1000,
        },
    }
    assert _calc_cpu(stats) == 0.0


def test_calc_cpu_fallback_num_cpus():
    """Falls back through percpu_usage length → os.cpu_count() → 1 for num_cpus."""
    from main import _calc_cpu
    stats = {
        "cpu_stats": {
            "cpu_usage": {"total_usage": 2000, "percpu_usage": [500, 500]},
            "system_cpu_usage": 10000,
            # no online_cpus key
        },
        "precpu_stats": {
            "cpu_usage": {"total_usage": 1000},
            "system_cpu_usage": 9000,
        },
    }
    result = _calc_cpu(stats)
    # num_cpus = len([500, 500]) = 2
    assert result == round(1000 / 1000 * 2 * 100, 1)


# ---------------------------------------------------------------------------
# Helper: _container_info
# ---------------------------------------------------------------------------

def _make_container(status="running", name="/my-app", image_tags=None, mem_limit=0):
    """Build a minimal mock container for testing."""
    c = MagicMock()
    c.id = "abc" * 21 + "a"  # 64 chars
    c.name = name
    c.status = status
    mock_image = MagicMock()
    mock_image.tags = image_tags or ["nginx:latest"]
    c.image = mock_image
    c.attrs = {"HostConfig": {"Memory": mem_limit}}
    return c


def test_container_info_running():
    """Running container gets CPU and memory from live stats."""
    from main import _container_info
    c = _make_container(status="running")
    stats_data = {
        "cpu_stats": {
            "cpu_usage": {"total_usage": 2_000_000, "percpu_usage": [1]},
            "system_cpu_usage": 10_000_000,
            "online_cpus": 1,
        },
        "precpu_stats": {
            "cpu_usage": {"total_usage": 1_000_000},
            "system_cpu_usage": 9_000_000,
        },
        "memory_stats": {
            "usage": 134_217_728,   # 128 MB
            "limit": 2_147_483_648, # 2 GB
        },
    }
    c.stats.return_value = stats_data

    result = _container_info(c)

    assert result["name"] == "my-app"  # leading slash stripped
    assert result["status"] == "running"
    assert result["memory_mb"] == 128.0
    assert result["memory_limit_mb"] == 2048.0
    assert result["memory_percent"] == round(128 / 2048 * 100, 1)
    c.stats.assert_called_once_with(stream=False)


def test_container_info_stopped():
    """Non-running container: cpu=0, memory from HostConfig, no stats() call."""
    from main import _container_info
    c = _make_container(status="exited", mem_limit=536_870_912)  # 512 MB limit

    result = _container_info(c)

    c.stats.assert_not_called()
    assert result["cpu_percent"] == 0.0
    assert result["memory_mb"] == 0.0
    assert result["memory_limit_mb"] == 512.0


def test_container_info_no_mem_limit():
    """When HostConfig.Memory == 0, host RAM is substituted for limit."""
    import psutil
    from main import _container_info
    c = _make_container(status="exited", mem_limit=0)

    result = _container_info(c)

    expected_limit_mb = round(psutil.virtual_memory().total / (1024 ** 2), 1)
    assert result["memory_limit_mb"] == expected_limit_mb


def test_container_name_strip_slash():
    """Leading slash is removed from container name."""
    from main import _container_info
    c = _make_container(status="exited", name="/slashy")
    result = _container_info(c)
    assert result["name"] == "slashy"


def test_container_image_fallback_short_id():
    """Falls back to image.short_id when no tags are present."""
    from main import _container_info
    c = _make_container(status="exited", image_tags=[])
    c.image.short_id = "sha256:abc123"
    result = _container_info(c)
    assert result["image"] == "sha256:abc123"


# ---------------------------------------------------------------------------
# Endpoint: GET /docker
# ---------------------------------------------------------------------------

def test_get_docker_returns_cache(monkeypatch):
    """GET /docker returns _docker_cache without calling Docker SDK."""
    import main
    fake_cache = {
        "available": True,
        "containers": [{"id": "x" * 64, "name": "app", "image": "img:1",
                        "status": "running", "cpu_percent": 1.0,
                        "memory_mb": 64.0, "memory_limit_mb": 512.0,
                        "memory_percent": 12.5}],
    }
    monkeypatch.setattr(main, "_docker_cache", fake_cache)
    client = TestClient(main.app)

    resp = client.get("/docker")

    assert resp.status_code == 200
    assert resp.json() == fake_cache


def test_get_docker_unavailable(monkeypatch):
    """GET /docker returns available:false when Docker is not running."""
    import main
    monkeypatch.setattr(main, "_docker_cache", {"available": False, "containers": []})
    client = TestClient(main.app)

    resp = client.get("/docker")

    assert resp.status_code == 200
    assert resp.json()["available"] is False
    assert resp.json()["containers"] == []


# ---------------------------------------------------------------------------
# Endpoints: POST /docker/{id}/start|stop|restart
# ---------------------------------------------------------------------------

@pytest.fixture
def docker_action_client(monkeypatch):
    """TestClient with a mocked docker client that has one running container."""
    import main
    mock_client = MagicMock()
    mock_container = MagicMock()
    mock_client.containers.get.return_value = mock_container
    monkeypatch.setattr(main, "_docker_client", mock_client)
    return TestClient(main.app), mock_client, mock_container


def test_start_container(docker_action_client):
    client, mock_docker, mock_container = docker_action_client
    resp = client.post(f"/docker/{'a' * 64}/start")
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    mock_container.start.assert_called_once()


def test_stop_container(docker_action_client):
    client, mock_docker, mock_container = docker_action_client
    resp = client.post(f"/docker/{'a' * 64}/stop")
    assert resp.status_code == 200
    mock_container.stop.assert_called_once()


def test_restart_container(docker_action_client):
    client, mock_docker, mock_container = docker_action_client
    resp = client.post(f"/docker/{'a' * 64}/restart")
    assert resp.status_code == 200
    mock_container.restart.assert_called_once()


def test_action_container_not_found(monkeypatch):
    """Returns 500 with detail when container does not exist."""
    import main
    import docker as docker_sdk
    mock_client = MagicMock()
    mock_client.containers.get.side_effect = docker_sdk.errors.NotFound("not found")
    monkeypatch.setattr(main, "_docker_client", mock_client)
    client = TestClient(main.app)

    resp = client.post(f"/docker/{'b' * 64}/start")

    assert resp.status_code == 500
    assert "detail" in resp.json()
```

- [ ] **Step 5: Run tests to confirm they all fail**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server
source venv/bin/activate
python -m pytest tests/test_docker.py -v 2>&1 | head -40
```

Expected: multiple `ImportError` or `AttributeError` failures because `_calc_cpu`, `_container_info`, etc. don't exist yet. All tests should show as FAILED or ERROR.

- [ ] **Step 6: Commit the test file and requirements**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add server/requirements.txt server/tests/
git commit -m "test: add Docker monitoring test suite and dependencies"
```

---

## Task 2: Docker helpers in `main.py`

**Files:**
- Modify: `server/main.py`

Add all module-level Docker state and the helper functions that the tests exercise. Do not add endpoints yet.

- [ ] **Step 1: Add imports at the top of `server/main.py`**

After the existing imports (after `import subprocess`), add:

```python
import threading
import docker
import docker.errors
```

- [ ] **Step 2: Add module-level Docker globals**

After the `_proc_cpu_cache: dict = {}` line (~line 66), add:

```python
# Docker state
_docker_client = None
_docker_cache: dict = {"available": False, "containers": []}
_docker_refresh_lock = threading.Lock()
```

- [ ] **Step 3: Add `_calc_cpu` helper**

After the `_docker_refresh_lock` declaration, add:

```python
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
```

- [ ] **Step 4: Add `_container_info` helper**

```python
def _container_info(c) -> dict:
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
    }
```

- [ ] **Step 5: Add `_do_refresh` and `_refresh_docker`**

```python
def _do_refresh():
    global _docker_cache
    if _docker_client is None:
        _docker_cache = {"available": False, "containers": []}
        return
    try:
        containers = _docker_client.containers.list(all=True)
    except Exception:
        _docker_cache = {"available": False, "containers": []}
        return

    result = []
    for c in containers:
        try:
            result.append(_container_info(c))
        except Exception:
            continue  # skip this container; others are unaffected

    _docker_cache = {"available": True, "containers": result}


def _refresh_docker():
    """Thread-safe wrapper. Skips if a previous refresh is still running."""
    if not _docker_refresh_lock.acquire(blocking=False):
        return
    try:
        _do_refresh()
    finally:
        _docker_refresh_lock.release()
```

- [ ] **Step 6: Run the helper tests**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server
source venv/bin/activate
python -m pytest tests/test_docker.py -v -k "calc_cpu or container_info"
```

Expected: all `test_calc_cpu_*` and `test_container_info_*` tests PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add server/main.py
git commit -m "feat: add Docker cache globals and stat helpers"
```

---

## Task 3: Wire Docker into the lifespan and sampler

**Files:**
- Modify: `server/main.py`

- [ ] **Step 1: Initialize Docker client in `lifespan()`**

In the `lifespan()` function, after `psutil.cpu_percent(percpu=True)` priming (~line 110), add:

```python
    # Initialize Docker client
    global _docker_client
    try:
        _docker_client = docker.from_env()
    except Exception:
        _docker_client = None

    # Eager first refresh so /docker is populated before serving requests
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, _refresh_docker)
```

- [ ] **Step 2: Add Docker refresh to the `_sampler` coroutine**

Inside `_sampler`, after the `_cpu_percent_overall` update (after the `if _cpu_percent_per_core else 0.0` line), add:

```python
            # Refresh Docker stats on every sampler tick
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(None, _refresh_docker)
```

- [ ] **Step 3: Smoke-test the server starts without error**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server
source venv/bin/activate
python main.py &
sleep 3
curl -s http://localhost:8085/health
kill %1
```

Expected: `{"status":"ok"}` printed. No tracebacks in the server output. If Docker is running, you should see non-empty output from `curl -s http://localhost:8085/docker` once that endpoint exists.

- [ ] **Step 4: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add server/main.py
git commit -m "feat: initialize Docker client and refresh cache in sampler"
```

---

## Task 4: `GET /docker` and action endpoints

**Files:**
- Modify: `server/main.py`

- [ ] **Step 1: Add `GET /docker` endpoint**

After the `/history` endpoint (~line 273), add:

```python
@app.get("/docker")
async def get_docker():
    return _docker_cache
```

- [ ] **Step 2: Add action endpoints**

After `GET /docker`, add:

```python
@app.post("/docker/{container_id}/start")
async def docker_start(container_id: str):
    try:
        _docker_client.containers.get(container_id).start()
        return {"ok": True}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/docker/{container_id}/stop")
async def docker_stop(container_id: str):
    try:
        _docker_client.containers.get(container_id).stop()
        return {"ok": True}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/docker/{container_id}/restart")
async def docker_restart(container_id: str):
    try:
        _docker_client.containers.get(container_id).restart()
        return {"ok": True}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
```

- [ ] **Step 3: Run the full test suite**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server
source venv/bin/activate
python -m pytest tests/test_docker.py -v
```

Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add server/main.py
git commit -m "feat: add GET /docker endpoint and start/stop/restart actions"
```

---

## Task 5: Swift model — `DockerContainer.swift`

**Files:**
- Create: `MiniWatcher/Models/DockerContainer.swift`

- [ ] **Step 1: Create the model file**

Create `MiniWatcher/Models/DockerContainer.swift`:

```swift
import Foundation

struct DockerResponse: Codable {
    let available: Bool
    let containers: [DockerContainer]
}

struct DockerContainer: Codable, Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let cpuPercent: Double
    let memoryMb: Double
    let memoryLimitMb: Double
    let memoryPercent: Double

    /// Docker-convention 12-char display ID
    var shortId: String { String(id.prefix(12)) }

    enum CodingKeys: String, CodingKey {
        case id, name, image, status
        case cpuPercent = "cpu_percent"
        case memoryMb = "memory_mb"
        case memoryLimitMb = "memory_limit_mb"
        case memoryPercent = "memory_percent"
    }
}

enum DockerAction: String {
    case start, stop, restart
}
```

- [ ] **Step 2: Add the file to the Xcode project**

Open `MiniWatcher.xcodeproj` in Xcode. Right-click the `Models` group → "Add Files to MiniWatcher" → select `DockerContainer.swift`. Ensure "Add to target: MiniWatcher" is checked.

- [ ] **Step 3: Verify it builds**

In Xcode: Product → Build (⌘B). Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add MiniWatcher/Models/DockerContainer.swift MiniWatcher.xcodeproj/
git commit -m "feat: add DockerContainer Swift model and DockerAction enum"
```

---

## Task 6: `MetricsService.swift` — Docker state, fetch, and control

**Files:**
- Modify: `MiniWatcher/Services/MetricsService.swift`

- [ ] **Step 1: Add published Docker state**

After the `@Published var errorMessage: String?` line (~line 9), add:

```swift
    @Published var dockerContainers: [DockerContainer] = []
    @Published var dockerAvailable: Bool? = nil
```

- [ ] **Step 2: Update the poll loop to fetch Docker concurrently**

Replace the current `startPolling()` body:

```swift
// BEFORE:
pollingTask = Task {
    while !Task.isCancelled {
        await fetchMetrics()
        try? await Task.sleep(for: .seconds(3))
    }
}
```

With:

```swift
// AFTER:
pollingTask = Task {
    while !Task.isCancelled {
        async let metricsResult: Void = fetchMetrics()
        async let dockerResult: Void = fetchDocker()
        _ = await (metricsResult, dockerResult)
        try? await Task.sleep(for: .seconds(3))
    }
}
```

- [ ] **Step 3: Add `fetchDocker()`**

After the closing brace of `fetchMetrics()`, add:

```swift
    func fetchDocker() async {
        guard let url = URL(string: "\(baseURL)/docker") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(DockerResponse.self, from: data)
            dockerContainers = decoded.containers
            dockerAvailable = decoded.available
        } catch is CancellationError {
            // ignore
        } catch {
            // On first fetch, mark unavailable rather than staying nil forever
            if dockerAvailable == nil { dockerAvailable = false }
            // subsequent errors: keep previous state silently
        }
    }
```

- [ ] **Step 4: Add `controlContainer()`**

After the closing brace of `controlService()`, add:

```swift
    func controlContainer(id: String, action: DockerAction) async throws {
        guard let url = URL(string: "\(baseURL)/docker/\(id)/\(action.rawValue)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            struct ErrorBody: Decodable { let detail: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
                ?? "Container action failed"
            throw NSError(domain: "DockerError", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        // Immediately refresh so the UI reflects the new container status
        await fetchDocker()
    }
```

- [ ] **Step 5: Build and verify**

In Xcode: Product → Build (⌘B). Expected: no errors or warnings related to the new code.

- [ ] **Step 6: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add MiniWatcher/Services/MetricsService.swift
git commit -m "feat: add Docker polling, fetchDocker, and controlContainer to MetricsService"
```

---

## Task 7: `DockerView.swift`

**Files:**
- Create: `MiniWatcher/Views/DockerView.swift`

- [ ] **Step 1: Create the view file**

Create `MiniWatcher/Views/DockerView.swift`:

```swift
import SwiftUI

struct DockerView: View {
    @EnvironmentObject private var metricsService: MetricsService
    @State private var actionError: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                switch metricsService.dockerAvailable {
                case nil:
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case false:
                    ContentUnavailableView(
                        "Docker Unavailable",
                        systemImage: "shippingbox",
                        description: Text("Docker is not available on this host.")
                    )
                case true:
                    if metricsService.dockerContainers.isEmpty {
                        ContentUnavailableView(
                            "No Containers",
                            systemImage: "shippingbox",
                            description: Text("No Docker containers found.")
                        )
                    } else {
                        containerList
                    }
                default:
                    EmptyView()
                }
            }
            .navigationTitle("Docker")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Action Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown error")
        }
    }

    private var containerList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(metricsService.dockerContainers) { container in
                    ContainerRowView(container: container) { action in
                        await performAction(container: container, action: action)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func performAction(container: DockerContainer, action: DockerAction) async {
        do {
            try await metricsService.controlContainer(id: container.id, action: action)
        } catch {
            actionError = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Container Row

private struct ContainerRowView: View {
    let container: DockerContainer
    let onAction: (DockerAction) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name + image + status badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(container.image)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge(status: container.status)
            }

            // CPU
            HStack {
                Text("CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", container.cpuPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(container.cpuPercent > 80 ? .red : .primary)
            }

            // Memory bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("MEM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f / %.0f MB (%.1f%%)",
                                container.memoryMb,
                                container.memoryLimitMb,
                                container.memoryPercent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(container.memoryPercent > 85 ? Color.red : Color.blue)
                            .frame(width: geo.size.width * CGFloat(container.memoryPercent / 100),
                                   height: 6)
                    }
                }
                .frame(height: 6)
            }

            // Action buttons
            HStack(spacing: 8) {
                ActionButton(label: "Start",
                             systemImage: "play.fill",
                             disabled: container.status == "running" || container.status == "paused") {
                    await onAction(.start)
                }
                ActionButton(label: "Stop",
                             systemImage: "stop.fill",
                             disabled: container.status != "running") {
                    await onAction(.stop)
                }
                ActionButton(label: "Restart",
                             systemImage: "arrow.clockwise",
                             disabled: container.status != "running") {
                    await onAction(.restart)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "running": return .green
        case "paused": return .yellow
        default: return .gray
        }
    }

    var body: some View {
        Text(status)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let label: String
    let systemImage: String
    let disabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .controlSize(.small)
    }
}
```

- [ ] **Step 2: Add the file to the Xcode project**

In Xcode, right-click the `Views` group → "Add Files to MiniWatcher" → select `DockerView.swift`. Ensure target is checked.

- [ ] **Step 3: Build**

Product → Build (⌘B). Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add MiniWatcher/Views/DockerView.swift MiniWatcher.xcodeproj/
git commit -m "feat: add DockerView with container list, status badges, and action buttons"
```

---

## Task 8: Register Docker tab in `MiniWatcherApp.swift`

**Files:**
- Modify: `MiniWatcher/MiniWatcherApp.swift`

- [ ] **Step 1: Insert the Docker tab**

In `MiniWatcherApp.swift`, add the Docker tab between `ServicesView` and `SettingsView`:

```swift
// BEFORE (inside TabView):
                ServicesView()
                    .tabItem {
                        Label("Services", systemImage: "list.bullet.rectangle")
                    }

                SettingsView()
```

```swift
// AFTER:
                ServicesView()
                    .tabItem {
                        Label("Services", systemImage: "list.bullet.rectangle")
                    }

                DockerView()
                    .tabItem {
                        Label("Docker", systemImage: "shippingbox")
                    }

                SettingsView()
```

The `.environmentObject(metricsService)` is already applied at the `TabView` level (line 30), so `DockerView` receives it automatically — no additional modifier needed.

- [ ] **Step 2: Build**

Product → Build (⌘B). Expected: no errors.

- [ ] **Step 3: Manual smoke test**

Run the app in Xcode Simulator or on device. Confirm:

1. A "Docker" tab appears between Services and Settings with a box icon
2. If Docker Desktop is not running: the tab shows "Docker Unavailable"
3. If Docker Desktop is running: containers appear in the list
4. Start a test container: `docker run -d --name test-nginx nginx`
5. The container should appear as "running" in the list with CPU and memory stats
6. Tap **Stop** — container status should change to "exited" within ~3 seconds
7. Tap **Start** — container should return to "running"
8. Tap **Restart** — container should restart (briefly "exited" then "running")
9. Stop the Docker daemon — the tab should switch to "Docker Unavailable" within 3 seconds

- [ ] **Step 4: Clean up test container**

```bash
docker rm -f test-nginx
```

- [ ] **Step 5: Commit**

```bash
cd /Users/zhongyang/Dev/mini-watcher
git add MiniWatcher/MiniWatcherApp.swift
git commit -m "feat: add Docker tab to main tab bar"
```

---

## Final Verification

- [ ] Run the full Python test suite one more time to confirm nothing regressed:

```bash
cd /Users/zhongyang/Dev/mini-watcher/server
source venv/bin/activate
python -m pytest tests/ -v
```

Expected: all tests PASS.

- [ ] Build the Xcode project cleanly (Product → Clean Build Folder, then ⌘B). Expected: no errors or warnings.
