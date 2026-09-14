"""Small human-readable status printer."""

from __future__ import annotations

from typing import Any


def print_status(summary: dict[str, Any]) -> None:
    modules = summary.get("modules", [])
    print(f"Modules ({len(modules)}):")
    for index, module in enumerate(modules, start=1):
        print(f"[{index}] {module['name']} ({module['class']})")
    print(f"Runtime: {summary.get('runtime', {})}")
    print(f"ContextKeys: {summary.get('runtime', {}).get('context_keys', [])}")


__all__ = ["print_status"]
