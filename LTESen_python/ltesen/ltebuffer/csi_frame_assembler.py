"""Assemble ten consecutive CSI subframes into a complete LTE frame."""

from __future__ import annotations

import math
from typing import Any

import numpy as np

from ..ltepipe import Message, Module, Packet, Result
from ._array_shapes import as_csi_4d, complex_zeros_like


class CsiFrameAssembler(Module):
    """Collect subframes 0..9, rejecting epochs and sequence gaps."""

    _FIELDS = ("g1", "g2", "dynamic_g1", "dynamic_g2")
    _MATLAB_FIELDS = {
        "g1": "G1",
        "g2": "G2",
        "dynamic_g1": "DynamicG1",
        "dynamic_g2": "DynamicG2",
    }

    def __init__(self) -> None:
        super().__init__("frame_assembler", "csi-subframe", "csi-frame")
        self.epoch: int | float | None = None
        self.buffered_subframes = 0
        self.emitted_frames = 0
        self.dropped_partial_frames = 0
        self._buffer: dict[str, np.ndarray] | None = None
        self._first_meta: dict[str, Any] | None = None
        self._expected_sequence: int | float | None = None

    def process(self, message: Message) -> Result:
        self.validate_input(message)
        if not message.has_packet:
            return Result.forward(message)
        assert message.packet is not None
        self._validate_packet(message.packet)
        packet = message.packet
        meta = _normalise_metadata(packet.meta)

        if not _same_epoch(self.epoch, meta["epoch"]):
            self.reset({"epoch": meta["epoch"], "reason": "new-epoch"})
        if (
            self.buffered_subframes > 0
            and meta["sequence"] != self._expected_sequence
        ):
            self._discard_partial()
        if (
            self.buffered_subframes > 0
            and meta["subframe_number"] != self.buffered_subframes
        ):
            self._discard_partial()

        if self.buffered_subframes == 0:
            if meta["subframe_number"] != 0:
                return Result.forward(message.clear_packet())
            self._allocate(packet.data)
            self._first_meta = meta

        assert self._buffer is not None
        column_start = int(meta["subframe_number"]) * 2
        for field in self._FIELDS:
            subframe = as_csi_4d(
                _mapping_field(packet.data, field, self._MATLAB_FIELDS[field]),
                name=f"data.{field}",
            )
            target = self._buffer[field]
            if subframe.shape[0] != target.shape[0] or subframe.shape[1] != 2:
                raise ValueError(f"data.{field} has incompatible subframe shape {subframe.shape}")
            if subframe.shape[2:] != target.shape[2:]:
                raise ValueError(f"data.{field} has incompatible antenna dimensions")
            target[:, column_start : column_start + 2, :, :] = subframe

        self.buffered_subframes += 1
        self._expected_sequence = meta["sequence"] + 1
        result = Result.forward(message.clear_packet())
        if meta["subframe_number"] != 9:
            return result

        assert self._first_meta is not None
        frame_meta = dict(self._first_meta)
        frame_meta["raw_end_sample_0"] = meta["raw_end_sample_0"]
        frame_meta["end_sequence"] = meta["sequence"]
        frame_meta.pop("subframe_number", None)
        output = Packet(
            type="csi-frame",
            data=self._buffer,
            meta=frame_meta,
            quality={"complete": True, "subframe_count": self.buffered_subframes},
        )
        result = Result.forward(self.replace_output(result.message, output))
        self.emitted_frames += 1
        self._clear_partial()
        return result

    def reset(self, event: Any = None) -> None:
        epoch = None
        if isinstance(event, dict):
            epoch = event.get("epoch", event.get("Epoch"))
        elif event is not None:
            epoch = event
        if self.buffered_subframes > 0:
            self.dropped_partial_frames += 1
        self.epoch = epoch
        self._clear_partial()

    def get_status(self) -> dict[str, Any]:
        return {
            "state": "ready",
            "ready": True,
            "epoch": self.epoch,
            "buffered_subframes": self.buffered_subframes,
            "emitted_frames": self.emitted_frames,
            "dropped_partial_frames": self.dropped_partial_frames,
        }

    def _allocate(self, data: Any) -> None:
        arrays = {
            field: as_csi_4d(
                _mapping_field(data, field, self._MATLAB_FIELDS[field]),
                name=f"data.{field}",
            )
            for field in self._FIELDS
        }
        for field, array in arrays.items():
            if array.shape[1] != 2:
                raise ValueError(f"data.{field} must contain two time samples")
        self._buffer = {
            field: complex_zeros_like(array, (array.shape[0], 20, array.shape[2], array.shape[3]))
            for field, array in arrays.items()
        }

    def _discard_partial(self) -> None:
        if self.buffered_subframes > 0:
            self.dropped_partial_frames += 1
        self._clear_partial()

    def _clear_partial(self) -> None:
        self._buffer = None
        self._first_meta = None
        self.buffered_subframes = 0
        self._expected_sequence = None

    @classmethod
    def _validate_packet(cls, packet: Packet) -> None:
        if not all(
            field in packet.data or cls._MATLAB_FIELDS[field] in packet.data
            for field in cls._FIELDS
        ):
            raise ValueError("Input is not a valid CSI subframe packet")
        _normalise_metadata(packet.meta)


def _mapping_field(mapping: Any, python_name: str, matlab_name: str) -> Any:
    if python_name in mapping:
        return mapping[python_name]
    if matlab_name in mapping:
        return mapping[matlab_name]
    raise ValueError(f"Missing data field {python_name!r}")


def _normalise_metadata(metadata: Any) -> dict[str, Any]:
    aliases = {
        "epoch": "Epoch",
        "sequence": "Sequence",
        "subframe_number": "SubframeNumber",
        "raw_end_sample_0": "RawEndSample0",
    }
    result: dict[str, Any] = {}
    for python_name, matlab_name in aliases.items():
        if python_name in metadata:
            result[python_name] = metadata[python_name]
        elif matlab_name in metadata:
            result[python_name] = metadata[matlab_name]
        else:
            raise ValueError("CSI subframe metadata is incomplete")
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


__all__ = ["CsiFrameAssembler"]
