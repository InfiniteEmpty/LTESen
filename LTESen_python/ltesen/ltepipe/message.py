"""Typed messages exchanged by pipeline modules."""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Any, Mapping


class MessageError(ValueError):
    """Raised when a message, packet, or artifact violates the contract."""


@dataclass(frozen=True)
class Packet:
    """A primary pipeline packet.

    ``data``, ``meta``, and ``quality`` stay open dictionaries because later
    phases will introduce several domain-specific packet types.
    """

    type: str
    data: Mapping[str, Any]
    meta: Mapping[str, Any]
    quality: Mapping[str, Any]

    def __post_init__(self) -> None:
        if not isinstance(self.type, str) or not self.type.strip():
            raise MessageError("Packets must have a non-empty string type")
        for name in ("data", "meta", "quality"):
            if not isinstance(getattr(self, name), Mapping):
                raise MessageError(f"Packet {name} must be a mapping")

    @classmethod
    def from_mapping(cls, packet: Mapping[str, Any]) -> "Packet":
        """Convert a packet mapping, accepting MATLAB-style field names too."""

        if not isinstance(packet, Mapping):
            raise MessageError("Packets must be mappings or Packet instances")
        values = {}
        for python_name, matlab_name in (
            ("type", "Type"),
            ("data", "Data"),
            ("meta", "Meta"),
            ("quality", "Quality"),
        ):
            if python_name in packet:
                values[python_name] = packet[python_name]
            elif matlab_name in packet:
                values[python_name] = packet[matlab_name]
            else:
                raise MessageError(
                    "Packets must contain type, data, meta, and quality fields"
                )
        return cls(**values)


def ensure_packet(packet: Packet | Mapping[str, Any]) -> Packet:
    return packet if isinstance(packet, Packet) else Packet.from_mapping(packet)


@dataclass(frozen=True)
class Message:
    """A packet plus zero or more side-channel artifacts."""

    has_packet: bool = False
    packet: Packet | None = None
    artifacts: tuple[Any, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        if not isinstance(self.has_packet, bool):
            raise MessageError("has_packet must be a bool")
        if not isinstance(self.artifacts, tuple):
            object.__setattr__(self, "artifacts", tuple(self.artifacts))
        if self.has_packet:
            if self.packet is None:
                raise MessageError("A message with has_packet=True needs a packet")
            if not isinstance(self.packet, Packet):
                object.__setattr__(self, "packet", ensure_packet(self.packet))
        elif self.packet is not None:
            raise MessageError("A message without a packet must use packet=None")

    @classmethod
    def none(cls) -> "Message":
        return cls()

    @classmethod
    def from_packet(cls, packet: Packet | Mapping[str, Any]) -> "Message":
        return cls(True, ensure_packet(packet))

    def replace_packet(self, packet: Packet | Mapping[str, Any]) -> "Message":
        return replace(self, has_packet=True, packet=ensure_packet(packet))

    def clear_packet(self) -> "Message":
        return replace(self, has_packet=False, packet=None)

    def add_artifact(self, artifact: Any) -> "Message":
        if not isinstance(artifact, Mapping) or not (
            "type" in artifact or "Type" in artifact
        ):
            raise MessageError("Artifacts must be mappings with a type field")
        return replace(self, artifacts=self.artifacts + (artifact,))

    @property
    def has_content(self) -> bool:
        return self.has_packet or bool(self.artifacts)

    @property
    def packet_type(self) -> str:
        return self.packet.type if self.has_packet and self.packet else ""


def validate_message(message: Message) -> None:
    if not isinstance(message, Message):
        raise MessageError("Pipeline messages must be Message instances")
    if message.has_packet and message.packet is None:
        raise MessageError("A message with a packet must set has_packet=True")


__all__ = ["Message", "MessageError", "Packet", "ensure_packet", "validate_message"]
