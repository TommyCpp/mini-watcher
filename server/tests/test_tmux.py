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
