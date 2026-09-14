"""Uniform results returned from pipeline modules."""

from __future__ import annotations

from dataclasses import dataclass, replace
from typing import Any, Literal, Sequence

from .message import Message, MessageError, Packet, validate_message

Directive = Literal["continue", "reset-downstream", "stop"]


class ResultError(ValueError):
    """Raised when a module returns an invalid result."""


@dataclass(frozen=True)
class Result:
    message: Message
    directive: Directive = "continue"
    epoch: int | float | None = None
    reason: str = ""
    commands: tuple[Any, ...] = ()

    def __post_init__(self) -> None:
        validate_message(self.message)
        if self.directive not in ("continue", "reset-downstream", "stop"):
            raise ResultError(f"Unsupported pipeline directive: {self.directive}")
        if not isinstance(self.reason, str):
            raise ResultError("Result reason must be a string")
        if not isinstance(self.commands, tuple):
            object.__setattr__(self, "commands", tuple(self.commands))
        if self.directive == "reset-downstream" and self.epoch is None:
            raise ResultError("A downstream reset must contain an epoch")

    @classmethod
    def forward(cls, message: Message) -> "Result":
        validate_message(message)
        return cls(message=message)

    @classmethod
    def emit(cls, packet: Packet | dict[str, Any]) -> "Result":
        return cls.forward(Message.from_packet(packet))

    @classmethod
    def reset_downstream(
        cls, message: Message, epoch: int | float, reason: str
    ) -> "Result":
        return cls(message=message, directive="reset-downstream", epoch=epoch, reason=reason)

    @classmethod
    def stop(cls, message: Message, reason: str) -> "Result":
        return cls(message=message, directive="stop", reason=reason)

    def with_commands(self, commands: Sequence[Any] | Any) -> "Result":
        if isinstance(commands, (str, bytes)) or not isinstance(commands, Sequence):
            commands = (commands,)
        return replace(self, commands=tuple(commands))


def validate_result(result: Result) -> None:
    if not isinstance(result, Result):
        raise ResultError("A module must return a Result instance")
    # Dataclass construction performs the rest of the validation. This helper
    # gives Pipeline a symmetric explicit validation hook.
    validate_message(result.message)


__all__ = ["Directive", "Result", "ResultError", "validate_result"]
