"""Tracking and waveform-domain helpers for the LTE receiver."""

from .cfo import CfoTracker
from .csi_tracker import CsiTracker
from .ofdm import FullOfdmInfo, OfdmParameters, demodulate_full
from .phase import estimate_phase_slope_fft

__all__ = [
    "CfoTracker",
    "CsiTracker",
    "FullOfdmInfo",
    "OfdmParameters",
    "Receiver",
    "demodulate_full",
    "estimate_phase_slope_fft",
]


def __getattr__(name: str):
    """Load the receiver lazily to avoid the LTE PHY import cycle."""

    if name == "Receiver":
        from .receiver import Receiver

        return Receiver
    raise AttributeError(name)
