"""LTE PBCH equalization, soft demodulation and BCH/MIB recovery."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from numbers import Integral, Real
from typing import Any

import numpy as np

from .bch import lte_bch_decode
from .pbch import lte_pbch_prbs


def lte_pbch_decode(
    enb: Mapping[str, Any] | Any,
    received: Any,
    hest: Any | None = None,
    noise_estimate: float = 0.0,
    alg: Mapping[str, Any] | Any | None = None,
) -> tuple[np.ndarray, np.ndarray, int, np.ndarray, int]:
    """Decode PBCH symbols and recover the 24-bit MIB transport block.

    Parameters follow MATLAB's ``ltePBCHDecode(enb,sym,hest,noiseEst)``
    structure, with Python arrays using zero-based indexing.  ``received`` is
    ``(N_RE, N_rx)`` complex PBCH symbols, and ``hest`` is optionally
    ``(N_RE, N_rx, P)``.  One to four consecutive PBCH subframes are accepted.

    Returns ``(softbits, symbols, nfmod4, mib, cell_ref_p)``.  A CRC failure
    returns ``cell_ref_p=0`` and an all-zero MIB, matching the acquisition
    caller's failure convention.
    """

    values = np.asarray(received, dtype=np.complex128)
    if values.ndim == 1:
        values = values[:, None]
    if values.ndim != 2 or values.shape[0] == 0:
        raise ValueError("received must have shape (N_RE, N_rx)")
    if not np.all(np.isfinite(values)):
        raise ValueError("received must contain finite complex values")
    n_re, n_rx = values.shape

    prefix = _prefix(enb)
    quarter_bits = 432 if prefix == "extended" else 480
    quarter_symbols = quarter_bits // 2
    if n_re % quarter_symbols:
        raise ValueError(
            f"received must contain a whole number of PBCH blocks ({quarter_symbols} symbols each)"
        )
    if n_re // quarter_symbols > 4:
        raise ValueError("received contains more than four PBCH blocks")

    channels = _normalise_channel(hest, n_re, n_rx)
    configured_ports = _field(enb, "cell_ref_p", "CellRefP", default=None)
    candidate_ports = _candidate_ports(configured_ports)
    noise = _nonnegative_real(noise_estimate, "noise_estimate")
    csi_enabled = _csi_enabled(alg)

    last_softbits = np.zeros(n_re * 2, dtype=np.float64)
    last_symbols = np.zeros(n_re, dtype=np.complex128)
    for ports in candidate_ports:
        if channels is not None and channels.shape[2] < ports:
            continue
        used_channels = (
            np.ones((n_re, n_rx, ports), dtype=np.complex128)
            if channels is None
            else channels[:, :, :ports]
        )
        symbols, csi = _equalize(values, used_channels, ports, noise)
        softbits = _qpsk_soft_demodulate(symbols)
        if csi_enabled:
            softbits *= np.repeat(csi, 2)
        last_softbits = softbits
        last_symbols = symbols

        for nfmod4 in range(3, -1, -1):
            start = nfmod4 * quarter_bits
            sequence = lte_pbch_prbs(
                enb, (start, softbits.size), mapping="signed"
            ).astype(np.float64)
            descrambled = softbits * sequence
            pad = start % 120
            if pad:
                bch_input = np.concatenate((np.zeros(pad), descrambled))
            else:
                bch_input = descrambled
            mib, detected_ports = lte_bch_decode(
                enb, bch_input, ports=ports
            )
            if detected_ports:
                return descrambled, symbols, nfmod4, mib, detected_ports

    return last_softbits, last_symbols, 0, np.zeros(24, dtype=np.uint8), 0


def _equalize(
    received: np.ndarray,
    channel: np.ndarray,
    ports: int,
    noise: float,
) -> tuple[np.ndarray, np.ndarray]:
    if ports == 1:
        gain = np.sum(np.abs(channel[:, :, 0]) ** 2, axis=1)
        numerator = np.sum(np.conj(channel[:, :, 0]) * received, axis=1)
        symbols = numerator / np.maximum(gain + noise, np.finfo(float).eps)
        csi = gain / np.maximum(gain + noise, np.finfo(float).eps)
        return symbols, csi

    if ports == 2:
        if received.shape[0] % 2:
            raise ValueError("two-port PBCH requires an even symbol count")
        symbols = np.empty(received.shape[0], dtype=np.complex128)
        csi = np.empty(received.shape[0], dtype=np.float64)
        for index in range(0, received.shape[0], 2):
            r0 = received[index]
            r1 = received[index + 1]
            h00 = channel[index, :, 0]
            h01 = channel[index + 1, :, 0]
            h10 = channel[index, :, 1]
            h11 = channel[index + 1, :, 1]
            gain0 = float(np.sum(np.abs(h00) ** 2 + np.abs(h11) ** 2))
            gain1 = float(np.sum(np.abs(h10) ** 2 + np.abs(h01) ** 2))
            denominator0 = max(gain0 + noise, np.finfo(float).eps)
            denominator1 = max(gain1 + noise, np.finfo(float).eps)
            layer0 = np.sum(np.conj(h00) * r0 + h11 * np.conj(r1))
            layer1 = np.sum(-h10 * np.conj(r0) + np.conj(h01) * r1)
            symbols[index] = layer0 / denominator0 * np.sqrt(2.0)
            symbols[index + 1] = layer1 / denominator1 * np.sqrt(2.0)
            csi[index] = gain0 / denominator0
            csi[index + 1] = gain1 / denominator1
        return symbols, csi

    if ports != 4:
        raise ValueError("PBCH equalization supports one, two, or four ports")
    if received.shape[0] % 4:
        raise ValueError("four-port PBCH requires a symbol count divisible by four")
    symbols = np.empty(received.shape[0], dtype=np.complex128)
    csi = np.empty(received.shape[0], dtype=np.float64)
    for index in range(0, received.shape[0], 4):
        r0, r1, r2, r3 = received[index : index + 4]
        h0 = channel[index, :, 0]
        h2 = channel[index, :, 2]
        h1 = channel[index + 2, :, 1]
        h3 = channel[index + 2, :, 3]
        gain01 = float(np.sum(np.abs(h0) ** 2 + np.abs(h2) ** 2))
        gain23 = float(np.sum(np.abs(h1) ** 2 + np.abs(h3) ** 2))
        denominator01 = max(gain01 + noise, np.finfo(float).eps)
        denominator23 = max(gain23 + noise, np.finfo(float).eps)
        layer0 = np.sum(np.conj(h0) * r0 + h2 * np.conj(r1))
        layer1 = np.sum(-h2 * np.conj(r0) + np.conj(h0) * r1)
        layer2 = np.sum(np.conj(h1) * r2 + h3 * np.conj(r3))
        layer3 = np.sum(-h3 * np.conj(r2) + np.conj(h1) * r3)
        decoded = np.asarray(
            [
                layer0 / denominator01 * np.sqrt(2.0),
                layer1 / denominator01 * np.sqrt(2.0),
                layer2 / denominator23 * np.sqrt(2.0),
                layer3 / denominator23 * np.sqrt(2.0),
            ],
            dtype=np.complex128,
        )
        symbols[index : index + 4] = decoded
        csi[index : index + 2] = gain01 / denominator01
        csi[index + 2 : index + 4] = gain23 / denominator23
    return symbols, csi


def _qpsk_soft_demodulate(symbols: np.ndarray) -> np.ndarray:
    output = np.empty(symbols.size * 2, dtype=np.float64)
    output[0::2] = 2.0 * symbols.real
    output[1::2] = 2.0 * symbols.imag
    return output


def _normalise_channel(
    value: Any | None,
    n_re: int,
    n_rx: int,
) -> np.ndarray | None:
    if value is None:
        return None
    channel = np.asarray(value, dtype=np.complex128)
    if channel.ndim == 2:
        channel = channel[:, :, None]
    if channel.ndim != 3 or channel.shape[:2] != (n_re, n_rx):
        raise ValueError("hest must have shape (N_RE, N_rx, CellRefP)")
    if not np.all(np.isfinite(channel)):
        raise ValueError("hest must contain finite complex values")
    return channel


def _candidate_ports(value: Any) -> tuple[int, ...]:
    all_ports = [1, 2, 4]
    if value is None:
        return tuple(all_ports)
    if isinstance(value, bool) or not isinstance(value, (Integral, Real)):
        raise ValueError("CellRefP must be one of 1, 2, or 4")
    configured = int(value)
    if configured not in all_ports:
        raise ValueError("CellRefP must be one of 1, 2, or 4")
    return tuple([configured] + [item for item in all_ports if item != configured])


def _csi_enabled(value: Mapping[str, Any] | Any | None) -> bool:
    if value is None:
        return True
    selected = _field(value, "csi", "CSI", default="On")
    return str(selected).lower() != "off"


def _prefix(value: Mapping[str, Any] | Any) -> str:
    prefix = str(_field(value, "cyclic_prefix", "CyclicPrefix", default="Normal")).lower()
    if prefix not in {"normal", "extended"}:
        raise ValueError("CyclicPrefix must be 'Normal' or 'Extended'")
    return prefix


def _nonnegative_real(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, Real):
        raise ValueError(f"{name} must be a non-negative real number")
    result = float(value)
    if not np.isfinite(result) or result < 0:
        raise ValueError(f"{name} must be a non-negative real number")
    return result


def _field(
    value: Mapping[str, Any] | Any,
    *names: str,
    default: Any = ...,
) -> Any:
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


__all__ = ["lte_pbch_decode"]
