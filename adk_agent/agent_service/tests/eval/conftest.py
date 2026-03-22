import sys
from pathlib import Path

# Add tests/eval/ to sys.path so "comparative" is importable
sys.path.insert(0, str(Path(__file__).parent))
