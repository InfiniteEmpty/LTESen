"""Shared initialization context and services."""

from __future__ import annotations

from typing import Any


class Runtime:
    def __init__(self) -> None:
        self._context: dict[str, Any] = {}
        self._services: dict[str, Any] = {}

    @staticmethod
    def _validate_key(key: str) -> str:
        if not isinstance(key, str) or not key.isidentifier():
            raise ValueError("Runtime keys must be valid Python identifiers")
        return key

    def set_context(self, key: str, value: Any) -> None:
        self._context[self._validate_key(key)] = value

    def get_context(self, key: str) -> Any:
        key = self._validate_key(key)
        if key not in self._context:
            raise KeyError(f'Runtime context "{key}" is not available')
        return self._context[key]

    def add_service(self, key: str, value: Any) -> None:
        key = self._validate_key(key)
        if key in self._services:
            raise ValueError(f'Runtime service "{key}" is already registered')
        self._services[key] = value

    def get_service(self, key: str) -> Any:
        key = self._validate_key(key)
        if key not in self._services:
            raise KeyError(f'Runtime service "{key}" is not available')
        return self._services[key]

    def get_status(self) -> dict[str, Any]:
        services: dict[str, Any] = {}
        for key, service in self._services.items():
            get_status = getattr(service, "get_status", None)
            services[key] = (
                get_status() if callable(get_status) else {"class": type(service).__name__}
            )
        return {"context_keys": sorted(self._context), "services": services}


__all__ = ["Runtime"]
