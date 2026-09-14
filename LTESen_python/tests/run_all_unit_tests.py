"""Run the Python unit-test tree, analogous to MATLAB's test runner."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


def main() -> int:
    tests_root = Path(__file__).resolve().parent
    project_root = tests_root.parent
    suite = unittest.defaultTestLoader.discover(
        str(tests_root / "unit"), pattern="test_*.py", top_level_dir=str(project_root)
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
