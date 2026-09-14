"""Reader for the project's legacy GNU Radio interleaved-IQ files."""

from __future__ import annotations

import re
import warnings
from pathlib import Path
from typing import Any

import numpy as np

from .iq_data_file import IQDataFile, read_interleaved_samples


class LegacyLTEDataFile(IQDataFile):
    """Read ``PREFIX_key_value_...bin`` recordings."""

    def __init__(self, path: str | Path, prefix: str = "") -> None:
        super().__init__()
        file_path, resolved_prefix = self._resolve_file(path, prefix)
        if file_path.suffix.lower() != ".bin":
            raise ValueError(f"Legacy data files must use .bin: {file_path}")

        metadata, keys, values = self._parse_metadata(file_path.stem, resolved_prefix)
        self.prefix = resolved_prefix
        self.metadata = metadata
        self.metadata_keys = keys
        self.metadata_values = values
        self.date = self._get_metadata(metadata, ("date",))
        self.record_id = self._get_metadata(metadata, ("id", "record_id", "recordid"))
        prefix_date, prefix_id = self._parse_indexed_prefix(resolved_prefix)
        self.date = self.date or prefix_date
        self.record_id = self.record_id or prefix_id

        frequency_text = self._get_metadata(metadata, ("fc", "freq", "frequency"))
        sample_rate_text = self._get_metadata(
            metadata, ("fs", "sr", "sample_rate", "samplerate")
        )
        datatype = self._get_metadata(metadata, ("tp", "type", "datatype", "data_type"))
        datatype = datatype or "int16"
        datatype_info = self.make_datatype_info(datatype, is_complex=True)

        data_bytes = file_path.stat().st_size
        if data_bytes % datatype_info.bytes_per_sample:
            raise ValueError(
                f"File size {data_bytes} is incompatible with {datatype_info.name}"
            )

        self.kind = "recording"
        self.format = "legacy"
        self.file_path = file_path
        self.data_exists = True
        self.data_type = datatype_info.matlab_type
        self.datatype = datatype_info.name
        self.datatype_info = datatype_info
        self.sample_rate = self._parse_quantity(sample_rate_text)
        self.frequency = self._parse_quantity(frequency_text)
        self.num_channels = 1
        self.sample_count = data_bytes // datatype_info.bytes_per_sample
        self.data_bytes = data_bytes
        self.offset = 0
        self.filename = file_path.stem

    def describe(self) -> dict[str, Any]:
        info = super().describe()
        info.update(
            {
                "prefix": self.prefix,
                "date": self.date,
                "record_id": self.record_id,
                "filename": self.filename,
                "metadata": dict(self.metadata),
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
            raise FileNotFoundError(f"Recording data is not available: {self.file_path}")
        start, count = self._read_bounds(from_index, length)
        return read_interleaved_samples(
            self.file_path,
            self.datatype_info,
            start,
            count,
            sample_count=self.sample_count or 0,
            num_channels=self.num_channels,
            normalize=normalize,
        )

    @staticmethod
    def _resolve_file(path: str | Path, prefix: str) -> tuple[Path, str]:
        candidate = Path(path)
        prefix = str(prefix).strip()
        if candidate.is_dir():
            if not prefix:
                raise ValueError("A prefix is required when path is a directory")
            exact = candidate / f"{prefix}.bin"
            if exact.is_file():
                return exact, LegacyLTEDataFile._infer_prefix(exact.stem)
            matches = sorted(candidate.glob(f"{prefix}_*.bin"))
            if not matches:
                raise FileNotFoundError(f"No .bin recording starts with {prefix!r}")
            if len(matches) > 1:
                warnings.warn(
                    f"Found {len(matches)} recordings for prefix {prefix!r}; using {matches[0].name}",
                    RuntimeWarning,
                    stacklevel=2,
                )
            return matches[0], prefix

        if not candidate.is_file():
            raise FileNotFoundError(f"Recording file or directory does not exist: {candidate}")
        if candidate.suffix.lower() != ".bin":
            raise ValueError(f"Legacy data files must use .bin: {candidate}")
        if not prefix:
            prefix = LegacyLTEDataFile._infer_prefix(candidate.stem)
        return candidate, prefix

    @staticmethod
    def _infer_prefix(file_name: str) -> str:
        known = (
            "fc",
            "freq",
            "frequency",
            "fs",
            "sr",
            "sample_rate",
            "samplerate",
            "tp",
            "type",
            "datatype",
            "data_type",
        )
        pattern = r"_(?:" + "|".join(re.escape(key) for key in known) + r")_"
        match = re.search(pattern, file_name, flags=re.IGNORECASE)
        if match is None:
            raise ValueError(f"Cannot infer a prefix from file name: {file_name}")
        return file_name[: match.start()]

    @staticmethod
    def _parse_indexed_prefix(prefix: str) -> tuple[str, str]:
        match = re.search(r"(\d{8})_(\d+)$", prefix)
        return (match.group(1), match.group(2)) if match else ("", "")

    @staticmethod
    def _parse_metadata(file_name: str, prefix: str) -> tuple[dict[str, str], list[str], list[str]]:
        marker = f"{prefix}_"
        if not file_name.startswith(marker):
            raise ValueError(f"File name does not start with prefix {prefix!r}: {file_name}")
        suffix = file_name[len(marker) :]
        tokens = suffix.split("_") if suffix else []
        if not tokens or len(tokens) % 2:
            raise ValueError(f"Metadata must be key/value pairs: {file_name}")
        metadata: dict[str, str] = {}
        keys: list[str] = []
        values: list[str] = []
        for key, value in zip(tokens[::2], tokens[1::2]):
            key = key.strip().lower()
            if not key or key in metadata:
                raise ValueError(f"Invalid or duplicate metadata key: {key!r}")
            metadata[key] = value
            keys.append(key)
            values.append(value)
        return metadata, keys, values

    @staticmethod
    def _get_metadata(metadata: dict[str, str], names: tuple[str, ...]) -> str:
        for name in names:
            if name.lower() in metadata:
                return str(metadata[name.lower()])
        return ""

    @staticmethod
    def _parse_quantity(text_value: str) -> float:
        if not text_value:
            return np.nan
        match = re.fullmatch(
            r"\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-Z]*)\s*",
            str(text_value),
        )
        if match is None:
            raise ValueError(f"Cannot parse quantity: {text_value}")
        scales = {"": 1, "h": 1, "hz": 1, "k": 1e3, "khz": 1e3, "m": 1e6, "mhz": 1e6, "g": 1e9, "ghz": 1e9}
        unit = match.group(2).lower()
        if unit not in scales:
            raise ValueError(f"Unknown quantity unit: {unit}")
        return float(match.group(1)) * scales[unit]


__all__ = ["LegacyLTEDataFile"]
