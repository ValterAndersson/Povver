# tests/test_http_client.py
"""Tests for the shared Firebase Functions HTTP client.

Verifies auth headers, JSON body forwarding, response envelope
unwrapping, and error handling — end-to-end through the real
httpx request/response pipeline using httpx's MockTransport.
"""

import asyncio
import json

import httpx
import pytest

from app.http_client import FunctionsClient, FunctionsError


def _run(coro):
    """Helper to run async tests without pytest-asyncio."""
    return asyncio.run(coro)


def _mock_transport(handler):
    """Create an httpx.MockTransport from an async handler.

    The handler receives an ``httpx.Request`` and must return an
    ``httpx.Response``.  This lets us inspect the full outgoing
    request (headers, body, URL) while exercising httpx's real
    serialisation/deserialisation path.
    """
    return httpx.MockTransport(handler)


def _make_client(handler, **kwargs):
    """Build a FunctionsClient whose inner httpx client uses a mock transport."""
    client = FunctionsClient(
        base_url="https://example.com",
        api_key="test-key",
        **kwargs,
    )
    # Replace the real AsyncClient with one backed by MockTransport
    client._client = httpx.AsyncClient(transport=_mock_transport(handler))
    return client


# ---- Auth headers ----------------------------------------------------------


def test_get_includes_auth_headers_with_user_id():
    """GET sends x-api-key and x-user-id when user_id is provided."""

    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"ok": True})

    async def _test():
        client = _make_client(handler)
        await client.get("/health", user_id="u123")

    _run(_test())

    assert captured["headers"]["x-api-key"] == "test-key"
    assert captured["headers"]["x-user-id"] == "u123"


def test_get_omits_user_id_header_when_none():
    """GET omits x-user-id when user_id is not provided."""

    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"ok": True})

    async def _test():
        client = _make_client(handler)
        await client.get("/health")

    _run(_test())

    assert captured["headers"]["x-api-key"] == "test-key"
    assert "x-user-id" not in captured["headers"]


# ---- POST body ------------------------------------------------------------


def test_post_sends_json_body():
    """POST sends the body dict as JSON."""

    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        captured["headers"] = dict(request.headers)
        return httpx.Response(200, json={"data": {"id": "w1"}})

    async def _test():
        client = _make_client(handler)
        result = await client.post(
            "/logSet",
            user_id="u1",
            body={"workout_id": "w1", "reps": 8},
        )
        return result

    result = _run(_test())

    assert captured["body"] == {"workout_id": "w1", "reps": 8}
    assert captured["headers"]["x-user-id"] == "u1"
    # Also verify envelope unwrapping happened
    assert result == {"id": "w1"}


# ---- GET params ------------------------------------------------------------


def test_get_sends_query_params():
    """GET forwards params as query string."""

    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["url"] = str(request.url)
        return httpx.Response(200, json={"data": {"status": "active"}})

    async def _test():
        client = _make_client(handler)
        return await client.get("/getWorkout", params={"workout_id": "w99"})

    result = _run(_test())

    assert "workout_id=w99" in captured["url"]
    assert result == {"status": "active"}


# ---- Response envelope unwrapping ------------------------------------------


def test_unwraps_data_envelope():
    """Response {"data": {...}} is unwrapped to the inner dict."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={"data": {"items": [1, 2, 3]}},
        )

    async def _test():
        client = _make_client(handler)
        return await client.get("/list")

    result = _run(_test())
    assert result == {"items": [1, 2, 3]}


def test_returns_body_as_is_without_data_wrapper():
    """Response without a sole 'data' key is returned unchanged."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={"items": [1, 2, 3], "count": 3},
        )

    async def _test():
        client = _make_client(handler)
        return await client.get("/rawList")

    result = _run(_test())
    assert result == {"items": [1, 2, 3], "count": 3}


def test_does_not_unwrap_data_when_other_keys_present():
    """If 'data' key exists alongside other keys, don't unwrap."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={"data": {"id": "x"}, "meta": {"page": 1}},
        )

    async def _test():
        client = _make_client(handler)
        return await client.get("/mixed")

    result = _run(_test())
    assert result == {"data": {"id": "x"}, "meta": {"page": 1}}


# ---- Error handling --------------------------------------------------------


def test_non_2xx_raises_functions_error():
    """Non-2xx response raises FunctionsError with correct status code."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            404,
            json={"error": "Workout not found"},
        )

    async def _test():
        client = _make_client(handler)
        await client.get("/getWorkout", user_id="u1")

    with pytest.raises(FunctionsError) as exc_info:
        _run(_test())

    assert exc_info.value.status_code == 404
    assert exc_info.value.endpoint == "/getWorkout"
    assert "Workout not found" in exc_info.value.message


def test_error_response_includes_error_message():
    """Error JSON body {"error": "msg"} is included in the exception."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            500,
            json={"error": "Internal server error"},
        )

    async def _test():
        client = _make_client(handler)
        await client.post("/logSet", body={"x": 1})

    with pytest.raises(FunctionsError) as exc_info:
        _run(_test())

    assert exc_info.value.status_code == 500
    assert "Internal server error" in str(exc_info.value)


def test_error_with_plain_text_body():
    """Non-JSON error body is still captured."""

    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(502, text="Bad Gateway")

    async def _test():
        client = _make_client(handler)
        await client.get("/down")

    with pytest.raises(FunctionsError) as exc_info:
        _run(_test())

    assert exc_info.value.status_code == 502
    assert "Bad Gateway" in exc_info.value.message


# ---- Singleton -------------------------------------------------------------


def test_get_functions_client_returns_singleton():
    """get_functions_client returns the same instance on repeated calls."""
    import app.http_client as mod

    # Reset singleton
    mod._instance = None
    try:
        a = mod.get_functions_client()
        b = mod.get_functions_client()
        assert a is b
    finally:
        mod._instance = None
