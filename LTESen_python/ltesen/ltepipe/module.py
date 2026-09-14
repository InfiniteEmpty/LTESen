"""Base class for modules participating in the streaming pipeline."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

from .message import Message, MessageError, Packet, validate_message
from .result import Result
from .runtime import Runtime


class Module(ABC):
    def __init__(
        self,
        name: str,
        input_type: str | None,
        output_type: str | None,
    ) -> None:
        if not isinstance(name, str) or not name.isidentifier():
            raise ValueError("Module names must be valid Python identifiers")
        self.name = name
        self.input_type = input_type or ""
        self.output_type = output_type or ""
        self.runtime: Runtime | None = None

    def initialize(self, runtime: Runtime) -> None:
        self.runtime = runtime

    def reset(self, event: Any = None) -> None:
        del event

    def finalize(self, reason: str) -> Result:
        del reason
        return Result.forward(Message.none())

    def get_status(self) -> dict[str, Any]:
        return {"state": "ready", "ready": True}

    def handle_command(self, command: Any) -> None:
        command_type = command.get("type", command.get("Type", "<invalid>")) \
            if isinstance(command, dict) else "<invalid>"
        raise ValueError(
            f'Module "{self.name}" does not support command "{command_type}"'
        )

    def validate_input(self, message: Message) -> None:
        validate_message(message)
        if message.has_packet and self.input_type and message.packet_type != self.input_type:
            raise MessageError(
                f'Module "{self.name}" expected "{self.input_type}" '
                f'but received "{message.packet_type}"'
            )

    def replace_output(self, message: Message, packet: Packet) -> Message:
        if self.output_type and packet.type != self.output_type:
            raise MessageError(
                f'Module "{self.name}" produced "{packet.type}" '
                f'instead of "{self.output_type}"'
            )
        return message.replace_packet(packet)

    @abstractmethod
    def process(self, message: Message) -> Result:
        """Process one message and return the next pipeline result."""


__all__ = ["Module"]
