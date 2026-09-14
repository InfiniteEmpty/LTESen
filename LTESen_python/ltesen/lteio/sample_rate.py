"""Sample-rate normalization used by the future recording readers."""

from __future__ import annotations

import math


def processing_sample_rate(reported_rate_hz: float) -> int:
    """Round a finite positive SDR rate to the nominal integer DSP rate."""

    if isinstance(reported_rate_hz, bool) or not isinstance(
        reported_rate_hz, (int, float)
    ):
        raise TypeError("reported_rate_hz must be a real scalar")
    if not math.isfinite(reported_rate_hz) or reported_rate_hz <= 0:
        raise ValueError("reported_rate_hz must be finite and positive")
    nominal = round(float(reported_rate_hz))
    if nominal <= 0:
        raise ValueError("The rounded processing sample rate must be positive")
    return nominal


__all__ = ["processing_sample_rate"]
