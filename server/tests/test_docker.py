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
