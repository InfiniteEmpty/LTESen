"""Shared LTE physical-layer pseudo-random sequences."""

from __future__ import annotations

import numpy as np


def lte_gold_sequence(c_init: int, length: int) -> np.ndarray:
    """Generate ``length`` bits of the LTE 31-bit Gold sequence."""

    if isinstance(c_init, bool) or not isinstance(c_init, int) or c_init < 0:
        raise ValueError("c_init must be a non-negative integer")
    if isinstance(length, bool) or not isinstance(length, int) or length < 0:
        raise ValueError("length must be a non-negative integer")

    total = 1600 + length
    x1 = np.zeros(total + 31, dtype=np.int8)
    x2 = np.zeros(total + 31, dtype=np.int8)
    x1[0] = 1
    x2[:31] = ((c_init >> np.arange(31)) & 1).astype(np.int8)
    for index in range(total):
        x1[index + 31] = (x1[index + 3] + x1[index]) & 1
        x2[index + 31] = (
            x2[index + 3] + x2[index + 2] + x2[index + 1] + x2[index]
        ) & 1
    return x1[1600 : 1600 + length] ^ x2[1600 : 1600 + length]


__all__ = ["lte_gold_sequence"]
