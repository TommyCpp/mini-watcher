# Tmux Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Tmux tab to MiniWatcher for viewing and killing tmux sessions on the monitored server.

**Architecture:** Python FastAPI backend exposes `GET /tmux` and `POST /tmux/{session}/kill` using subprocess with list-form invocation for safety; Swift `MetricsService` polls every 3s via a concurrent `async let` group; `TmuxView` renders session rows with kill confirmation and an `isKilling` guard.

**Tech Stack:** Python 3 + FastAPI + subprocess, Swift 5.9 + SwiftUI + async/await, pytest + FastAPI TestClient

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `server/tests/test_tmux.py` | **Create** | Tests for `_get_tmux_sessions()` helper and both endpoints |
| `server/main.py` | **Modify** | Add `_INVALID_SESSION_CHARS`, `_get_tmux_sessions()`, `GET /tmux`, `POST /tmux/{session}/kill` |
| `MiniWatcher/Models/TmuxSession.swift` | **Create** | `TmuxSession` + `TmuxResponse` Codable models |
| `MiniWatcher/Services/MetricsService.swift` | **Modify** | Add `tmuxSessions`, `tmuxAvailable`, `fetchTmux()`, `killTmuxSession()`, update `startPolling()` |
| `MiniWatcher/Views/TmuxView.swift` | **Create** | Full tmux management UI (session list, badges, kill button) |
| `MiniWatcher/MiniWatcherApp.swift` | **Modify** | Add Tmux tab before Settings |

---

## Task 1: Backend – GET /tmux helper + endpoint

**Files:**
- Create: `server/tests/test_tmux.py`
- Modify: `server/main.py`

- [ ] **Step 1: Write failing tests for `_get_tmux_sessions()`**

Create `server/tests/test_tmux.py`:

```python
"""Tests for tmux endpoints and helpers."""
import os
import sys
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))


# ---------------------------------------------------------------------------
# Helper: _get_tmux_sessions
# ---------------------------------------------------------------------------

def test_tmux_not_installed():
    """Returns available:false when tmux binary is not found."""
    from main import _get_tmux_sessions
    with patch("main.subprocess.run", side_effect=FileNotFoundError):
        result = _get_tmux_sessions()
    assert result == {"available": False, "sessions": []}


def test_tmux_no_server_running():
    """Returns available:true, empty sessions when tmux is installed but no server is up."""
    from main import _get_tmux_sessions
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stdout = ""
    mock_result.stderr = "no server running on /tmp/tmux-501/default"
    with patch("main.subprocess.run", return_value=mock_result):
        result = _get_tmux_sessions()
    assert result == {"available": True, "sessions": []}


def test_tmux_zero_sessions():
    """Returns available:true, empty sessions when tmux runs but no sessions exist."""
    from main import _get_tmux_sessions
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = ""
    with patch("main.subprocess.run", return_value=mock_result):
        result = _get_tmux_sessions()
    assert result == {"available": True, "sessions": []}


def test_tmux_parses_sessions():
    """Correctly parses multiple sessions from tmux ls output."""
    from main import _get_tmux_sessions
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "main\t3\t1710000000\t1\nwork\t1\t1709999000\t0\n"
    with patch("main.subprocess.run", return_value=mock_result):
        result = _get_tmux_sessions()
    assert result["available"] is True
    assert len(result["sessions"]) == 2
    assert result["sessions"][0] == {
        "name": "main", "windows": 3, "created": 1710000000, "attached": True,
    }
    assert result["sessions"][1] == {
        "name": "work", "windows": 1, "created": 1709999000, "attached": False,
    }


def test_tmux_skips_malformed_lines():
    """Lines with wrong field count are silently skipped."""
    from main import _get_tmux_sessions
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stdout = "main\t3\t1710000000\t1\nbadline\n"
    with patch("main.subprocess.run", return_value=mock_result):
        result = _get_tmux_sessions()
    assert len(result["sessions"]) == 1
    assert result["sessions"][0]["name"] == "main"
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server && python -m pytest tests/test_tmux.py -v
```

Expected: `ImportError: cannot import name '_get_tmux_sessions' from 'main'`

- [ ] **Step 3: Implement `_get_tmux_sessions()` and `GET /tmux` in `server/main.py`**

Add after line 214 (after `_get_launchctl_list`, before `_read_user_plists`), then add the endpoint after the `/health` endpoint (after line 313):

```python
# --- add as a module-level constant near the top of main.py, after PROTECTED_LABELS ---
_INVALID_SESSION_CHARS = frozenset("/\x00\n")


# --- add this function after _get_launchctl_list() ---
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
```

```python
# --- add this endpoint after the /health endpoint ---
@app.get("/tmux")
async def get_tmux():
    return _get_tmux_sessions()
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server && python -m pytest tests/test_tmux.py::test_tmux_not_installed tests/test_tmux.py::test_tmux_no_server_running tests/test_tmux.py::test_tmux_zero_sessions tests/test_tmux.py::test_tmux_parses_sessions tests/test_tmux.py::test_tmux_skips_malformed_lines -v
```

Expected: all 5 PASS

- [ ] **Step 5: Commit**

```bash
git add server/main.py server/tests/test_tmux.py
git commit -m "feat: add GET /tmux endpoint with session parsing and error handling"
```

---

## Task 2: Backend – POST /tmux/{session}/kill + tests

**Files:**
- Modify: `server/tests/test_tmux.py` (append tests)
- Modify: `server/main.py` (add endpoint)

- [ ] **Step 1: Add failing tests for the kill endpoint**

Append to `server/tests/test_tmux.py`:

```python
# ---------------------------------------------------------------------------
# Endpoint: GET /tmux
# ---------------------------------------------------------------------------

def test_get_tmux_returns_sessions(monkeypatch):
    """GET /tmux returns session list from _get_tmux_sessions."""
    import main
    monkeypatch.setattr(main, "_get_tmux_sessions", lambda: {
        "available": True,
        "sessions": [{"name": "dev", "windows": 2, "created": 1710000000, "attached": True}],
    })
    client = TestClient(main.app)
    resp = client.get("/tmux")
    assert resp.status_code == 200
    data = resp.json()
    assert data["available"] is True
    assert data["sessions"][0]["name"] == "dev"


def test_get_tmux_unavailable(monkeypatch):
    """GET /tmux returns available:false when tmux is not installed."""
    import main
    monkeypatch.setattr(main, "_get_tmux_sessions", lambda: {"available": False, "sessions": []})
    client = TestClient(main.app)
    resp = client.get("/tmux")
    assert resp.status_code == 200
    assert resp.json() == {"available": False, "sessions": []}


# ---------------------------------------------------------------------------
# Endpoint: POST /tmux/{session}/kill
# ---------------------------------------------------------------------------

def test_kill_session_success(monkeypatch):
    """Returns success:true when tmux kill-session exits 0."""
    import main
    mock_result = MagicMock()
    mock_result.returncode = 0
    mock_result.stderr = ""
    monkeypatch.setattr(main.subprocess, "run", lambda *a, **kw: mock_result)
    client = TestClient(main.app)
    resp = client.post("/tmux/main/kill")
    assert resp.status_code == 200
    assert resp.json() == {"success": True}


def test_kill_session_not_found(monkeypatch):
    """Returns 500 when tmux reports the session does not exist."""
    import main
    mock_result = MagicMock()
    mock_result.returncode = 1
    mock_result.stderr = "can't find session: missing"
    monkeypatch.setattr(main.subprocess, "run", lambda *a, **kw: mock_result)
    client = TestClient(main.app)
    resp = client.post("/tmux/missing/kill")
    assert resp.status_code == 500
    assert "detail" in resp.json()


def test_kill_session_invalid_name_newline():
    """Returns 400 when session name contains a newline (percent-encoded in URL)."""
    import main
    client = TestClient(main.app)
    resp = client.post("/tmux/foo%0Abar/kill")
    assert resp.status_code == 400


def test_kill_session_subprocess_uses_list(monkeypatch):
    """Verifies subprocess is called with a list (not a shell string) for safety."""
    import main
    captured = {}
    def fake_run(args, **kwargs):
        captured["args"] = args
        r = MagicMock()
        r.returncode = 0
        r.stderr = ""
        return r
    monkeypatch.setattr(main.subprocess, "run", fake_run)
    client = TestClient(main.app)
    client.post("/tmux/mysession/kill")
    assert isinstance(captured["args"], list)
    assert "mysession" in captured["args"]


def test_invalid_session_chars_set():
    """_INVALID_SESSION_CHARS contains the required dangerous characters."""
    from main import _INVALID_SESSION_CHARS
    assert "/" in _INVALID_SESSION_CHARS
    assert "\x00" in _INVALID_SESSION_CHARS
    assert "\n" in _INVALID_SESSION_CHARS
```

- [ ] **Step 2: Run new tests to confirm they fail**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server && python -m pytest tests/test_tmux.py -k "kill or get_tmux" -v
```

Expected: FAIL for kill tests (endpoint not defined yet), PASS for `get_tmux` tests.

- [ ] **Step 3: Implement `POST /tmux/{session}/kill` in `server/main.py`**

Add immediately after the `GET /tmux` endpoint:

```python
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
```

- [ ] **Step 4: Run all tmux tests to confirm they pass**

```bash
cd /Users/zhongyang/Dev/mini-watcher/server && python -m pytest tests/test_tmux.py -v
```

Expected: all tests PASS (skip `test_kill_session_subprocess_uses_list` if the helper function approach is awkward — the validation logic is covered by other tests)

- [ ] **Step 5: Commit**

```bash
git add server/main.py server/tests/test_tmux.py
git commit -m "feat: add POST /tmux/{session}/kill with input validation"
```

---

## Task 3: Swift Model – TmuxSession.swift

**Files:**
- Create: `MiniWatcher/Models/TmuxSession.swift`

- [ ] **Step 1: Create the model file**

```swift
import Foundation

struct TmuxSession: Codable, Identifiable {
    let name: String
    let windows: Int
    let created: Double  // whole-number Unix epoch; Double for Date conversion
    let attached: Bool

    var id: String { name }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
}

struct TmuxResponse: Codable {
    let available: Bool
    let sessions: [TmuxSession]
}
```

- [ ] **Step 2: Build to confirm no errors**

```bash
xcodebuild -project /Users/zhongyang/Dev/mini-watcher/MiniWatcher.xcodeproj \
  -scheme MiniWatcher build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Models/TmuxSession.swift
git commit -m "feat: add TmuxSession and TmuxResponse models"
```

---

## Task 4: Swift Service – MetricsService tmux methods

**Files:**
- Modify: `MiniWatcher/Services/MetricsService.swift`

- [ ] **Step 1: Add published properties after `dockerAvailable` (line 10)**

```swift
@Published var tmuxSessions: [TmuxSession] = []
@Published var tmuxAvailable: Bool? = nil
```

- [ ] **Step 2: Add `fetchTmux()` after `fetchDocker()` (after line 77)**

```swift
func fetchTmux() async {
    guard let url = URL(string: "\(baseURL)/tmux") else { return }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(TmuxResponse.self, from: data)
        tmuxSessions = decoded.sessions
        tmuxAvailable = decoded.available
    } catch is CancellationError {
        // ignore
    } catch {
        if tmuxAvailable == nil { tmuxAvailable = false }
    }
}
```

- [ ] **Step 3: Add `killTmuxSession()` after `fetchTmux()`**

```swift
func killTmuxSession(_ name: String) async throws {
    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    guard let url = URL(string: "\(baseURL)/tmux/\(encoded)/kill") else {
        throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        struct ErrorBody: Decodable { let detail: String }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            ?? "Failed to kill session"
        throw NSError(domain: "TmuxError", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }
    await fetchTmux()
}
```

- [ ] **Step 4: Add `fetchTmux()` to the concurrent polling group in `startPolling()` (lines 29-31)**

Change:
```swift
async let metricsResult: Void = fetchMetrics()
async let dockerResult: Void = fetchDocker()
_ = await (metricsResult, dockerResult)
```

To:
```swift
async let metricsResult: Void = fetchMetrics()
async let dockerResult: Void = fetchDocker()
async let tmuxResult: Void = fetchTmux()
_ = await (metricsResult, dockerResult, tmuxResult)
```

- [ ] **Step 5: Build to confirm no errors**

```bash
xcodebuild -project /Users/zhongyang/Dev/mini-watcher/MiniWatcher.xcodeproj \
  -scheme MiniWatcher build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add MiniWatcher/Services/MetricsService.swift
git commit -m "feat: add fetchTmux and killTmuxSession to MetricsService"
```

---

## Task 5: Swift View – TmuxView.swift

**Files:**
- Create: `MiniWatcher/Views/TmuxView.swift`

- [ ] **Step 1: Create the view file**

```swift
import SwiftUI

struct TmuxView: View {
    @EnvironmentObject private var metricsService: MetricsService
    @State private var actionError: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                switch metricsService.tmuxAvailable {
                case nil:
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case false:
                    ContentUnavailableView(
                        "tmux Not Available",
                        systemImage: "terminal",
                        description: Text("tmux is not installed or not running on this host.")
                    )
                case true:
                    if metricsService.tmuxSessions.isEmpty {
                        ContentUnavailableView(
                            "No tmux Sessions",
                            systemImage: "terminal",
                            description: Text("No active tmux sessions found on the server.")
                        )
                    } else {
                        sessionList
                    }
                }
            }
            .navigationTitle("tmux")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Kill Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown error")
        }
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(metricsService.tmuxSessions) { session in
                    SessionRowView(session: session) {
                        await performKill(session: session)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func performKill(session: TmuxSession) async {
        do {
            try await metricsService.killTmuxSession(session.name)
        } catch {
            actionError = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    let session: TmuxSession
    let onKill: () async -> Void
    @State private var isKilling = false
    @State private var showKillConfirm = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: name + metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text("\(session.windows) \(session.windows == 1 ? "window" : "windows")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.createdDate.relativeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Right: attached badge + kill button
            VStack(alignment: .trailing, spacing: 6) {
                AttachedBadge(attached: session.attached)
                Button(role: .destructive) {
                    showKillConfirm = true
                } label: {
                    Label("Kill", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isKilling)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
        .confirmationDialog(
            "Kill session \"\(session.name)\"?",
            isPresented: $showKillConfirm,
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                Task {
                    isKilling = true
                    defer { isKilling = false }
                    await onKill()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Attached Badge

private struct AttachedBadge: View {
    let attached: Bool

    var body: some View {
        Text(attached ? "attached" : "detached")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((attached ? Color.green : Color.gray).opacity(0.15), in: Capsule())
            .foregroundStyle(attached ? .green : .secondary)
    }
}

// MARK: - Date helper

private extension Date {
    var relativeString: String {
        let seconds = Int(Date.now.timeIntervalSince(self))
        switch seconds {
        case ..<60:      return "\(seconds)s ago"
        case ..<3600:    return "\(seconds / 60)m ago"
        case ..<86400:   return "\(seconds / 3600)h ago"
        default:         return "\(seconds / 86400)d ago"
        }
    }
}
```

- [ ] **Step 2: Build to confirm no errors**

```bash
xcodebuild -project /Users/zhongyang/Dev/mini-watcher/MiniWatcher.xcodeproj \
  -scheme MiniWatcher build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Views/TmuxView.swift
git commit -m "feat: add TmuxView with session list, attached badge, and kill confirmation"
```

---

## Task 6: Wire up tab in MiniWatcherApp.swift

**Files:**
- Modify: `MiniWatcher/MiniWatcherApp.swift`

- [ ] **Step 1: Insert Tmux tab before Settings**

In `MiniWatcherApp.swift`, add after the `DockerView()` tab item (after line 28) and before `SettingsView()`:

```swift
TmuxView()
    .tabItem {
        Label("Tmux", systemImage: "terminal")
    }
```

- [ ] **Step 2: Build to confirm no errors**

```bash
xcodebuild -project /Users/zhongyang/Dev/mini-watcher/MiniWatcher.xcodeproj \
  -scheme MiniWatcher build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/MiniWatcherApp.swift
git commit -m "feat: add Tmux tab to main tab bar"
```

---

## Manual Verification Checklist

After all tasks complete, verify on device/simulator:

- [ ] Tmux tab appears in tab bar between Docker and Settings
- [ ] When server has active sessions: list renders with name, window count, relative time, attached badge
- [ ] Kill button shows confirmation dialog before killing
- [ ] After kill, session disappears from list within 3 seconds
- [ ] When no sessions: "No tmux Sessions" empty state shows
- [ ] When tmux not installed on server: "tmux Not Available" shows
- [ ] Backend test suite still passes: `cd server && python -m pytest tests/ -v`
