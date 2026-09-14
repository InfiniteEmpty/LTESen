"""Recording format selection."""

from __future__ import annotations

from pathlib import Path

from .legacy import LegacyLTEDataFile
from .sigmf import SigMFDataFile


def open_recording(
    root_directory: str | Path,
    record_name: str,
    format: str = "auto",
) -> LegacyLTEDataFile | SigMFDataFile:
    """Open a SigMF pair or legacy recording through one common interface."""

    root = Path(root_directory)
    selected = str(format).lower()
    name = str(record_name)
    if selected == "auto":
        if (root / f"{name}.sigmf-meta").is_file() and (
            root / f"{name}.sigmf-data"
        ).is_file():
            return SigMFDataFile(root, name)
        return LegacyLTEDataFile(root, name)
    if selected == "sigmf":
        return SigMFDataFile(root, name)
    if selected == "legacy":
        return LegacyLTEDataFile(root, name)
    raise ValueError(f"Unknown recording format: {format}")


__all__ = ["open_recording"]
