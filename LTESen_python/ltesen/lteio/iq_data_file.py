"""Common interfaces and binary helpers for IQ recordings."""

from __future__ import annotations

import math
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np


@dataclass(frozen=True)
class DataTypeInfo:
    """Normalized description of a scalar or interleaved-IQ data type."""

    name: str
    is_complex: bool
    endianness: str
    machine_format: str
    matlab_type: str
    bits_per_scalar: int
    is_integer: bool
    is_unsigned: bool
    numpy_dtype: np.dtype = field(repr=False, compare=False)

    @property
    def is_real(self) -> bool:
        return not self.is_complex

    @property
    def bytes_per_scalar(self) -> int:
        return self.bits_per_scalar // 8

    @property
    def components_per_sample(self) -> int:
        return 2 if self.is_complex else 1

    @property
    def bytes_per_sample(self) -> int:
        return self.components_per_sample * self.bytes_per_scalar

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "is_complex": self.is_complex,
            "is_real": self.is_real,
            "endianness": self.endianness,
            "machine_format": self.machine_format,
            "matlab_type": self.matlab_type,
            "bits_per_scalar": self.bits_per_scalar,
            "bytes_per_scalar": self.bytes_per_scalar,
            "is_integer": self.is_integer,
            "is_unsigned": self.is_unsigned,
            "components_per_sample": self.components_per_sample,
            "bytes_per_sample": self.bytes_per_sample,
        }


class IQDataFile(ABC):
    """Base class for a seekable single-channel IQ recording."""

    def __init__(self) -> None:
        self.kind = "recording"
        self.format = ""
        self.file_path: Path | None = None
        self.data_exists = False
        self.data_type = ""
        self.datatype = ""
        self.datatype_info: DataTypeInfo | None = None
        self.sample_rate = math.nan
        self.frequency = math.nan
        self.num_channels = 1
        self.sample_count: int | None = None
        self.data_bytes: int | None = None
        self.offset = 0

    def read(self, length: int | float | None = None, normalize: bool = False) -> np.ndarray:
        """Read from the current offset and advance that offset."""

        signal = self.read_at(self.offset, length, normalize)
        self.offset += int(signal.size)
        return signal

    def seek(self, position: int | float, origin: str = "bof") -> int:
        """Set the zero-based sample offset."""

        self._assert_recording()
        if self.sample_count is None:
            raise ValueError("Cannot seek a recording with unknown sample count")
        position_int = _validate_integer(position, "position")
        origin = str(origin).lower()
        if origin in {"bof", "begin", "start"}:
            if position_int < 0:
                raise ValueError("An offset relative to the beginning cannot be negative")
            new_offset = position_int
        elif origin in {"cof", "current"}:
            new_offset = self.offset + position_int
        elif origin in {"eof", "end"}:
            new_offset = self.sample_count + position_int
        else:
            raise ValueError("origin must be 'bof', 'cof', or 'eof'")
        if new_offset < 0 or new_offset > self.sample_count:
            raise ValueError(
                f"Target offset {new_offset} is outside [0, {self.sample_count}]"
            )
        self.offset = new_offset
        return new_offset

    def skip(self, count: int | float = 0) -> int:
        return self.seek(count, "cof")

    def reset(self) -> None:
        self.seek(0, "bof")

    @property
    def eof(self) -> bool:
        return (
            self.kind == "recording"
            and self.sample_count is not None
            and self.offset >= self.sample_count
        )

    @property
    def duration_seconds(self) -> float:
        if (
            self.sample_count is not None
            and math.isfinite(float(self.sample_rate))
            and self.sample_rate > 0
        ):
            return self.sample_count / self.sample_rate
        return math.nan

    @property
    def fc(self) -> float:
        return self.frequency

    @property
    def sr(self) -> float:
        return self.sample_rate

    def describe(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "format": self.format,
            "file_path": str(self.file_path) if self.file_path is not None else "",
            "data_type": self.data_type,
            "datatype": self.datatype,
            "sample_rate": self.sample_rate,
            "frequency": self.frequency,
            "sample_count": self.sample_count,
            "offset": self.offset,
            "num_channels": self.num_channels,
            "duration_seconds": self.duration_seconds,
        }

    @staticmethod
    def make_datatype_info(
        data_type: str, is_complex: bool | None = None
    ) -> DataTypeInfo:
        """Normalize a SigMF type or legacy NumPy/MATLAB scalar type.

        SigMF names are of the form ``ci16_le`` or ``rf32_le``. Legacy names
        such as ``int16`` describe interleaved IQ unless ``is_complex=False``
        is explicitly supplied.
        """

        name = str(data_type).strip().lower()
        if not name:
            raise ValueError("data_type cannot be empty")
        is_sigmf = name[0] in {"c", "r"}
        if is_complex is None:
            is_complex = name[0] == "c" if is_sigmf else True

        if is_sigmf:
            body = name[1:]
            if body.endswith("_le"):
                endianness = "little"
                machine_format = "<"
                body = body[:-3]
            elif body.endswith("_be"):
                endianness = "big"
                machine_format = ">"
                body = body[:-3]
            else:
                endianness = "native"
                machine_format = "="
        else:
            body = name
            endianness = "native"
            machine_format = "="

        scalar_types: dict[str, tuple[str, type[Any], int, bool, bool]] = {
            "i8": ("int8", np.int8, 8, True, False),
            "int8": ("int8", np.int8, 8, True, False),
            "u8": ("uint8", np.uint8, 8, True, True),
            "uint8": ("uint8", np.uint8, 8, True, True),
            "i16": ("int16", np.int16, 16, True, False),
            "int16": ("int16", np.int16, 16, True, False),
            "u16": ("uint16", np.uint16, 16, True, True),
            "uint16": ("uint16", np.uint16, 16, True, True),
            "i32": ("int32", np.int32, 32, True, False),
            "int32": ("int32", np.int32, 32, True, False),
            "u32": ("uint32", np.uint32, 32, True, True),
            "uint32": ("uint32", np.uint32, 32, True, True),
            "i64": ("int64", np.int64, 64, True, False),
            "int64": ("int64", np.int64, 64, True, False),
            "u64": ("uint64", np.uint64, 64, True, True),
            "uint64": ("uint64", np.uint64, 64, True, True),
            "f32": ("single", np.float32, 32, False, False),
            "single": ("single", np.float32, 32, False, False),
            "float": ("single", np.float32, 32, False, False),
            "float32": ("single", np.float32, 32, False, False),
            "f64": ("double", np.float64, 64, False, False),
            "double": ("double", np.float64, 64, False, False),
            "float64": ("double", np.float64, 64, False, False),
        }
        try:
            matlab_type, numpy_type, bits, is_integer, is_unsigned = scalar_types[body]
        except KeyError as exc:
            raise ValueError(f"Unsupported data type: {data_type}") from exc

        dtype = np.dtype(numpy_type).newbyteorder(machine_format)
        return DataTypeInfo(
            name=name,
            is_complex=bool(is_complex),
            endianness=endianness,
            machine_format=machine_format,
            matlab_type=matlab_type,
            bits_per_scalar=bits,
            is_integer=is_integer,
            is_unsigned=is_unsigned,
            numpy_dtype=dtype,
        )

    def _assert_recording(self) -> None:
        if self.kind != "recording":
            raise ValueError("A collection object cannot be read directly")

    def _read_bounds(
        self,
        from_index: int | float,
        length: int | float | None,
    ) -> tuple[int, int]:
        self._assert_recording()
        if self.sample_count is None:
            raise ValueError("Cannot read a recording with unknown sample count")
        start = _validate_index(from_index, "from")
        if length is None or (
            isinstance(length, (int, float, np.integer, np.floating))
            and math.isinf(float(length))
        ):
            length_int = self.sample_count - start
        else:
            length_int = _validate_index(length, "length")
        if start > self.sample_count:
            raise ValueError(f"from={start} exceeds sample count {self.sample_count}")
        return start, min(length_int, self.sample_count - start)

    @abstractmethod
    def read_at(
        self,
        from_index: int | float = 0,
        length: int | float | None = None,
        normalize: bool = False,
    ) -> np.ndarray:
        """Read a fixed range without changing the cursor."""


def _validate_index(value: int | float, name: str) -> int:
    number = _validate_integer(value, name)
    if number < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return number


def _validate_integer(value: int | float, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float, np.integer, np.floating)):
        raise TypeError(f"{name} must be an integer")
    number = float(value)
    if not math.isfinite(number) or number != math.floor(number):
        raise ValueError(f"{name} must be an integer")
    return int(number)


def read_interleaved_samples(
    file_path: Path,
    datatype_info: DataTypeInfo,
    from_index: int,
    length: int,
    *,
    sample_count: int,
    num_channels: int = 1,
    normalize: bool = False,
) -> np.ndarray:
    """Read interleaved scalar components using a bounded memory map."""

    if length == 0:
        dtype = np.complex128 if datatype_info.is_complex else np.float64
        return np.empty(0, dtype=dtype)
    byte_offset = from_index * datatype_info.bytes_per_sample * num_channels
    scalar_count = datatype_info.components_per_sample * length * num_channels
    expected_end = from_index + length
    if from_index < 0 or expected_end > sample_count:
        raise ValueError("Requested range is outside the recording")

    raw_map = np.memmap(
        file_path,
        dtype=datatype_info.numpy_dtype,
        mode="r",
        offset=byte_offset,
        shape=(scalar_count,),
    )
    # Copy the requested chunk so the memory-mapped file is closed before the
    # result is returned. The caller controls chunk size through read_at().
    raw = np.array(raw_map, copy=True)
    del raw_map
    if datatype_info.is_integer:
        values = raw.astype(np.float64)
    else:
        values = raw.astype(np.float64, copy=False)
    if datatype_info.is_complex:
        signal = values[0::2] + 1j * values[1::2]
    else:
        signal = values

    if normalize and datatype_info.is_integer:
        if datatype_info.is_unsigned:
            scale = 2**datatype_info.bits_per_scalar
            signal = (signal - scale / 2) / (scale / 2)
        else:
            scale = 2 ** (datatype_info.bits_per_scalar - 1)
            signal = signal / scale
    return np.asarray(signal).reshape(-1)


__all__ = ["DataTypeInfo", "IQDataFile", "read_interleaved_samples"]
