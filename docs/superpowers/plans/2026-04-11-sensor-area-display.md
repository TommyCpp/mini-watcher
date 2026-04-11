# Sensor Area Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Home Assistant sensor friendly names with their *area* names as the primary display label across the Home tab of the iOS app, with a graceful fallback when the area is unavailable.

**Architecture:** `RoomSensor` gains an optional `area` field and uses it as `displayName` when present. `HomeAssistantService.fetchSensors()` makes one extra `POST /api/template` call per poll to retrieve an `entity_id → area` map via HA's Jinja template endpoint, then assigns the result to each room. All existing views (`RoomTileView`, `RoomDetailView`, `HomeView.compareBars`) already read `displayName` and pick up the change automatically.

**Tech Stack:** Swift / SwiftUI (iOS 26, iPhone target), Home Assistant REST API (`/api/states`, `/api/template`), `URLSession`, `JSONDecoder`, `xcodebuild` + `xcrun devicectl` for on-device deploy.

**Testing note:** This project has no automated test target. Per the spec, verification is manual on the connected device at the end of the plan. TDD steps are therefore replaced with "implement + inspect + manual verify on device" steps.

**Spec:** `docs/superpowers/specs/2026-04-11-sensor-area-display-design.md`

---

### Task 1: Add `area` to `RoomSensor` and make it the primary display name

**Files:**
- Modify: `MiniWatcher/Models/RoomSensor.swift:4-31`

- [ ] **Step 1: Add the `area` field**

In `MiniWatcher/Models/RoomSensor.swift`, add a new stored property just above `temperatureHistory`. The full property block of the struct should read:

```swift
struct RoomSensor: Identifiable {
    let id: String // device name, e.g. "meter_plus_345d"
    var friendlyName: String // e.g. "Meter Plus 345D"
    var area: String? = nil
    var temperature: Double?
    var humidity: Double?
    var battery: Double?
    var temperatureUnit: String = "°C"
    var temperatureEntityId: String?
    var isAvailable: Bool { temperature != nil }
    var temperatureHistory: [HAHistoryPoint] = []
```

Leave all other fields and methods untouched for this step.

- [ ] **Step 2: Update `displayName` to prefer `area`**

Replace the existing `displayName` computed property with this exact implementation:

```swift
    var displayName: String {
        if let area = area, !area.isEmpty {
            return area
        }
        return friendlyName
            .replacingOccurrences(of: " Temperature", with: "")
            .replacingOccurrences(of: " Humidity", with: "")
            .replacingOccurrences(of: " Battery", with: "")
    }
```

- [ ] **Step 3: Confirm the file compiles (syntactic sanity)**

Run from the repo root:

```bash
xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' -quiet build-for-testing 2>&1 | tail -40
```

Expected: build succeeds (or fails only on later-task errors unrelated to this file). Any error that mentions `RoomSensor.swift` must be fixed before moving on.

- [ ] **Step 4: Commit**

```bash
git add MiniWatcher/Models/RoomSensor.swift
git commit -m "$(cat <<'EOF'
feat(model): add area field to RoomSensor and prefer it in displayName

area falls back to the cleaned HA friendly name when nil/empty so
existing behavior is preserved until the service layer populates it.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Fetch area names via HA `/api/template` and assign to rooms

**Files:**
- Modify: `MiniWatcher/Services/HomeAssistantService.swift:81-113` (fetchSensors)
- Modify: `MiniWatcher/Services/HomeAssistantService.swift:186-190` (helper region)

- [ ] **Step 1: Add `fetchAreas(for:)` helper**

Insert the following method into `HomeAssistantService`, placed immediately *after* `parseISO8601(_:)` and *before* `fetchHistory(for:)` (roughly around line 191 in the current file). Add it verbatim:

```swift
    private func fetchAreas(for entityIds: [String]) async -> [String: String] {
        guard !haToken.isEmpty, !entityIds.isEmpty else { return [:] }
        guard let url = URL(string: "\(baseURL)/api/template") else { return [:] }

        let template = """
        {% set ns = namespace(d={}) %}\
        {% for s in states.sensor if s.attributes.device_class == 'temperature' %}\
        {% set ns.d = dict(ns.d, **{s.entity_id: (area_name(s.entity_id) or '')}) %}\
        {% endfor %}\
        {{ ns.d | tojson }}
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(haToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["template": template]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return [:] }
        request.httpBody = encoded

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            // Response body is a raw JSON string (a dict), e.g. {"sensor.x":"Living Room","sensor.y":""}
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            return decoded.filter { !$0.value.isEmpty }
        } catch {
            return [:]
        }
    }
```

Notes:
- Failures return `[:]` silently — they must not mutate `isConnected` or `errorMessage`. This is intentional per the spec.
- The trailing `\` on each template line strips newlines so the Jinja expression is a single line inside the JSON string (HA's template engine is whitespace-tolerant but we want the body to stay small and unambiguous).

- [ ] **Step 2: Call `fetchAreas` at the end of `fetchSensors`**

In `fetchSensors()`, extend the `do` block so that after `parseStates(states)` succeeds, it also fetches and applies areas. Replace the current `do { ... }` block with this exact version:

```swift
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Auth failed (check token)"
                isConnected = false
                return
            }
            let states = try JSONDecoder().decode([HAState].self, from: data)
            parseStates(states)

            let entityIds = rooms.compactMap(\.temperatureEntityId)
            let areas = await fetchAreas(for: entityIds)
            if !areas.isEmpty {
                rooms = rooms.map { room in
                    var updated = room
                    if let eid = room.temperatureEntityId, let area = areas[eid] {
                        updated.area = area
                    }
                    return updated
                }
            }

            isConnected = true
            errorMessage = nil
        } catch is CancellationError {
            // ignore
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }
```

Important: the sort order established by `parseStates` (temperature desc) is preserved because `rooms.map` keeps array order.

- [ ] **Step 3: Build to verify both files compile**

Run:

```bash
xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' -quiet build 2>&1 | tail -60
```

Expected: `BUILD SUCCEEDED`. If not, read the first error and fix — common causes will be a typo in the template literal or missing `Content-Type` header.

- [ ] **Step 4: Commit**

```bash
git add MiniWatcher/Services/HomeAssistantService.swift
git commit -m "$(cat <<'EOF'
feat(ha): fetch sensor area names via /api/template

After each successful /api/states poll, POST a Jinja template to
/api/template to retrieve an entity_id -> area_name map for every
temperature sensor, then populate RoomSensor.area. Failures are
silent so the main Home tab stays healthy if the template endpoint
hiccups.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Deploy to the connected iPhone and manually verify

**Files:** none (build + device install)

- [ ] **Step 1: Invoke the `deploy-ios` skill**

Use the `Skill` tool with `skill: "deploy-ios"`. The skill handles xcodebuild + `xcrun devicectl device install app` against the connected iPhone. Follow its instructions exactly — do **not** run `xcodegen generate` (the user's global rule: only run it when `project.yml` changes).

- [ ] **Step 2: Manual verification on device**

With the app running on the physical iPhone, open the **Home** tab and confirm each point:

1. Every tile's large temperature number is now headed by the **room/area name** (e.g. "Living Room", "Bedroom"), not a "Meter Plus ..." string.
2. The Compare Temperature bars at the bottom use the same area labels.
3. Tapping a tile opens `RoomDetailView` and the detail header also shows the area name.
4. If any sensor has no area assigned in HA, that tile gracefully falls back to the cleaned friendly name (no crash, no empty label).
5. Pull-to-refresh still works and `isConnected` stays true (no new error banner).

If any of 1–5 fails, stop and debug before reporting complete.

- [ ] **Step 3: Report status to the user**

Report which of the five checks passed and show a photo/description of the Home tab. Do not claim success unless all five checks pass.

---

## Self-Review

- **Spec coverage**
  - "Use area as displayName with fallback" → Task 1, Step 2 ✓
  - "Add `area` field to `RoomSensor`" → Task 1, Step 1 ✓
  - "Add `fetchAreas` method to `HomeAssistantService`" → Task 2, Step 1 ✓
  - "Call fetchAreas after parseStates, assign area per sensor, preserve sort" → Task 2, Step 2 ✓
  - "Area fetch failure must not affect isConnected/errorMessage" → Task 2, Step 1 notes + Step 2 (failures return empty dict, no early exit) ✓
  - "UI files unchanged" → confirmed, no task touches them ✓
  - "Manual verification on device" → Task 3 ✓

- **Placeholders:** none. Every code block is complete and runnable.

- **Type consistency:** `fetchAreas(for:)` returns `[String: String]` and is consumed as `[String: String]` in `fetchSensors`. `RoomSensor.area` is `String?` and is assigned from `areas[eid]` (non-optional `String` from the dict subscript inside the `if let`). `temperatureEntityId` is used consistently as the join key in both the model and service.
