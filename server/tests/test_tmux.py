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
