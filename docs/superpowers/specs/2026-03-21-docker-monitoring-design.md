# Docker Container Monitoring — Design Spec

**Date:** 2026-03-21
**Status:** Approved

---

## Overview

Add Docker container monitoring to mini-watcher. Users can view running and stopped containers with CPU % and memory usage, and control them (start / stop / restart) from a dedicated tab in the macOS app.

---

## Requirements

- Display all containers: name, image, status, CPU %, memory usage
- Refresh at the same **3-second** client-side interval as host metrics
- Support start / stop / restart per container
- Gracefully handle Docker being unavailable (no crash, clear message)
- Requires Docker socket access (Docker Desktop on macOS, or `docker` group on Linux)
- Minimum deployment target: macOS 12

---

## Backend (`server/main.py`)

### Dependency

Add `docker>=6.0` to `requirements.txt` (minimum version to avoid v5→v6 breaking changes).

### Docker Client Lifecycle

A single Docker client is created once in `lifespan()`. It is never re-created per sampler tick:

```python
_docker_client = None

# inside lifespan():
try:
    _docker_client = docker.from_env()
except Exception:
    _docker_client = None
```

If calls against the cached client raise `DockerException`, the cache is set to `available: False` and the client is left as-is. It will be retried on the next sampler tick and recover naturally if Docker becomes available.

### Background Cache

A module-level dict holds the latest snapshot, initialized to `available: False` (not `True`) to avoid a misleading empty-but-"available" state before the first refresh:

```python
_docker_cache: dict = {"available": False, "containers": []}
_docker_refresh_lock = threading.Lock()
```

The `lifespan()` function triggers an **eager first refresh** before `yield` via `run_in_executor` (not a bare synchronous call, which would block the event loop):

```python
loop = asyncio.get_event_loop()
await loop.run_in_executor(None, _refresh_docker)  # non-blocking; called before yield
```

Subsequent refreshes run inside `_sampler` via `run_in_executor`:

```python
loop = asyncio.get_event_loop()
await loop.run_in_executor(None, _refresh_docker)
```

**Overlap guard:** `_refresh_docker()` acquires `_docker_refresh_lock` with a non-blocking `trylock`. If a previous refresh is still running (slow Docker), the current tick skips it entirely:

```python
def _refresh_docker():
    if not _docker_refresh_lock.acquire(blocking=False):
        return  # previous refresh still running, skip this tick
    try:
        _do_refresh()
    finally:
        _docker_refresh_lock.release()
```

### `_do_refresh()` Implementation

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
```

### `_container_info(c)` — Per-Container Stats

```python
def _container_info(c):
    name = c.name.lstrip("/")
    image = c.image.tags[0] if c.image.tags else c.image.short_id
    status = c.status  # "running", "exited", "paused", etc.

    if status == "running":
        stats = c.stats(stream=False)
        cpu_percent = _calc_cpu(stats)
        mem_usage = stats["memory_stats"].get("usage", 0)
        mem_limit = stats["memory_stats"].get("limit", 0)
    else:
        # Do NOT call stats() for non-running containers — it may block or error
        cpu_percent = 0.0
        mem_usage = 0
        mem_limit = c.attrs["HostConfig"].get("Memory", 0)

    # When limit is 0 (no explicit limit), substitute total host RAM
    if mem_limit == 0:
        mem_limit = psutil.virtual_memory().total

    memory_mb = round(mem_usage / (1024 ** 2), 1)
    memory_limit_mb = round(mem_limit / (1024 ** 2), 1)
    memory_percent = round(mem_usage / mem_limit * 100, 1) if mem_limit > 0 else 0.0

    return {
        "id": c.id,          # full 64-char SHA
        "name": name,
        "image": image,
        "status": status,
        "cpu_percent": cpu_percent,
        "memory_mb": memory_mb,
        "memory_limit_mb": memory_limit_mb,
        "memory_percent": memory_percent,
    }
```

### CPU Calculation

```python
def _calc_cpu(stats):
    cpu_delta = (stats["cpu_stats"]["cpu_usage"]["total_usage"]
                 - stats["precpu_stats"]["cpu_usage"]["total_usage"])
    system_delta = (stats["cpu_stats"].get("system_cpu_usage", 0)
                    - stats["precpu_stats"].get("system_cpu_usage", 0))
    num_cpus = (
        stats["cpu_stats"].get("online_cpus")
        or len(stats["cpu_stats"]["cpu_usage"].get("percpu_usage", []))
        or os.cpu_count()
        or 1
    )
    return round((cpu_delta / system_delta * num_cpus * 100), 1) if system_delta > 0 else 0.0
```

### `GET /docker`

Reads `_docker_cache` and returns immediately (no blocking calls):

```python
@app.get("/docker")
async def get_docker():
    return _docker_cache
```

**Response schema:**
```json
{
  "available": true,
  "containers": [
    {
      "id": "abc123def456...64chars",
      "name": "my-app",
      "image": "nginx:latest",
      "status": "running",
      "cpu_percent": 1.4,
      "memory_mb": 128.5,
      "memory_limit_mb": 2048.0,
      "memory_percent": 6.3
    }
  ]
}
```

If Docker is unavailable: `{"available": false, "containers": []}` (HTTP 200).

### Action Endpoints

```
POST /docker/{id}/start
POST /docker/{id}/stop
POST /docker/{id}/restart
```

- `id` is the full 64-character container ID
- On success: `{"ok": true}` (HTTP 200)
- On failure: `HTTPException(status_code=500, detail=str(e))`
- Mirrors the pattern of existing `/services/{label}/start` and `/services/{label}/stop`
- Does **not** trigger an immediate cache refresh (the sampler picks it up within 2 seconds; the Swift client calls `fetchDocker()` immediately after success)

---

## Swift App

### Model (`Models/DockerContainer.swift`)

New file:

```swift
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

    var shortId: String { String(id.prefix(12)) }  // Docker-convention 12-char display ID

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

### Service (`Services/MetricsService.swift`)

**New published state:**
```swift
@Published var dockerContainers: [DockerContainer] = []
@Published var dockerAvailable: Bool? = nil  // nil = not yet loaded
```

`dockerAvailable` starts as `nil`. On first-fetch error (any error), it is set to `false`. On subsequent errors, the previous state is kept silently.

**Updated poll loop** using valid `async let` Swift concurrency syntax:

```swift
pollingTask = Task {
    while !Task.isCancelled {
        async let metrics: Void = fetchMetrics()
        async let docker: Void = fetchDocker()
        _ = await (metrics, docker)
        try? await Task.sleep(for: .seconds(3))
    }
}
```

Both fetches run concurrently. The 3-second sleep starts after both complete (or fail).

**New fetch method:**
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
        if dockerAvailable == nil { dockerAvailable = false }
        // subsequent errors: keep previous state silently
    }
}
```

**Action method:**

`controlContainer` is `@MainActor`-isolated (inherited from the class), so all `@Published` mutations inside `fetchDocker()` are safe. Call sites must use `Task { }` (not `Task.detached`) to preserve actor isolation:

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
    await fetchDocker()  // refresh immediately after success
}
```

### View (`Views/DockerView.swift`)

New view. Four states:

- `dockerAvailable == nil` → `ProgressView("Loading...")`
- `dockerAvailable == false` → centered placeholder: "Docker is not available on this host"
- `dockerAvailable == true`, containers empty → centered placeholder: "No containers found"
- `dockerAvailable == true`, containers non-empty → `List` of container rows

**Each row shows:**
- Container name (bold) + image name (secondary)
- Status badge: green (`running`), yellow (`paused`), gray (all other statuses)
- CPU % label
- Memory bar: used / limit with percentage — matching `ProcessListView` style
- Three action buttons: **Start** / **Stop** / **Restart**

**Button enable logic:**
- **Start**: disabled when `status == "running"` or `status == "paused"`
- **Stop**: disabled when `status != "running"`
- **Restart**: disabled when `status != "running"`

Paused containers have all three buttons disabled. This is intentional — unpause is out of scope. No additional explanation is shown to the user (the yellow "paused" badge communicates the state).

Action errors surface as a `.alert` on the view, populated from the thrown error's `localizedDescription`.

### Tab Registration (`MiniWatcherApp.swift`)

`DockerView` is inserted at position 4 in the `TabView`, before Settings, and receives `metricsService` via `.environmentObject` (same as all other tabs). Final tab order:

1. Dashboard
2. History
3. Services
4. **Docker** — `shippingbox` SF Symbol ← new
5. Settings

---

## Error Handling

| Scenario | Behavior |
|---|---|
| Docker not installed at startup | `docker.from_env()` throws; client is nil; cache stays `available: false` |
| Docker socket permission denied | Same |
| `_refresh_docker` takes >2s | Next sampler tick skips via `trylock`; previous cache served |
| `stats()` or other call fails for one container | Per-container `try/except` catches it; container skipped; others unaffected |
| `mem_limit == 0` (no explicit limit) | Substitute host total RAM for limit computation |
| Action fails | Server returns `{"detail": "..."}` (HTTP 500); Swift decodes and shows alert |
| Action succeeds | `fetchDocker()` called immediately; UI refreshes |
| First `fetchDocker` error | `dockerAvailable = false`; placeholder shown |
| Subsequent `fetchDocker` errors | Previous state kept silently |

---

## Out of Scope

- Container removal / deletion
- Log streaming
- Container creation
- Unpause action
- History tracking for container metrics
