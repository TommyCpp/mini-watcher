# Tmux Management Feature Design

**Date:** 2026-03-23
**Status:** Approved
**Scope:** Read-only session list + kill session action

---

## Overview

Add a Tmux tab to MiniWatcher for viewing and managing tmux sessions on the monitored server. Follows the same architecture pattern as the existing Docker tab.

---

## Requirements

- Display all tmux sessions on the server (name, window count, created time, attached status)
- Kill (destroy) a session with a confirmation step
- Handle tmux not installed or no sessions gracefully
- Auto-refresh every 3 seconds via existing polling loop
- Out of scope: create session, rename session, view windows/panes, send commands

---

## Architecture

### Backend — `server/main.py`

Two new endpoints:

**`GET /tmux`**

Calls tmux via subprocess **as a list** (never shell string interpolation) to prevent command injection:

```python
subprocess.run(
    ["tmux", "ls", "-F", "#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}"],
    capture_output=True, text=True
)
```

Three distinct subprocess outcomes are handled separately:

| Outcome | Cause | Response |
|---|---|---|
| `FileNotFoundError` | tmux binary not installed | `{ "available": false, "sessions": [] }` |
| Exit code 1, stderr contains "no server" / "error connecting" | tmux installed but no server running (zero sessions ever started) | `{ "available": true, "sessions": [] }` |
| Exit code 0, stdout empty | tmux running, zero active sessions | `{ "available": true, "sessions": [] }` |
| Exit code 0, stdout non-empty | Normal case | `{ "available": true, "sessions": [...] }` |

The `created` field is a whole-number Unix epoch integer from `#{session_created}` (tmux does not provide sub-second precision). It is serialized as a JSON number (e.g., `1710000000`).

Response structure:
```json
{
  "available": true,
  "sessions": [
    {
      "name": "main",
      "windows": 3,
      "created": 1710000000,
      "attached": true
    }
  ]
}
```

**`POST /tmux/{session}/kill`**

Session name validation (backend):
- Reject names containing `/`, `\0` (null byte), or `\n` (newline) with HTTP 400.
- Pass session name as a list element to subprocess: `["tmux", "kill-session", "-t", session_name]`.

Returns `{ "success": true }` on success, HTTP 400/500 on failure.

**Security note:** The Swift client must percent-encode the session name before embedding it in the URL path (following the same pattern as `controlService` in `MetricsService.swift`).

---

### Data Model — `MiniWatcher/Models/TmuxSession.swift`

```swift
struct TmuxSession: Codable, Identifiable {
    let name: String
    let windows: Int
    let created: Double   // whole-number Unix epoch from tmux; Double for Date conversion
    let attached: Bool

    var id: String { name }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
}

struct TmuxResponse: Codable {
    let available: Bool
    let sessions: [TmuxSession]
}
```

---

### Service — `MiniWatcher/Services/MetricsService.swift`

New published properties:
```swift
@Published var tmuxSessions: [TmuxSession] = []
@Published var tmuxAvailable: Bool? = nil   // nil = loading; true/false after first fetch
```

New methods:
- `fetchTmux()` — `GET /tmux`, updates `tmuxSessions` and `tmuxAvailable`. On fetch failure, sets `tmuxAvailable = false` (matches Docker behavior) to prevent permanent loading spinner.
- `killTmuxSession(_ name: String) async throws` — percent-encodes the name, calls `POST /tmux/{encodedName}/kill`, then calls `fetchTmux()` on success for an immediate UI refresh (matching `controlContainer` precedent).

**Polling integration:** `fetchTmux()` is added to the `async let` concurrent group inside `startPolling()`, alongside `fetchMetrics()` and `fetchDocker()`, to avoid introducing sequential latency into the 3-second polling loop.

```swift
// Inside startPolling() loop:
async let _ = fetchMetrics()
async let _ = fetchDocker()
async let _ = fetchTmux()
```

---

### UI — `MiniWatcher/Views/TmuxView.swift`

New SwiftUI view added as the **5th content tab** in `MiniWatcherApp.swift`, inserted before the Settings tab.

**Tab:** `Label("Tmux", systemImage: "terminal")` — SF Symbols 2 (iOS 14+, matches app minimum deployment target)

**States:**
1. **Loading** (`tmuxAvailable == nil`) — `ProgressView`
2. **Unavailable** (`tmuxAvailable == false`) — `ContentUnavailableView("tmux not found on server")`
3. **Empty** (`tmuxAvailable == true`, sessions empty) — `ContentUnavailableView("No tmux sessions")`
4. **Session list** — `ScrollView` + `VStack` of session rows

**Session row layout:**
- Left: session name (bold), window count (`3 windows`), relative created time (`2h ago`)
- Right: attached badge (green `attached` / gray `detached`) + red Kill button
- Kill button shows a confirmation alert before calling `killTmuxSession`
- Kill button is disabled while kill is in flight via `@State private var isKilling: Bool = false` per-row guard (matching `isActioning` pattern in DockerView)

---

## Data Flow

```
MetricsService.startPolling() [every 3s, concurrent async let]
  └─ fetchTmux()
       └─ GET /tmux
            └─ subprocess (list form): tmux ls -F ...
                 └─ parse → TmuxResponse
                      └─ @Published tmuxSessions, tmuxAvailable
                           └─ TmuxView re-renders

TmuxView Kill button [user action, guarded by isKilling]
  └─ confirmation alert → MetricsService.killTmuxSession(name)
       └─ percent-encode name
       └─ POST /tmux/{encodedName}/kill
            └─ subprocess (list form): tmux kill-session -t {name}
                 └─ on success: fetchTmux() → immediate UI refresh
```

---

## Error Handling

| Scenario | Behavior |
|---|---|
| tmux not installed | `available: false` → show "tmux not found" |
| No sessions running | `available: true, sessions: []` → show "No tmux sessions" |
| Kill fails (session not found) | HTTP 400/500 → show error alert in TmuxView |
| Server unreachable | Existing `isConnected` handling covers this |
| First poll fails | `tmuxAvailable = false` → show "tmux not found" (avoids infinite spinner) |
| Session name with shell metacharacters | Backend validates and rejects with HTTP 400; client percent-encodes URL |
| Double-tap Kill button | `isKilling` guard disables button during in-flight request |

---

## Files Changed

| File | Change |
|---|---|
| `server/main.py` | Add `/tmux` GET and `/tmux/{session}/kill` POST |
| `MiniWatcher/Models/TmuxSession.swift` | New file |
| `MiniWatcher/Services/MetricsService.swift` | Add tmux properties and methods |
| `MiniWatcher/Views/TmuxView.swift` | New file |
| `MiniWatcher/MiniWatcherApp.swift` | Add Tmux tab (5th, before Settings) |
