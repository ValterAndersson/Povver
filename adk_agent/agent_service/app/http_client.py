# app/http_client.py
"""Shared HTTP client for Firebase Functions calls.

Provides connection pooling, auth headers, and response unwrapping
so that skill files don't each create inline httpx.AsyncClient instances.

Firebase Functions wrap responses in ``ok(res, data)`` which produces
``{"data": ...}`` — this client unwraps that envelope automatically.
"""

from __future__ import annotations

import logging
import os

import httpx

logger = logging.getLogger(__name__)

_instance: "FunctionsClient | None" = None


def get_functions_client() -> FunctionsClient:
    """Module-level singleton — reuses TCP connections across requests."""
    global _instance
    if _instance is None:
        _instance = FunctionsClient()
    return _instance


class FunctionsError(Exception):
    """Raised when a Firebase Function returns a non-2xx response."""

    def __init__(self, status_code: int, message: str, endpoint: str) -> None:
        self.status_code = status_code
        self.message = message
        self.endpoint = endpoint
        super().__init__(f"{endpoint} returned {status_code}: {message}")


class FunctionsClient:
    """Async HTTP client for Firebase Functions with connection pooling.

    Args:
        base_url: Firebase Functions base URL.
            Defaults to ``MYON_FUNCTIONS_BASE_URL`` env var.
        api_key: Server-to-server API key.
            Defaults to ``MYON_API_KEY`` env var.
        timeout: Request timeout in seconds (default 5.0).
    """

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        timeout: float = 5.0,
    ) -> None:
        self.base_url = (
            base_url
            or os.getenv(
                "MYON_FUNCTIONS_BASE_URL",
                "https://us-central1-myon-53d85.cloudfunctions.net",
            )
        )
        self.api_key = api_key or os.getenv("MYON_API_KEY", "")
        self._client = httpx.AsyncClient(timeout=timeout)

    # -- public API ----------------------------------------------------------

    async def get(
        self,
        path: str,
        user_id: str | None = None,
        params: dict | None = None,
    ) -> dict:
        """GET ``{base_url}{path}`` with auth headers."""
        resp = await self._client.get(
            f"{self.base_url}{path}",
            headers=self._headers(user_id),
            params=params,
        )
        return self._handle_response(resp, path)

    async def post(
        self,
        path: str,
        user_id: str | None = None,
        body: dict | None = None,
    ) -> dict:
        """POST ``{base_url}{path}`` with JSON body and auth headers."""
        resp = await self._client.post(
            f"{self.base_url}{path}",
            headers=self._headers(user_id),
            json=body,
        )
        return self._handle_response(resp, path)

    # -- internals -----------------------------------------------------------

    def _headers(self, user_id: str | None = None) -> dict[str, str]:
        headers: dict[str, str] = {
            "Content-Type": "application/json",
            "x-api-key": self.api_key,
        }
        if user_id is not None:
            headers["x-user-id"] = user_id
        return headers

    @staticmethod
    def _handle_response(resp: httpx.Response, path: str) -> dict:
        """Raise on non-2xx; unwrap ``{"data": ...}`` envelope if present."""
        if not resp.is_success:
            # Try to extract error message from response body
            try:
                body = resp.json()
                message = body.get("error", resp.text)
            except Exception:
                message = resp.text
            raise FunctionsError(resp.status_code, message, path)

        body = resp.json()

        # Firebase Functions wrap successful responses in {"data": ...}
        if isinstance(body, dict) and "data" in body and len(body) == 1:
            return body["data"]
        return body
