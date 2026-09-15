"""Generic YAML configuration loading and recursive override merging.

This module deliberately does not know which application modules consume the
configuration or which keys they require. Domain validation belongs to the
consumer that owns the corresponding configuration section.
"""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, Mapping

import yaml


_DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent / "default.yaml"


class ConfigError(ValueError):
    """Raised when a configuration file cannot be loaded as a mapping."""


def load_config(
    path: str | Path | None = None,
    *,
    overrides: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Load a YAML mapping and optionally merge nested override values.

    The loader validates only file/YAML/mapping mechanics. Unknown sections,
    unknown keys, and application-specific value constraints are intentionally
    preserved for the owning module to interpret.
    """

    config_path = Path(path) if path is not None else _DEFAULT_CONFIG_PATH
    if not config_path.is_file():
        raise ConfigError(f"Configuration file does not exist: {config_path}")
    try:
        with config_path.open("r", encoding="utf-8") as stream:
            loaded = yaml.safe_load(stream)
    except yaml.YAMLError as exc:
        raise ConfigError(f"Invalid YAML in {config_path}: {exc}") from exc

    if loaded is None:
        loaded = {}
    if not isinstance(loaded, Mapping):
        raise ConfigError("The top-level YAML value must be a mapping")

    result = deepcopy(dict(loaded))
    if overrides is not None:
        if not isinstance(overrides, Mapping):
            raise ConfigError("Configuration overrides must be a mapping")
        _deep_merge(result, overrides)
    return result


def _deep_merge(target: dict[str, Any], updates: Mapping[str, Any]) -> None:
    for key, value in updates.items():
        if isinstance(value, Mapping) and isinstance(target.get(key), dict):
            _deep_merge(target[key], value)
        else:
            target[key] = deepcopy(value)


__all__ = ["ConfigError", "load_config"]
