"""LTE broadcast-channel (BCH) coding and decoding."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from numbers import Integral, Real
from typing import Any

import numpy as np

from .fec import (
    append_lte_crc16,
    lte_bch_crc_mask,
    lte_convolutional_rate_dematch,
    lte_convolutional_rate_match,
    lte_crc16,
    lte_tail_biting_decode,
    lte_tail_biting_encode,
)


def lte_bch(
    enb: Mapping[str, Any] | Any,
    trblk: Any,
    output_length: int | None = None,
    ports: int | None = None,
) -> np.ndarray:
    """Encode a BCH transport block with CRC, convolutional coding and RM.

    The normal MIB path uses a 24-bit transport block and produces 1920 bits
    for normal CP or 1728 bits for extended CP.  ``output_length`` is exposed
    because MATLAB also permits a shorter rate-matched output for fixtures.
    ``ports`` controls the PBCH CRC mask and defaults to ``enb.CellRefP``;
    zero disables the mask for low-level tests.
    """

    values = _normalise_bits(trblk, "trblk")
    if values.size == 0:
        raise ValueError("trblk must not be empty")
    selected_ports = _ports(enb, ports, default=0)
    if output_length is None:
        output_length = 1728 if _prefix(enb) == "extended" else 1920
    length = _positive_integer(output_length, "output_length")

    payload_crc = append_lte_crc16(values)
    if selected_ports:
        payload_crc = payload_crc.copy()
        payload_crc[-16:] ^= lte_bch_crc_mask(selected_ports)
    encoded = lte_tail_biting_encode(payload_crc)
    return lte_convolutional_rate_match(encoded, length)


def lte_bch_decode(
    enb: Mapping[str, Any] | Any,
    softbits: Any,
    output_length: int = 24,
    ports: int | Sequence[int] | None = None,
) -> tuple[np.ndarray, int]:
    """Decode BCH LLRs and return ``(transport_block, detected_ports)``.

    ``softbits`` may contain any positive number of rate-matched LLRs.  A
    positive value denotes bit 0 and a negative value denotes bit 1.  The
    decoder accepts partial BCH transmissions, which is important because a
    single LTE frame carries only one quarter of the BCH codeword.

    A CRC failure returns an all-zero transport block and ``detected_ports=0``
    instead of raising, matching the MATLAB receiver contract.
    """

    values = np.asarray(softbits, dtype=np.float64).reshape(-1)
    if values.size and not np.all(np.isfinite(values)):
        raise ValueError("softbits must contain finite values")
    trblk_length = _positive_integer(output_length, "output_length")
    if ports is None:
        candidates = (1, 2, 4)
    elif isinstance(ports, (Integral, Real)) and not isinstance(ports, bool):
        candidates = (_ports(enb, int(ports), default=0),)
    else:
        candidates = tuple(_ports(enb, int(item), default=0) for item in ports)
    if not candidates:
        raise ValueError("ports must contain at least one candidate")

    coded_length = 3 * (trblk_length + 16)
    if coded_length <= 0:
        raise ValueError("output_length is too small for BCH CRC decoding")
    dematched = lte_convolutional_rate_dematch(values, coded_length)
    decoded = lte_tail_biting_decode(dematched, trblk_length + 16)
    transport = decoded[:trblk_length]
    received_crc = decoded[trblk_length:]

    for candidate in candidates:
        unmasked_crc = received_crc ^ lte_bch_crc_mask(candidate)
        check_bits = np.concatenate((transport, unmasked_crc))
        if lte_crc16(check_bits) == 0:
            return transport.copy(), candidate
    return np.zeros(trblk_length, dtype=np.uint8), 0


def _prefix(value: Mapping[str, Any] | Any) -> str:
    prefix = str(_field(value, "cyclic_prefix", "CyclicPrefix", default="Normal")).lower()
    if prefix not in {"normal", "extended"}:
        raise ValueError("CyclicPrefix must be 'Normal' or 'Extended'")
    return prefix


def _ports(value: Mapping[str, Any] | Any, ports: int | None, *, default: int) -> int:
    selected = default if ports is None else ports
    if ports is None and selected == default:
        selected = _field(value, "cell_ref_p", "CellRefP", default=default)
    if isinstance(selected, bool) or not isinstance(selected, (Integral, Real)):
        raise ValueError("ports must be an integer")
    selected = int(selected)
    if selected not in {0, 1, 2, 4}:
        raise ValueError("ports must be one of 0, 1, 2, or 4")
    return selected


def _normalise_bits(value: Any, name: str) -> np.ndarray:
    values = np.asarray(value).reshape(-1)
    if not np.issubdtype(values.dtype, np.number):
        raise TypeError(f"{name} must contain numeric binary values")
    if values.size and (not np.all(np.isfinite(values)) or np.any((values != 0) & (values != 1))):
        raise ValueError(f"{name} must contain only 0 and 1")
    return values.astype(np.uint8, copy=False)


def _field(value: Mapping[str, Any] | Any, *names: str, default: Any = ...) -> Any:
    if isinstance(value, Mapping):
        for name in names:
            if name in value:
                return value[name]
    else:
        for name in names:
            if hasattr(value, name):
                return getattr(value, name)
    if default is not ...:
        return default
    raise ValueError(f"Missing LTE field; expected one of {names}")


def _positive_integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError(f"{name} must be a positive integer")
    if not np.isfinite(value) or int(value) != value or int(value) < 1:
        raise ValueError(f"{name} must be a positive integer")
    return int(value)


__all__ = ["lte_bch", "lte_bch_decode"]
