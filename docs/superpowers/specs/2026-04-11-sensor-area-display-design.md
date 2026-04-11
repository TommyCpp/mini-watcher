# Sensor Area as Primary Name

## Problem

The Home tab tiles (`RoomTileView`) currently display each sensor's Home Assistant friendly name (e.g. "Meter Plus 345D"). The friendly name is a device model/serial label and carries no meaning to the user — the user thinks in rooms, not device IDs. The sensor's HA *area* is the meaningful label and should be the primary name on every surface in the iOS app that already shows the sensor name.

## Goal

Use the HA area of each temperature sensor as its display name throughout the iOS app, with a graceful fallback to the current friendly name when the area is unknown.

## Non-goals

- Grouping tiles by area (one area = one section). Tiles remain a flat grid sorted by temperature.
- Handling multiple temperature sensors in the same area. If the user has two sensors in one area both tiles will simply show the same name. Revisit only if it becomes a real problem.
- Surfacing area anywhere other than the existing name slot. No new badges, subtitles, or filters.
- Fetching areas for non-temperature sensors (weather, sun, etc.).

## Approach

HA's REST `/api/states` endpoint does **not** include `area_id` or area name in entity attributes. Area membership lives in the entity / device / area registries, normally accessed via WebSocket. To stay on the existing REST polling architecture, the app will use HA's `POST /api/template` endpoint to render a single Jinja template that returns a JSON map of `entity_id → area name` for every temperature sensor.

Template body:

```jinja
{% set ns = namespace(d={}) %}
{% for s in states.sensor if s.attributes.device_class == 'temperature' %}
{% set ns.d = dict(ns.d, **{s.entity_id: (area_name(s.entity_id) or '')}) %}
{% endfor %}
{{ ns.d | tojson }}
```

The response is a JSON string (a dict) that the app parses into `[String: String]` and applies to matching sensors.

## Changes

### `Models/RoomSensor.swift`

- Add `var area: String? = nil`.
- Change `displayName` to return `area` when non-nil/non-empty, otherwise fall back to the current friendly-name cleaning logic.

### `Services/HomeAssistantService.swift`

- Add a private method `fetchAreas(for entityIds: [String]) async -> [String: String]` that:
  - Returns early with `[:]` if the token is empty or there are no entity IDs.
  - `POST`s to `\(baseURL)/api/template` with `Authorization: Bearer \(haToken)` and JSON body `{"template": "..."}` (the template above).
  - Decodes the response body (a JSON string) into `[String: String]`, mapping empty values to omitted keys.
  - Returns `[:]` on any error (no error propagation, no `errorMessage` mutation).
- At the end of `fetchSensors()`, after `parseStates(states)` succeeds and `rooms` has been rebuilt, collect `rooms.compactMap(\.temperatureEntityId)`, call `fetchAreas(for:)`, and assign `room.area` for each matching entity ID. Keep the existing sort (by temperature desc).
- Area fetch failures must **not** affect `isConnected` or `errorMessage`. If the template call fails, tiles simply keep falling back to friendly names.

### UI (no changes)

`RoomTileView`, `RoomDetailView`, and `HomeView.compareBars` already use `room.displayName`. Once the model change lands, they automatically show the area.

## Error handling & edge cases

- **Template call fails / times out**: silently fall back. The main `fetchSensors()` success path is unaffected.
- **`area_name()` returns empty for a sensor**: treated as nil, falls back to friendly name for that tile only.
- **Two sensors share one area**: both tiles show the same name (accepted for v1).
- **Token not configured**: `fetchAreas` short-circuits; main guard in `fetchSensors()` already handles this.

## Testing

Manual verification on the real device (simulator cannot reach the user's HA instance):

1. Launch app with valid HA token, confirm tiles now show room names (e.g. "Living Room", "Bedroom") instead of device model names.
2. Temporarily rename an area in HA, pull to refresh, confirm tile updates on next poll.
3. Temporarily revoke the token or stop HA, confirm no crash and tiles still render (either with stale area or with friendly-name fallback).
4. Confirm the compare-bars section on the Home tab also shows area names as labels.

No automated tests — the project has none in this area and the change is small enough that manual verification is appropriate.
