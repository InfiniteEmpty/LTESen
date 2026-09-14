"""Configuration loading for the Python LTE sensing pipeline.

Configuration is deliberately represented as ordinary nested dictionaries.
This keeps YAML round-tripping simple while avoiding a second, incomplete
configuration object model during the staged rewrite.
"""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any, Mapping

import yaml


_DEFAULT_CONFIG_PATH = Path(__file__).resolve().parent / "config" / "default.yaml"


class ConfigError(ValueError):
    """Raised when a configuration file is missing or malformed."""


def load_config(
    path: str | Path | None = None,
    *,
    overrides: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Load the default or requested YAML configuration.

    ``overrides`` is merged recursively and is useful for experiments without
    modifying the checked-in default file. Keys are intentionally not renamed
    at runtime; the YAML file is the canonical Python-facing schema.
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
    if not isinstance(loaded, dict):
        raise ConfigError("The top-level YAML value must be a mapping")

    result = deepcopy(loaded)
    if overrides is not None:
        if not isinstance(overrides, Mapping):
            raise ConfigError("Configuration overrides must be a mapping")
        _deep_merge(result, overrides)
    _validate_config(result)
    return result


def _deep_merge(target: dict[str, Any], updates: Mapping[str, Any]) -> None:
    for key, value in updates.items():
        if isinstance(value, Mapping) and isinstance(target.get(key), dict):
            _deep_merge(target[key], value)
        else:
            target[key] = deepcopy(value)


def _validate_config(config: Mapping[str, Any]) -> None:
    required_sections = {
        "acquisition",
        "tracking",
        "sync",
        "cancellation",
        "range_doppler",
        "music",
        "display",
        "execution",
    }
    missing = required_sections.difference(config)
    if missing:
        names = ", ".join(sorted(missing))
        raise ConfigError(f"Missing configuration sections: {names}")

    for section in required_sections:
        if not isinstance(config[section], Mapping):
            raise ConfigError(f"Configuration section {section!r} must be a mapping")

    positive_paths = (
        ("acquisition", "head_start_sample"),
        ("acquisition", "search_duration_seconds"),
        ("cancellation", "ar_order"),
        ("cancellation", "warmup_frames"),
        ("range_doppler", "window_frames"),
        ("range_doppler", "hop_frames"),
        ("music", "covariance_order"),
        ("music", "signal_count"),
        ("music", "sample_interval_frames"),
    )
    for section, key in positive_paths:
        value = config[section].get(key)
        if not isinstance(value, (int, float)) or value <= 0:
            raise ConfigError(f"{section}.{key} must be positive")


__all__ = ["ConfigError", "load_config"]
