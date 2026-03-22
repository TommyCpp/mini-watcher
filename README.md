# mini-watcher

A system monitoring app for iOS that connects to a lightweight Python server running on your Mac or Linux host.

## Features

- **Dashboard** — real-time CPU (per-core), memory, disk, and network I/O gauges
- **History** — time-series charts for CPU, memory, and network over 1h / 6h / 24h / 7d
- **Services** — view and control launchd / systemd services (start / stop / restart)
- **Containers** — monitor Docker and Podman containers simultaneously; shows CPU %, memory usage, and status with start / stop / restart controls
- **Settings** — configure server host and port

## Architecture

```
iPhone (SwiftUI)  ──HTTP──►  Python FastAPI server (Mac/Linux)
                                     │
                              ┌──────┴──────┐
                           psutil        Docker/Podman SDK
                        (host metrics)   (container metrics)
```

The server exposes a REST API polled every 3 seconds by the iOS app.

## Server Setup

**Requirements:** Python 3.10+, Docker or Podman (optional)

```bash
cd server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8085
```

### Run as a launchd service (macOS)

Create `~/Library/LaunchAgents/com.miniwatcher.server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.miniwatcher.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/path/to/server/venv/bin/uvicorn</string>
    <string>main:app</string>
    <string>--host</string>
    <string>0.0.0.0</string>
    <string>--port</string>
    <string>8085</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/server</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.miniwatcher.server.plist
```

### Docker / Podman support

The server auto-detects both runtimes at startup. Priority order:

1. `DOCKER_HOST` env var
2. `PODMAN_HOST` env var
3. `/var/run/docker.sock` (Docker default)
4. `/run/user/<uid>/podman/podman.sock` (Podman rootless, Linux)
5. `~/.local/share/containers/podman/machine/podman-machine-default/podman.sock` (Podman machine, macOS)

If both are running, containers from both appear in the same list with a runtime badge.

### Run tests

```bash
cd server
pytest tests/
```

## iOS App Setup

**Requirements:** Xcode 16+, iOS 18+, iPhone on the same network as the server

1. Open `MiniWatcher.xcodeproj` in Xcode
2. Set your Apple Development Team in project settings
3. Build and run on your device

### Configure server address

Open the **Settings** tab in the app and enter your server's IP and port.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/metrics` | Current system metrics |
| `GET` | `/history` | Historical data (`?range=1h\|6h\|24h\|7d`) |
| `GET` | `/services` | List launchd/systemd services |
| `POST` | `/services/{label}/{action}` | Control a service (`start\|stop\|restart`) |
| `GET` | `/docker` | List containers from Docker and Podman |
| `POST` | `/docker/{id}/{action}` | Control a container (`?runtime=docker\|podman`) |
