"""Fixed-size CSI frame ring buffer with a configurable output hop."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any

import numpy as np

from ..ltepipe import Packet
from ._array_shapes import as_csi_4d, complex_zeros_like


@dataclass
class WindowResult:
    available: bool = False
    data: np.ndarray | None = None
    first_meta: dict[str, Any] = field(default_factory=dict)
    last_meta: dict[str, Any] = field(default_factory=dict)


class FrameWindow:
    """Keep the most recent frames and emit them in chronological order."""

    def __init__(self, window_frames: int, hop_frames: int) -> None:
        if not isinstance(window_frames, int) or window_frames <= 0:
            raise ValueError("window_frames must be a positive integer")
        if not isinstance(hop_frames, int) or hop_frames <= 0:
            raise ValueError("hop_frames must be a positive integer")
        self.window_frames = window_frames
        self.hop_frames = hop_frames
        self.epoch: int | float | None = None
        self.count = 0
        self.frames_since_output = 0
        self._buffer: np.ndarray | None = None
        self._metadata: list[dict[str, Any] | None] = []
        self._write_index = -1
        self._last_end_sequence: int | float | None = None

    def push(self, frame_packet: Packet, field_name: str = "g1") -> WindowResult:
        packet = frame_packet if isinstance(frame_packet, Packet) else Packet.from_mapping(frame_packet)
        actual_field = _field_name(packet.data, field_name)
        self._validate_frame(packet, actual_field)
        meta = _normalise_metadata(packet.meta)
        if not _same_epoch(self.epoch, meta["epoch"]):
            self.reset(meta["epoch"], "new-epoch")
        if self.count > 0 and meta["sequence"] != self._last_end_sequence + 1:
            self.reset(meta["epoch"], "sequence-gap")

        frame = as_csi_4d(packet.data[actual_field], name=f"data.{field_name}")
        if self._buffer is None:
            shape = (*frame.shape, self.window_frames)
            self._buffer = complex_zeros_like(frame, shape)
            self._metadata = [None] * self.window_frames

        self._write_index = (self._write_index + 1) % self.window_frames
        assert self._buffer is not None
        self._buffer[..., self._write_index] = frame
        self._metadata[self._write_index] = meta
        self.count = min(self.count + 1, self.window_frames)
        self.frames_since_output += 1
        self._last_end_sequence = meta["end_sequence"]

        result = WindowResult()
        if self.count < self.window_frames or self.frames_since_output < self.hop_frames:
            return result

        indices = [
            (self._write_index - self.window_frames + 1 + offset) % self.window_frames
            for offset in range(self.window_frames)
        ]
        ordered = np.concatenate([self._buffer[..., index] for index in indices], axis=1)
        result.data = ordered
        result.first_meta = dict(self._metadata[indices[0]] or {})
        result.last_meta = dict(self._metadata[indices[-1]] or {})
        result.available = True
        self.frames_since_output = 0
        return result

    def reset(self, epoch: Any = None, reason: str = "") -> None:
        del reason
        self.epoch = epoch
        self.count = 0
        self.frames_since_output = 0
        self._buffer = None
        self._metadata = []
        self._write_index = -1
        self._last_end_sequence = None

    @staticmethod
    def _validate_frame(packet: Packet, field_name: str) -> None:
        if field_name not in packet.data:
            # Make the failure at the boundary clear rather than leaking KeyError.
            raise ValueError(f"Frame packet is missing data field {field_name!r}")
        required = ("epoch", "sequence", "end_sequence")
        if not all(key in packet.meta for key in required):
            matlab_required = ("Epoch", "Sequence", "EndSequence")
            if not all(key in packet.meta for key in matlab_required):
                raise ValueError("Input is not a valid CSI frame packet")


def _field_name(data: Any, field_name: str) -> str:
    if field_name in data:
        return field_name
    matlab_name = {
        "g1": "G1",
        "g2": "G2",
        "dynamic_g1": "DynamicG1",
        "dynamic_g2": "DynamicG2",
    }.get(field_name, field_name)
    if matlab_name in data:
        return matlab_name
    for python_name, candidate in {
        "g1": "G1",
        "g2": "G2",
        "dynamic_g1": "DynamicG1",
        "dynamic_g2": "DynamicG2",
    }.items():
        if field_name == candidate and python_name in data:
            return python_name
    raise ValueError(f"Frame packet is missing data field {field_name!r}")


def _normalise_metadata(metadata: Any) -> dict[str, Any]:
    aliases = {
        "epoch": "Epoch",
        "sequence": "Sequence",
        "end_sequence": "EndSequence",
    }
    result: dict[str, Any] = {}
    for python_name, matlab_name in aliases.items():
        if python_name in metadata:
            result[python_name] = metadata[python_name]
        elif matlab_name in metadata:
            result[python_name] = metadata[matlab_name]
        else:
            raise ValueError("Input is not a valid CSI frame packet")
    result.update(metadata)
    return result


def _same_epoch(left: Any, right: Any) -> bool:
    if left == right:
        return True
    return (
        isinstance(left, (float, np.floating))
        and isinstance(right, (float, np.floating))
        and math.isnan(left)
        and math.isnan(right)
    )


__all__ = ["FrameWindow", "WindowResult"]
