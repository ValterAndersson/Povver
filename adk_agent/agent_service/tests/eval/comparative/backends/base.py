# base.py
from __future__ import annotations
from typing import Protocol, Union
from comparative.test_cases import SingleTurnCase, MultiTurnCase
from comparative.models import BackendResponse

AnyCase = Union[SingleTurnCase, MultiTurnCase]


class EvalBackend(Protocol):
    """Protocol for eval backends."""

    async def run_case(self, case: AnyCase, user_id: str) -> BackendResponse:
        """Run a test case and return the response."""
        ...

    @property
    def name(self) -> str:
        """Backend name for logging/results."""
        ...
