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
Calls `tmux ls -F '#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}'` via subprocess. Returns:

```json
{
  "available": true,
  "sessions": [
    {
      "name": "main",
      "windows": 3,
      "created": 1710000000.0,
      "attached": true
    }
  ]
}
```

If tmux is not installed or returns a non-zero exit code with "no server running", returns `{ "available": false, "sessions": [] }`.

**`POST /tmux/{session}/kill`**
Calls `tmux kill-session -t {session}`. Returns `{ "success": true }` or raises HTTP 400/500 on failure.

---

### Data Model — `MiniWatcher/Models/TmuxSession.swift`

```swift
struct TmuxSession: Codable, Identifiable {
    let name: String
    let windows: Int
    let created: Double
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
@Published var tmuxAvailable: Bool? = nil
```

New methods:
- `fetchTmux()` — `GET /tmux`, updates `tmuxSessions` and `tmuxAvailable`
- `killTmuxSession(_ name: String) async throws` — `POST /tmux/{name}/kill`

`fetchTmux()` is called inside the existing `startPolling()` 3-second loop alongside `fetchDocker()`.

---

### UI — `MiniWatcher/Views/TmuxView.swift`

New SwiftUI view added as the 6th tab in `MiniWatcherApp.swift`.

**Tab:** `Label("Tmux", systemImage: "terminal")`

**States:**
1. **Loading** — `ProgressView`
2. **Unavailable** — `ContentUnavailableView` with message "tmux not found on server"
3. **Empty** — `ContentUnavailableView` with message "No tmux sessions"
4. **Session list** — `ScrollView` + `VStack` of session rows

**Session row layout:**
- Left: session name (bold), window count (`3 windows`), relative created time (`2h ago`)
- Right: attached badge (green `attached` / gray `detached`) + red Kill button
- Kill button shows a confirmation alert before calling `killTmuxSession`

---

## Data Flow

```
MetricsService.startPolling() [every 3s]
  └─ fetchTmux()
       └─ GET /tmux
            └─ subprocess: tmux ls -F ...
                 └─ parse → TmuxResponse
                      └─ @Published tmuxSessions, tmuxAvailable
                           └─ TmuxView re-renders

TmuxView Kill button [user action]
  └─ MetricsService.killTmuxSession(name)
       └─ POST /tmux/{name}/kill
            └─ subprocess: tmux kill-session -t {name}
                 └─ fetchTmux() triggered to refresh list
```

---

## Error Handling

| Scenario | Behavior |
|---|---|
| tmux not installed | `available: false` → show "tmux not found" |
| No sessions running | `sessions: []` → show "No tmux sessions" |
| Kill fails (session not found) | Show error alert in TmuxView |
| Server unreachable | Existing `isConnected` handling covers this |

---

## Files Changed

| File | Change |
|---|---|
| `server/main.py` | Add `/tmux` GET and `/tmux/{session}/kill` POST |
| `MiniWatcher/Models/TmuxSession.swift` | New file |
| `MiniWatcher/Services/MetricsService.swift` | Add tmux properties and methods |
| `MiniWatcher/Views/TmuxView.swift` | New file |
| `MiniWatcher/MiniWatcherApp.swift` | Add Tmux tab |
