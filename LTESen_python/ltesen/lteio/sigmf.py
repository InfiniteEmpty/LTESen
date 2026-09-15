"""SigMF data/meta and collection readers."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping

import numpy as np

from .iq_data_file import IQDataFile, read_interleaved_samples


class SigMFDataFile(IQDataFile):
    """Read one ``.sigmf-data``/``.sigmf-meta`` pair."""

    def __init__(self, root_dir: str | Path, record_name: str) -> None:
        super().__init__()
        if not root_dir or not record_name:
            raise ValueError("root_dir and record_name are required")
        root = Path(root_dir)
        name = str(record_name)
        if not root.is_dir():
            raise FileNotFoundError(f"SigMF root directory does not exist: {root}")
        if Path(name).suffix or "/" in name or "\\" in name:
            raise ValueError("record_name must not contain a path or suffix")

        self.root_dir = root
        self.record_name = name
        self.file_path = root / f"{name}.sigmf-data"
        self.meta_file = root / f"{name}.sigmf-meta"
        self._load_recording()

    def describe(self) -> dict[str, Any]:
        info = super().describe()
        info.update(
            {
                "root_dir": str(self.root_dir),
                "record_name": self.record_name,
                "meta_file": str(self.meta_file),
                "start_time_utc": self.start_time_utc,
                "sample_start": self.sample_start,
                "sha512": self.sha512,
            }
        )
        return info

    def read_at(
        self,
        from_index: int | float = 0,
        length: int | float | None = None,
        normalize: bool = False,
    ) -> np.ndarray:
        if self.num_channels != 1:
            raise ValueError("The current read interface supports one channel per file")
        if not self.data_exists or self.file_path is None or self.datatype_info is None:
            raise FileNotFoundError(f"SigMF data file does not exist: {self.file_path}")
        start, count = self._read_bounds(from_index, length)
        return read_interleaved_samples(
            self.file_path,
            self.datatype_info,
            start,
            count,
            sample_count=self.sample_count or 0,
            num_channels=self.num_channels,
            normalize=normalize,
            raw_data=self._cached_scalar_range(
                self.file_path,
                self.datatype_info,
                scalar_start=start
                * self.datatype_info.components_per_sample
                * self.num_channels,
                scalar_count=count
                * self.datatype_info.components_per_sample
                * self.num_channels,
                total_scalar_count=(self.sample_count or 0)
                * self.datatype_info.components_per_sample
                * self.num_channels,
            ),
        )

    def _load_recording(self) -> None:
        if not self.meta_file.is_file():
            raise FileNotFoundError(f"SigMF metadata file does not exist: {self.meta_file}")
        raw = _read_json(self.meta_file)
        global_metadata = _json_field(raw, "global", {})
        if not isinstance(global_metadata, Mapping):
            raise ValueError("SigMF global metadata must be an object")
        capture_list = _as_list(_json_field(raw, "captures", []))
        annotation_list = _as_list(_json_field(raw, "annotations", []))

        datatype = str(_json_field(global_metadata, "core:datatype", "")).strip()
        if not datatype:
            raise ValueError(f"SigMF metadata lacks core:datatype: {self.meta_file}")
        datatype_info = self.make_datatype_info(datatype)

        num_channels = _as_positive_int(
            _json_field(global_metadata, "core:num_channels", 1), "core:num_channels"
        )
        trailing_bytes = _as_nonnegative_int(
            _json_field(global_metadata, "core:trailing_bytes", 0), "core:trailing_bytes"
        )
        capture = capture_list[0] if capture_list else {}
        if not isinstance(capture, Mapping):
            capture = {}

        frequency = _as_float(_json_field(capture, "core:frequency", np.nan))
        sample_rate = _as_float(_json_field(global_metadata, "core:sample_rate", np.nan))
        data_exists = self.file_path is not None and self.file_path.is_file()
        data_bytes: int | None = None
        sample_count: int | None = None
        if data_exists:
            data_bytes = self.file_path.stat().st_size
            usable_bytes = data_bytes - trailing_bytes
            bytes_per_sample = datatype_info.bytes_per_sample * num_channels
            if usable_bytes < 0 or usable_bytes % bytes_per_sample:
                raise ValueError(
                    f"SigMF data length {data_bytes} is incompatible with metadata"
                )
            sample_count = usable_bytes // bytes_per_sample

        self.kind = "recording"
        self.format = "sigmf"
        self.data_exists = data_exists
        self.data_type = datatype_info.matlab_type
        self.datatype = datatype
        self.datatype_info = datatype_info
        self.sample_rate = sample_rate
        self.frequency = frequency
        self.num_channels = num_channels
        self.sample_count = sample_count
        self.data_bytes = data_bytes
        self.offset = 0
        self.metadata = dict(raw)
        self.global_metadata = dict(global_metadata)
        self.captures = capture_list
        self.annotations = annotation_list
        self.start_time_utc = str(_json_field(capture, "core:datetime", "") or "")
        self.sample_start = _as_float(_json_field(capture, "core:sample_start", 0))
        self.trailing_bytes = trailing_bytes
        self.sha512 = str(_json_field(global_metadata, "core:sha512", "") or "")


class SigMFCollection:
    """Descriptor containing multiple named SigMF streams."""

    def __init__(self, root_dir: str | Path, collection_name: str) -> None:
        if not root_dir or not collection_name:
            raise ValueError("root_dir and collection_name are required")
        root = Path(root_dir)
        name = str(collection_name)
        if not root.is_dir():
            raise FileNotFoundError(f"SigMF root directory does not exist: {root}")
        if Path(name).suffix or "/" in name or "\\" in name:
            raise ValueError("collection_name must not contain a path or suffix")

        self.kind = "collection"
        self.root_dir = root
        self.collection_name = name
        self.file_path = root / f"{name}.sigmf-collection"
        if not self.file_path.is_file():
            raise FileNotFoundError(f"SigMF collection does not exist: {self.file_path}")
        self.metadata = _read_json(self.file_path)
        collection = _json_field(self.metadata, "collection", {})
        if not isinstance(collection, Mapping):
            raise ValueError("SigMF collection field must be an object")
        definitions = _as_list(_json_field(collection, "core:streams", []))
        self.collection = dict(collection)
        self.stream_definitions = definitions
        self.stream_names: list[str] = []
        self.streams: list[SigMFDataFile] = []
        for definition in definitions:
            if not isinstance(definition, Mapping):
                raise ValueError("Each SigMF stream definition must be an object")
            stream_name = str(_json_field(definition, "name", "") or "")
            if not stream_name:
                raise ValueError("A SigMF stream definition lacks name")
            lower_name = stream_name.lower()
            for suffix in (".sigmf-data", ".sigmf-meta"):
                if lower_name.endswith(suffix):
                    stream_name = stream_name[: -len(suffix)]
                    break
            self.stream_names.append(stream_name)
            self.streams.append(SigMFDataFile(root, stream_name))
        self.stream_count = len(self.streams)

    def get_stream(self, index_or_name: int | str) -> SigMFDataFile:
        """Return a stream by zero-based index or suffix-free name."""

        if isinstance(index_or_name, (int, np.integer)) and not isinstance(index_or_name, bool):
            index = int(index_or_name)
            if index < 0 or index >= self.stream_count:
                raise IndexError(f"stream index must be in [0, {self.stream_count})")
            return self.streams[index]
        name = str(index_or_name)
        try:
            return self.streams[self.stream_names.index(name)]
        except ValueError as exc:
            raise KeyError(f"Stream not found: {name}") from exc

    def describe(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "format": "sigmf-collection",
            "root_dir": str(self.root_dir),
            "collection_name": self.collection_name,
            "file_path": str(self.file_path),
            "stream_names": list(self.stream_names),
            "stream_count": self.stream_count,
        }


def _read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot read JSON file: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"JSON top level must be an object: {path}")
    return value


def _json_field(value: Any, name: str, default: Any) -> Any:
    if not isinstance(value, Mapping):
        return default
    for candidate in (name, name.replace(":", "_")):
        if candidate in value:
            return value[candidate]
    return default


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _as_float(value: Any) -> float:
    if value is None or value == "":
        return np.nan
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Expected a numeric value, got {value!r}") from exc


def _as_positive_int(value: Any, name: str) -> int:
    number = _as_nonnegative_int(value, name)
    if number <= 0:
        raise ValueError(f"{name} must be positive")
    return number


def _as_nonnegative_int(value: Any, name: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be an integer")
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if not np.isfinite(number) or number < 0 or number != np.floor(number):
        raise ValueError(f"{name} must be a non-negative integer")
    return int(number)


__all__ = ["SigMFCollection", "SigMFDataFile"]
