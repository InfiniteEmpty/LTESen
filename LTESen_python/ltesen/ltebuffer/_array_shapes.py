"""Array-shape helpers shared by the phase-1 buffering components."""

from __future__ import annotations

import numpy as np


def as_csi_4d(value: object, *, name: str) -> np.ndarray:
    array = np.asarray(value)
    if array.ndim > 4:
        raise ValueError(f"{name} must have at most four dimensions")
    if array.ndim == 0:
        raise ValueError(f"{name} must be an array")
    return array.reshape(array.shape + (1,) * (4 - array.ndim))


def complex_zeros_like(array: np.ndarray, shape: tuple[int, ...]) -> np.ndarray:
    return np.zeros(shape, dtype=np.result_type(array.dtype, np.complex64))
