# conftest.py
"""Root conftest — stubs out google.cloud.firestore so tests run without the SDK installed."""

import sys
from unittest.mock import MagicMock

# Stub the entire google.cloud.firestore package before any test imports it.
_mock_firestore = MagicMock()
sys.modules.setdefault("google", _mock_firestore)
sys.modules.setdefault("google.cloud", _mock_firestore)
sys.modules.setdefault("google.cloud.firestore", _mock_firestore)
